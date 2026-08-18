import XCTest
@testable import libdave_swift

/// Randomized, deterministic exercise of the gateway state machine.
///
/// These tests do not need genuine MLS fixtures: their purpose is to prove
/// that no ordering of gateway events — including malformed, out-of-order,
/// duplicated, and hostile ones — can break the coordinator's safety
/// invariants, exhaust its bounded state, or trap.
///
/// The seeds are fixed so a failure is reproducible; the reported seed and
/// step index identify the exact sequence.
final class StateMachineFuzzTests: XCTestCase {

    /// A small, explicit PRNG so sequences are identical on every machine and
    /// every Swift version, unlike `SystemRandomNumberGenerator`.
    private struct SplitMix64: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            self.state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Invariants that must hold after *every* event, whatever the sequence.
    private func assertInvariants(
        _ snapshot: DaveSessionCoordinator.InvariantSnapshot,
        limits: DaveCoordinatorLimits,
        seed: UInt64,
        step: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let context = "seed \(seed), step \(step)"

        // Media may never be declared ready without the cryptographic state
        // needed to actually produce a frame. This is the fail-closed contract.
        if snapshot.mediaReady {
            XCTAssertTrue(snapshot.hasEncryptor, "ready without an encryptor (\(context))", file: file, line: line)
            XCTAssertTrue(
                snapshot.hasActiveOutboundRatchet,
                "ready without an active ratchet (\(context))",
                file: file,
                line: line
            )
        }

        // A failed session is fully revoked and stays revoked.
        if snapshot.handshakeState == .failed {
            XCTAssertFalse(snapshot.mediaReady, "failed session reported ready (\(context))", file: file, line: line)
            XCTAssertFalse(
                snapshot.hasActiveOutboundRatchet,
                "failed session kept a ratchet (\(context))",
                file: file,
                line: line
            )
        }

        // Every bounded store stays inside its configured bound, so a hostile
        // or merely long-lived gateway stream cannot grow memory without limit.
        XCTAssertLessThanOrEqual(
            snapshot.ledgerEntryCount,
            limits.maximumTrackedTransitions,
            "replay ledger exceeded its bound (\(context))",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            snapshot.stagedTransitionCount,
            limits.maximumTrackedTransitions,
            "staged transitions exceeded their bound (\(context))",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            snapshot.pendingOutboundActionCount,
            limits.maximumPendingOutboundActions,
            "outbox exceeded its bound (\(context))",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            snapshot.decryptorCount,
            limits.maximumRosterMembers,
            "decryptor map exceeded its bound (\(context))",
            file: file,
            line: line
        )
        // The staged bookkeeping index and its storage must not drift apart.
        XCTAssertEqual(
            snapshot.stagedTransitionCount,
            snapshot.stagedTransitionOrderCount,
            "staged transition index drifted from storage (\(context))",
            file: file,
            line: line
        )
    }

    private func randomPayload(_ generator: inout SplitMix64, maxBytes: Int = 96) -> Data {
        let count = Int.random(in: 0...maxBytes, using: &generator)
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        for _ in 0..<count {
            bytes.append(UInt8.random(in: 0...255, using: &generator))
        }
        return Data(bytes)
    }

    /// Drives random gateway sequences and asserts the invariants after each
    /// step. Transition IDs are drawn from a deliberately small pool so that
    /// duplicates, replays, and welcome/commit collisions on one ID all occur.
    func testRandomGatewaySequencesPreserveSafetyInvariants() async throws {
        let limits = DaveCoordinatorLimits(
            maximumRosterMembers: 16,
            maximumTrackedTransitions: 8,
            maximumPendingOutboundActions: 8
        )

        for seed in UInt64(1)...UInt64(24) {
            var generator = SplitMix64(seed: seed)
            let coordinator = DaveSessionCoordinator(limits: limits)
            try await coordinator.configureForDiscordVoice(
                groupId: 777,
                selfUserId: "424242424242424242",
                protocolVersion: 1
            )

            for step in 0..<120 {
                let transitionId = UInt64.random(in: 0...4, using: &generator)
                let event: DiscordDaveGatewayEvent

                switch Int.random(in: 0...6, using: &generator) {
                case 0:
                    event = .externalSender(randomPayload(&generator))
                case 1:
                    event = .proposals(
                        randomPayload(&generator),
                        recognizedUserIds: ["424242424242424242", "515151515151515151"]
                    )
                case 2:
                    event = .welcome(
                        randomPayload(&generator),
                        transitionId: transitionId,
                        recognizedUserIds: ["424242424242424242"]
                    )
                case 3:
                    event = .commit(randomPayload(&generator), transitionId: transitionId)
                case 4:
                    event = .executeTransition(transitionId)
                case 5:
                    event = .prepareEpoch(
                        protocolVersion: 1,
                        epoch: UInt64.random(in: 0...3, using: &generator),
                        transitionId: transitionId
                    )
                default:
                    // Interleave the media path: it must never encrypt or
                    // decrypt while the session is not ready.
                    let frame = randomPayload(&generator, maxBytes: 32)
                    do {
                        _ = try await coordinator.encryptDiscordAudioFrame(frame, ssrc: 1)
                    } catch {
                        XCTAssertTrue(error is DaveError, "seed \(seed), step \(step): \(error)")
                    }
                    do {
                        _ = try await coordinator.decryptDiscordAudioFrame(frame, from: "515151515151515151")
                    } catch {
                        XCTAssertTrue(error is DaveError, "seed \(seed), step \(step): \(error)")
                    }
                    assertInvariants(
                        await coordinator.invariantSnapshot,
                        limits: limits,
                        seed: seed,
                        step: step
                    )
                    continue
                }

                do {
                    let result = try await coordinator.consumeDiscordGatewayEvent(event)
                    // Acknowledge roughly half the emitted actions, so both the
                    // acknowledged and the stuck-outbox paths get exercised.
                    for envelope in result.pendingActions where Bool.random(using: &generator) {
                        await coordinator.acknowledgeDiscordGatewayAction(envelope.id)
                    }
                } catch {
                    // Every rejection must be a typed DaveError carrying usable
                    // recovery guidance — never an untyped or trapping failure.
                    guard let daveError = error as? DaveError else {
                        return XCTFail("seed \(seed), step \(step): untyped error \(error)")
                    }
                    XCTAssertFalse(
                        daveError.localizedDescription.isEmpty,
                        "seed \(seed), step \(step): error without a description"
                    )
                }

                assertInvariants(
                    await coordinator.invariantSnapshot,
                    limits: limits,
                    seed: seed,
                    step: step
                )
            }
        }
    }

    /// A session that keeps recovering must not accumulate state across
    /// generations: recreation is the host's escape hatch and has to be clean.
    func testRepeatedRecoveryDoesNotAccumulateState() async throws {
        let coordinator = DaveSessionCoordinator(limits: DaveCoordinatorLimits(maximumTrackedTransitions: 8))
        try await coordinator.configureForDiscordVoice(
            groupId: 999,
            selfUserId: "424242424242424242",
            protocolVersion: 1
        )

        for round in 0..<40 {
            _ = await coordinator.executeDiscordTransition(UInt64(round))
            try await coordinator.recreateSessionState()

            let snapshot = await coordinator.invariantSnapshot
            XCTAssertEqual(snapshot.ledgerEntryCount, 0, "round \(round): ledger survived recreation")
            XCTAssertEqual(snapshot.stagedTransitionCount, 0, "round \(round): staged state survived recreation")
            XCTAssertEqual(snapshot.pendingOutboundActionCount, 0, "round \(round): outbox survived recreation")
            XCTAssertFalse(snapshot.mediaReady, "round \(round): media ready after recreation")
        }
    }
}
