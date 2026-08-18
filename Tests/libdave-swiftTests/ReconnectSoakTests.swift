import XCTest
@testable import libdave_swift

/// A voice bot is a long-lived process that reconnects repeatedly: each
/// reconnect creates and destroys a native MLS session, an encryptor, and a
/// set of decryptors, and registers native callback contexts for each.
///
/// These tests run that churn far past any bound in the library and assert
/// that nothing accumulates. They are cheap in wall time but are the tests
/// most likely to expose a lifetime bug under the sanitizer CI jobs.
final class ReconnectSoakTests: XCTestCase {

    /// Native sessions and their callback contexts must not accumulate across
    /// reconnect cycles.
    func testSessionChurnKeepsCallbackContextsBounded() throws {
        for _ in 0..<600 {
            let session = try DaveSession(authSessionId: nil) { _, _ in }
            session.initialize(version: 1, groupId: 5_150, selfUserId: "424242424242424242")
            _ = session.marshalledKeyPackage
            session.reset()
        }

        XCTAssertLessThanOrEqual(
            DaveNativeCallbackContextRetainer.shared.retainedContextCount,
            512,
            "reconnect churn must not grow the callback table without bound"
        )
    }

    /// Cryptor churn exercises the other native lifetime: encryptors register
    /// their own callback context, and decryptors park replaced ratchets.
    func testCryptorChurnDoesNotAccumulate() throws {
        for _ in 0..<600 {
            let encryptor = try DaveEncryptor()
            encryptor.setProtocolVersionChangedCallback {}
            encryptor.assignSsrcToCodec(ssrc: 1, codec: .opus)
            encryptor.setPassthroughMode(true)
            _ = try encryptor.encrypt(mediaType: .audio, ssrc: 1, frame: Data([0x01, 0x02]))

            let decryptor = try DaveDecryptor()
            decryptor.transitionToPassthroughMode(true)
            _ = try decryptor.decrypt(mediaType: .audio, encryptedFrame: Data([0x01, 0x02]))
        }

        XCTAssertLessThanOrEqual(
            DaveNativeCallbackContextRetainer.shared.retainedContextCount,
            512,
            "encryptor churn must not grow the callback table without bound"
        )
    }

    /// The full coordinator reconnect cycle: configure, run media, recover,
    /// and recreate, repeatedly. Internal state must return to a clean baseline
    /// every round rather than creeping upward.
    func testCoordinatorReconnectCycleReturnsToCleanState() async throws {
        let coordinator = DaveSessionCoordinator(authSessionId: nil)

        for round in 0..<150 {
            try await coordinator.configureForDiscordVoice(
                groupId: UInt64(6_000 + round),
                selfUserId: "424242424242424242",
                protocolVersion: 1
            )
            try await coordinator.setPassthroughMode(true)

            // Drive both media directions and a few gateway events, then tear
            // the session down the way a dropped WebSocket would.
            _ = await coordinator.executeDiscordTransition(UInt64(round))
            _ = try? await coordinator.consumeDiscordGatewayEvent(
                .commit(Data([0x01, 0x02, 0x03]), transitionId: UInt64(round))
            )
            _ = try? await coordinator.decryptDiscordAudioFrame(
                Data([0x09]),
                from: "515151515151515151"
            )

            await coordinator.reset()

            let snapshot = await coordinator.invariantSnapshot
            XCTAssertEqual(snapshot.ledgerEntryCount, 0, "round \(round): ledger survived reset")
            XCTAssertEqual(snapshot.stagedTransitionCount, 0, "round \(round): staged state survived reset")
            XCTAssertEqual(snapshot.decryptorCount, 0, "round \(round): decryptors survived reset")
            XCTAssertEqual(snapshot.pendingOutboundActionCount, 0, "round \(round): outbox survived reset")
            XCTAssertFalse(snapshot.mediaReady, "round \(round): media stayed ready across reset")
        }

        XCTAssertLessThanOrEqual(DaveNativeCallbackContextRetainer.shared.retainedContextCount, 512)
    }
}
