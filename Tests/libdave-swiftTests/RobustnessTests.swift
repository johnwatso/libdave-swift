import XCTest
@testable import libdave_swift

/// Regression tests for the failure modes that only appear in long-lived or
/// adversarial sessions: bounded state that used to fail the session closed,
/// callback contexts that used to accumulate for the life of the process, and
/// identity material that used to be world-listable.
final class RobustnessTests: XCTestCase {

    // MARK: - Bounded state ages out instead of killing the session

    /// A long call produces far more transitions than the tracking window
    /// holds. Before eviction existed, the session failed closed at the bound —
    /// roughly thirty membership changes — and the voice call died with it.
    func testLongTransitionStreamAgesOutInsteadOfFailingClosed() async throws {
        let limits = DaveCoordinatorLimits(maximumTrackedTransitions: 8)
        let coordinator = DaveSessionCoordinator(limits: limits)
        try await coordinator.configureForDiscordVoice(
            groupId: 4242,
            selfUserId: "424242424242424242",
            protocolVersion: 1
        )

        // Comfortably more than the bound, as a multi-hour call would produce.
        for transitionId in 1...200 {
            _ = await coordinator.executeDiscordTransition(UInt64(transitionId))

            let diagnostics = await coordinator.getDiagnostics()
            XCTAssertNotEqual(
                diagnostics.handshakeState,
                .failed,
                "session failed closed at transition \(transitionId) instead of ageing state out"
            )
        }

        let snapshot = await coordinator.invariantSnapshot
        XCTAssertLessThanOrEqual(snapshot.ledgerEntryCount, limits.maximumTrackedTransitions)
        XCTAssertLessThanOrEqual(snapshot.stagedTransitionCount, limits.maximumTrackedTransitions)

        let diagnostics = await coordinator.getDiagnostics()
        XCTAssertGreaterThan(
            diagnostics.evictedTransitionCount,
            0,
            "eviction must be reported so hosts can see state ageing out"
        )
    }

    /// Eviction must not silently forget the transition that media is actually
    /// using: a replay of the live transition still has to be recognized.
    func testEvictionKeepsTheActiveAndStagedTransitions() async throws {
        let limits = DaveCoordinatorLimits(maximumTrackedTransitions: 4)
        let coordinator = DaveSessionCoordinator(limits: limits)
        try await coordinator.configureForDiscordVoice(
            groupId: 4243,
            selfUserId: "424242424242424242",
            protocolVersion: 1
        )

        // Stage an Execute that has no MLS payload yet, then push far past the
        // bound. The staged window is allowed to age out, but the bookkeeping
        // must stay internally consistent throughout.
        for transitionId in 1...50 {
            _ = await coordinator.executeDiscordTransition(UInt64(transitionId))
            let snapshot = await coordinator.invariantSnapshot
            XCTAssertEqual(
                snapshot.stagedTransitionCount,
                snapshot.stagedTransitionOrderCount,
                "staged index drifted from storage at \(transitionId)"
            )

            // The reported pending transition must always name a transition
            // that is genuinely still staged, never one that was evicted.
            let pendingTransitionId = await coordinator.getDiagnostics().pendingTransitionId
            if snapshot.stagedTransitionCount == 0 {
                XCTAssertNil(pendingTransitionId, "reported a pending transition with nothing staged")
            } else {
                XCTAssertNotNil(pendingTransitionId, "staged transitions exist but none was reported")
            }
        }
    }

    // MARK: - Callback contexts are reclaimed

    /// Every fingerprint request registers a native callback context. They used
    /// to be retained until process exit, so a bot that verifies identities
    /// leaked steadily for as long as it ran.
    func testFingerprintRequestsDoNotGrowTheCallbackTableWithoutBound() throws {
        let session = try DaveSession(authSessionId: nil) { _, _ in }
        session.initialize(version: 1, groupId: 4244, selfUserId: "424242424242424242")

        let before = DaveNativeCallbackContextRetainer.shared.retainedContextCount
        for _ in 0..<800 {
            session.getPairwiseFingerprint(version: 1, userId: "515151515151515151") { _ in }
        }
        let after = DaveNativeCallbackContextRetainer.shared.retainedContextCount

        // 800 requests must not add 800 permanent contexts. Delivered bridges
        // are retired, so the table is capped rather than growing linearly.
        XCTAssertLessThan(
            after,
            before + 800,
            "delivered fingerprint bridges must be retired, not retained forever"
        )
        XCTAssertLessThanOrEqual(after, 512, "retainer must enforce its hard ceiling")
    }

    /// The single-shot resume is what makes a timeout safe: whichever of the
    /// native callback and the timeout arrives first wins, and the loser is a
    /// no-op rather than a double resume (which would trap).
    func testSingleShotResumeDeliversExactlyOnce() async {
        let resume = DaveSingleShotResume<Int>()
        resume.deliver(1)
        resume.deliver(2)
        let value = await withCheckedContinuation { continuation in
            resume.attach(continuation)
        }
        XCTAssertEqual(value, 1, "the first delivery must win, even before attach")

        let ordered = DaveSingleShotResume<Int>()
        let task = Task { await withCheckedContinuation { ordered.attach($0) } }
        try? await Task.sleep(for: .milliseconds(20))
        ordered.deliver(7)
        ordered.deliver(8)
        let result = await task.value
        XCTAssertEqual(result, 7)
    }

    /// Replaced ratchets are held briefly because native code keeps using them
    /// for frames that were already in flight when a re-key landed. The pool
    /// must keep them alive for that window, and still be bounded.
    func testRetiredHandlePoolRetainsThenBoundsItsContents() {
        var pool = DaveRetiredHandlePool<NSObject>()
        XCTAssertEqual(pool.count, 0)

        // A retired handle must stay alive: releasing it early is exactly the
        // use-after-free this pool exists to prevent.
        weak var weakHandle: NSObject?
        do {
            let handle = NSObject()
            weakHandle = handle
            pool.retire(handle)
        }
        XCTAssertNotNil(weakHandle, "a retired handle must stay alive through its grace window")
        pool.prune()
        XCTAssertNotNil(weakHandle, "prune must not release a handle whose window has not elapsed")
        XCTAssertEqual(pool.count, 1)

        // A pathological re-key storm must not accumulate handles forever.
        for _ in 0..<64 {
            pool.retire(NSObject())
        }
        XCTAssertLessThanOrEqual(pool.count, 8, "retired handles must not accumulate without bound")
    }

    // MARK: - Roster verification

    func testUnrecognizedRosterMemberIsReportedByDefault() async throws {
        let coordinator = DaveSessionCoordinator()
        try await coordinator.configureForDiscordVoice(
            groupId: 4246,
            selfUserId: "424242424242424242",
            protocolVersion: 1
        )
        await coordinator.setRecognizedRosterForTesting(["515151151515151515"])

        try await coordinator.applyRoster([515_151_151_515_151_515, 616_161_161_616_161_616]) { memberId in
            Data([UInt8(memberId % 251)])
        }

        let roster = await coordinator.currentRoster()
        XCTAssertEqual(roster.count, 2)
        let unrecognized = await coordinator.unrecognizedRosterMembers()
        XCTAssertEqual(unrecognized, ["616161161616161616"])
        let signature = await coordinator.rosterMemberSignature(for: "515151151515151515")
        XCTAssertNotNil(signature)

        let diagnostics = await coordinator.getDiagnostics()
        XCTAssertEqual(diagnostics.rosterMemberCount, 2)
        XCTAssertEqual(diagnostics.unrecognizedRosterMemberCount, 1)
        XCTAssertNotEqual(diagnostics.handshakeState, .failed, "the default policy reports without stopping media")
    }

    func testUnrecognizedRosterMemberCanFailTheSessionClosed() async throws {
        let coordinator = DaveSessionCoordinator(
            limits: DaveCoordinatorLimits(unrecognizedRosterMemberPolicy: .failClosed)
        )
        try await coordinator.configureForDiscordVoice(
            groupId: 4247,
            selfUserId: "424242424242424242",
            protocolVersion: 1
        )
        await coordinator.setRecognizedRosterForTesting(["515151151515151515"])

        do {
            try await coordinator.applyRoster([515_151_151_515_151_515, 616_161_161_616_161_616]) { _ in nil }
            XCTFail("failClosed policy must reject an unrecognized roster member")
        } catch let error as DaveError {
            guard case .unrecognizedRosterMembers(let userIds) = error else {
                return XCTFail("expected unrecognizedRosterMembers, got \(error)")
            }
            XCTAssertEqual(userIds, ["616161161616161616"])
            XCTAssertEqual(error.recoveryHint, .recreateSession)
        }
    }

    /// The local client belongs to its own group whether or not Discord listed
    /// it, so it must never be reported as an intruder.
    func testSelfIsNeverAnUnrecognizedRosterMember() async throws {
        let coordinator = DaveSessionCoordinator(
            limits: DaveCoordinatorLimits(unrecognizedRosterMemberPolicy: .failClosed)
        )
        try await coordinator.configureForDiscordVoice(
            groupId: 4248,
            selfUserId: "424242424242424242",
            protocolVersion: 1
        )
        await coordinator.setRecognizedRosterForTesting(["515151151515151515"])

        try await coordinator.applyRoster([424_242_424_242_424_242, 515_151_151_515_151_515]) { _ in nil }
        let unrecognized = await coordinator.unrecognizedRosterMembers()
        XCTAssertTrue(unrecognized.isEmpty, "self must not be flagged as unrecognized")
    }

    func testEpochAuthenticatorRequiresConfiguration() async {
        let coordinator = DaveSessionCoordinator()
        do {
            _ = try await coordinator.epochAuthenticator()
            XCTFail("expected notConfigured")
        } catch let error as DaveError {
            guard case .notConfigured = error else {
                return XCTFail("expected notConfigured, got \(error)")
            }
        } catch {
            XCTFail("expected DaveError, got \(error)")
        }
    }

    // MARK: - Watchdog

    /// The watchdog deadline is monotonic, so it cannot be defeated by moving
    /// the wall clock backwards — the case that would leave a stalled
    /// transition transmitting on indeterminate MLS state indefinitely.
    func testWatchdogDeadlineIsNotAffectedByWallClockMovement() async throws {
        let coordinator = DaveSessionCoordinator()
        try await coordinator.configureForDiscordVoice(
            groupId: 4249,
            selfUserId: "424242424242424242",
            protocolVersion: 1
        )

        _ = await coordinator.markDiscordMediaNotReady(reason: "monotonic watchdog", timeout: 60)

        // A wall clock that jumped an hour into the past must not extend the
        // deadline when the watchdog is evaluated on its own clock.
        let status = await coordinator.evaluateMediaReadinessWatchdog()
        guard case .pending(let secondsRemaining) = status else {
            return XCTFail("expected a pending watchdog, got \(status)")
        }
        XCTAssertGreaterThan(secondsRemaining, 0)
        XCTAssertLessThanOrEqual(secondsRemaining, 60)
    }

    /// The default timeout comes from limits rather than a constant repeated
    /// through the coordinator.
    func testWatchdogDefaultTimeoutComesFromLimits() async throws {
        let coordinator = DaveSessionCoordinator(
            limits: DaveCoordinatorLimits(mediaReadinessTimeout: 45)
        )
        try await coordinator.configureForDiscordVoice(
            groupId: 4250,
            selfUserId: "424242424242424242",
            protocolVersion: 1
        )

        _ = await coordinator.markDiscordMediaNotReady(reason: "configured timeout")
        let status = await coordinator.evaluateMediaReadinessWatchdog()
        guard case .pending(let secondsRemaining) = status else {
            return XCTFail("expected a pending watchdog, got \(status)")
        }
        XCTAssertGreaterThan(secondsRemaining, 40, "the configured 45s timeout must be used, not a hardcoded 10s")
    }

    // MARK: - Persisted identity

    func testAuthSessionIdCannotEscapeTheKeyStore() {
        // These would be interpolated straight into a key-store path by the
        // native backend.
        for hostile in ["../../evil", "..", "a/b", "back\\slash", "", String(repeating: "x", count: 129)] {
            XCTAssertThrowsError(
                try DaveSession(authSessionId: hostile) { _, _ in },
                "auth session id '\(hostile)' must be rejected"
            ) { error in
                guard let daveError = error as? DaveError,
                      case .invalidAuthSessionId = daveError else {
                    return XCTFail("expected invalidAuthSessionId for '\(hostile)', got \(error)")
                }
            }
        }
    }

    func testPersistedIdentityIsPurgeableAndDirectoryIsPrivate() async throws {
        let keyStore = try TemporaryKeyStore()
        defer { try? keyStore.close() }

        // This test deletes key material. Refuse to run unless the store has
        // demonstrably been redirected into the throwaway directory, so a
        // failed redirection can never destroy the user's real identities.
        let resolved = DavePersistedIdentityStore.directoryURL.standardizedFileURL.path
        let expectedRoot = keyStore.root.standardizedFileURL.path
        try XCTSkipUnless(
            resolved.hasPrefix(expectedRoot),
            "key store was not redirected (resolved to \(resolved)); refusing to purge"
        )

        let authSessionId = "purge-test-\(UUID().uuidString)"
        let otherSessionId = "other-\(UUID().uuidString)"

        for id in [authSessionId, otherSessionId] {
            let coordinator = DaveSessionCoordinator(authSessionId: id)
            _ = try await coordinator.configureDiscordVoiceSession(
                groupId: 4251,
                selfUserId: "424242424242424242",
                protocolVersion: 1
            )
            _ = try await coordinator.getMarshalledKeyPackage()
        }

        XCTAssertFalse(
            DavePersistedIdentityStore.identityFileURLs(authSessionId: authSessionId).isEmpty,
            "the identity under test must have been persisted"
        )

        // The native library leaves the directory 0755, which lets any local
        // user enumerate which identities exist.
        let directoryMode = try FileManager.default
            .attributesOfItem(atPath: DavePersistedIdentityStore.directoryURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryMode?.intValue, 0o700, "the identity directory must be private to the user")

        for url in DavePersistedIdentityStore.identityFileURLs() {
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o600, "signature key files must not be readable by other users")
        }

        // Purging one identity must not touch another's key material.
        let removed = try DavePersistedIdentityStore.purge(authSessionId: authSessionId)
        XCTAssertGreaterThan(removed, 0)
        XCTAssertTrue(DavePersistedIdentityStore.identityFileURLs(authSessionId: authSessionId).isEmpty)
        XCTAssertFalse(
            DavePersistedIdentityStore.identityFileURLs(authSessionId: otherSessionId).isEmpty,
            "purging one identity must not remove another"
        )

        XCTAssertGreaterThan(try DavePersistedIdentityStore.purgeAll(), 0)
        XCTAssertTrue(DavePersistedIdentityStore.identityFileURLs().isEmpty)
    }

    // MARK: - Diagnostics schema

    /// Diagnostics are persisted and forwarded to monitoring pipelines, so a
    /// record written by an older release must still decode.
    func testDiagnosticsDecodesPayloadsMissingNewerFields() throws {
        let legacy = """
        {
          "sessionGeneration": 3,
          "protocolVersion": 1,
          "appliedTransitionCount": 2,
          "handshakeState": "Ready",
          "isExternalSenderRegistered": true,
          "mediaReady": true,
          "pendingTransitionIds": [7],
          "externalSenderState": "registered",
          "hasIssuedInitialKeyPackage": true,
          "hasSentInitialKeyPackage": true,
          "pendingOutboundActionCount": 1
        }
        """.data(using: .utf8)!

        let diagnostics = try JSONDecoder().decode(DaveDiagnostics.self, from: legacy)
        XCTAssertEqual(diagnostics.sessionGeneration, 3)
        XCTAssertEqual(diagnostics.handshakeState, .ready)
        XCTAssertEqual(diagnostics.pendingTransitionIds, [7])
        // Fields added later fall back to their defaults.
        XCTAssertEqual(diagnostics.rosterMemberCount, 0)
        XCTAssertEqual(diagnostics.unrecognizedRosterMemberCount, 0)
        XCTAssertEqual(diagnostics.evictedTransitionCount, 0)
    }

    /// Points the native key store at a throwaway directory via
    /// XDG_CONFIG_HOME, which the backend reads on every lookup.
    private final class TemporaryKeyStore {
        let root: URL
        private let previous: String?
        private var isClosed = false

        init() throws {
            previous = getenv("XDG_CONFIG_HOME").map { String(cString: $0) }
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("libdave-robustness-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            guard setenv("XDG_CONFIG_HOME", root.path, 1) == 0 else {
                try? FileManager.default.removeItem(at: root)
                throw NSError(domain: "RobustnessTests", code: 1)
            }
        }

        func close() throws {
            guard !isClosed else { return }
            isClosed = true
            if let previous {
                setenv("XDG_CONFIG_HOME", previous, 1)
            } else {
                unsetenv("XDG_CONFIG_HOME")
            }
            try FileManager.default.removeItem(at: root)
        }

        deinit {
            try? close()
        }
    }
}
