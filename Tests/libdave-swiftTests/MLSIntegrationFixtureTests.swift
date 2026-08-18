import XCTest
@testable import libdave_swift

/// Runs a captured, internally consistent MLS session end to end.
///
/// Every other test in this package stops at the boundary of real MLS: they
/// prove the state machine, lifetimes, and native error handling are sound, but
/// nothing exercises an actual key ratchet, an actual re-key, or actual
/// encrypted media. That gap cannot be closed with synthetic bytes — an
/// external sender, key package, Welcome, Commit, roster, and ratchets are all
/// bound to one MLS group state — so it needs a fixture captured from a real
/// (disposable, non-production) Voice session.
///
/// This harness is the consumer for that fixture. Drop one or more JSON files
/// into `Tests/libdave-swiftTests/Fixtures/mls-integration/` following
/// `Docs/MLS_INTEGRATION_FIXTURES.md` and they run automatically. With no
/// fixture present the test skips, so the gap is visible in test output rather
/// than silently absent.
final class MLSIntegrationFixtureTests: XCTestCase {

    private struct Fixture: Decodable {
        let description: String
        let groupId: UInt64
        let selfUserId: String
        let protocolVersion: UInt16
        let steps: [Step]
    }

    private struct Step: Decodable {
        /// One of: externalSender, proposals, welcome, commit, executeTransition,
        /// prepareEpoch, encryptAudio, decryptAudio.
        let event: String
        let payloadHex: String?
        let transitionId: UInt64?
        let epoch: UInt64?
        let protocolVersion: UInt16?
        let recognizedUserIds: [String]?
        let fromUserId: String?
        let ssrc: UInt32?
        let expect: Expectation?
    }

    private struct Expectation: Decodable {
        /// Expected outbound action kinds, in order: mlsKeyPackage,
        /// mlsCommitWelcome, transitionReady, invalidCommitWelcome.
        let actions: [String]?
        let mediaReady: Bool?
        let roster: [String]?
        let unrecognizedRoster: [String]?
        let recoveryHint: String?
        /// For decryptAudio: the plaintext the frame must decrypt to.
        let plaintextHex: String?
        /// For encryptAudio: ciphertext must differ from the plaintext, which
        /// is the check that real encryption (not passthrough) happened.
        let differsFromPlaintext: Bool?
        /// The step is expected to throw a `DaveError` with this case name.
        let error: String?
    }

    /// Name of the committed fixture that exercises the harness itself. It
    /// contains only malformed bytes, so it proves nothing about MLS.
    private static let selfCheckFixtureName = "harness-selfcheck.json"

    /// Runs every captured fixture. Skips — loudly — when none has been
    /// captured yet, so the missing end-to-end coverage shows up in test output
    /// instead of being invisible.
    func testCapturedMlsSessionsRunEndToEnd() async throws {
        let fixtures = Self.fixtureURLs().filter { $0.lastPathComponent != Self.selfCheckFixtureName }
        try XCTSkipIf(
            fixtures.isEmpty,
            """
            No captured MLS fixture present, so real key ratchets, re-keys, and \
            encrypted media remain unverified. Everything else in this package \
            is tested; this is the known gap. See \
            Docs/MLS_INTEGRATION_FIXTURES.md for how to capture one into \
            Tests/libdave-swiftTests/Fixtures/mls-integration/.
            """
        )

        for url in fixtures {
            let fixture = try JSONDecoder().decode(Fixture.self, from: try Data(contentsOf: url))
            try await run(fixture, named: url.lastPathComponent)
        }
    }

    /// Keeps the harness itself working while no real fixture exists.
    ///
    /// Without this, the discovery, decoding, and assertion paths above would
    /// be dead code until someone captured a session — and would likely have
    /// rotted by then. This fixture uses deliberately malformed bytes, so it
    /// requires no captured session and no secret material.
    func testFixtureHarnessSelfCheckRuns() async throws {
        let url = try XCTUnwrap(
            Self.fixtureURLs().first { $0.lastPathComponent == Self.selfCheckFixtureName },
            "the committed harness self-check fixture is missing"
        )
        let fixture = try JSONDecoder().decode(Fixture.self, from: try Data(contentsOf: url))
        try await run(fixture, named: url.lastPathComponent)
    }

    private func run(_ fixture: Fixture, named name: String) async throws {
        let coordinator = DaveSessionCoordinator(authSessionId: nil)
        _ = try await coordinator.configureDiscordVoiceSession(
            groupId: fixture.groupId,
            selfUserId: fixture.selfUserId,
            protocolVersion: fixture.protocolVersion
        )

        for (index, step) in fixture.steps.enumerated() {
            let context = "\(name) step \(index) (\(step.event))"

            switch step.event {
            case "encryptAudio":
                let plaintext = try Self.data(step.payloadHex, context)
                do {
                    let ciphertext = try await coordinator.encryptDiscordAudioFrame(
                        plaintext,
                        ssrc: step.ssrc ?? 1
                    )
                    try assertNoExpectedError(step, context)
                    if step.expect?.differsFromPlaintext == true {
                        XCTAssertNotEqual(
                            ciphertext,
                            plaintext,
                            "\(context): ciphertext matched plaintext, so no encryption happened"
                        )
                    }
                } catch let error as DaveError {
                    try assertExpected(error, step, context)
                }

            case "decryptAudio":
                let ciphertext = try Self.data(step.payloadHex, context)
                do {
                    let plaintext = try await coordinator.decryptDiscordAudioFrame(
                        ciphertext,
                        from: try XCTUnwrap(step.fromUserId, "\(context): fromUserId required")
                    )
                    try assertNoExpectedError(step, context)
                    if let expectedHex = step.expect?.plaintextHex {
                        XCTAssertEqual(
                            plaintext,
                            try Self.data(expectedHex, context),
                            "\(context): decrypted plaintext did not match the fixture"
                        )
                    }
                } catch let error as DaveError {
                    try assertExpected(error, step, context)
                }

            default:
                let event = try Self.gatewayEvent(step, context)
                do {
                    let result = try await coordinator.consumeDiscordGatewayEvent(event)
                    try assertNoExpectedError(step, context)
                    try assert(result, against: step.expect, context)
                    // Acknowledge everything: the outbox retry path has its own
                    // coverage, and a fixture should exercise the happy path.
                    for envelope in result.pendingActions {
                        await coordinator.acknowledgeDiscordGatewayAction(envelope.id)
                    }
                } catch let error as DaveError {
                    try assertExpected(error, step, context)
                }
            }
        }
    }

    private func assert(
        _ result: DiscordDaveGatewayResult,
        against expectation: Expectation?,
        _ context: String
    ) throws {
        guard let expectation else { return }

        if let expectedActions = expectation.actions {
            let actual = result.pendingActions.map { Self.name(of: $0.action) }
            XCTAssertEqual(actual, expectedActions, "\(context): outbound actions did not match")
        }
        if let mediaReady = expectation.mediaReady {
            XCTAssertEqual(result.mediaReady, mediaReady, "\(context): media readiness did not match")
        }
        if let roster = expectation.roster {
            XCTAssertEqual(result.rosterUserIds.sorted(), roster.sorted(), "\(context): roster did not match")
        }
        if let unrecognized = expectation.unrecognizedRoster {
            XCTAssertEqual(
                result.unrecognizedRosterUserIds.sorted(),
                unrecognized.sorted(),
                "\(context): unrecognized roster members did not match"
            )
        }
        if let hint = expectation.recoveryHint {
            XCTAssertEqual(result.recoveryHint.rawValue, hint, "\(context): recovery hint did not match")
        }
    }

    private func assertNoExpectedError(_ step: Step, _ context: String) throws {
        if let expected = step.expect?.error {
            XCTFail("\(context): expected DaveError.\(expected) but the step succeeded")
        }
    }

    private func assertExpected(_ error: DaveError, _ step: Step, _ context: String) throws {
        guard let expected = step.expect?.error else {
            XCTFail("\(context): unexpected error \(error)")
            return
        }
        XCTAssertTrue(
            String(describing: error).hasPrefix(expected),
            "\(context): expected DaveError.\(expected), got \(error)"
        )
    }

    private static func gatewayEvent(_ step: Step, _ context: String) throws -> DiscordDaveGatewayEvent {
        switch step.event {
        case "externalSender":
            return .externalSender(try data(step.payloadHex, context))
        case "proposals":
            return .proposals(
                try data(step.payloadHex, context),
                recognizedUserIds: step.recognizedUserIds ?? []
            )
        case "welcome":
            return .welcome(
                try data(step.payloadHex, context),
                transitionId: try XCTUnwrap(step.transitionId, "\(context): transitionId required"),
                recognizedUserIds: step.recognizedUserIds ?? []
            )
        case "commit":
            return .commit(
                try data(step.payloadHex, context),
                transitionId: try XCTUnwrap(step.transitionId, "\(context): transitionId required")
            )
        case "executeTransition":
            return .executeTransition(try XCTUnwrap(step.transitionId, "\(context): transitionId required"))
        case "prepareEpoch":
            return .prepareEpoch(
                protocolVersion: try XCTUnwrap(step.protocolVersion, "\(context): protocolVersion required"),
                epoch: try XCTUnwrap(step.epoch, "\(context): epoch required"),
                transitionId: try XCTUnwrap(step.transitionId, "\(context): transitionId required")
            )
        default:
            throw XCTSkip("\(context): unknown fixture event '\(step.event)'")
        }
    }

    private static func name(of action: DiscordDaveOutboundAction) -> String {
        switch action {
        case .mlsKeyPackage: return "mlsKeyPackage"
        case .mlsCommitWelcome: return "mlsCommitWelcome"
        case .transitionReady: return "transitionReady"
        case .invalidCommitWelcome: return "invalidCommitWelcome"
        }
    }

    private static func data(_ hex: String?, _ context: String) throws -> Data {
        let hex = try XCTUnwrap(hex, "\(context): payloadHex required")
        let clean = hex.filter { !$0.isWhitespace }
        guard clean.count.isMultiple(of: 2) else {
            throw XCTSkip("\(context): odd-length hex payload")
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else {
                throw XCTSkip("\(context): invalid hex byte")
            }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    private static func fixtureURLs() -> [URL] {
        guard let urls = Bundle.module.urls(
            forResourcesWithExtension: "json",
            subdirectory: "Fixtures/mls-integration"
        ) else {
            return []
        }
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
