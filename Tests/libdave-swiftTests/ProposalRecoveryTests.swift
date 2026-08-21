import XCTest
@testable import libdave_swift

final class ProposalRecoveryTests: XCTestCase {

    func testSynchronousNativeProposalFailureRequiresRecreationAndRejectsLaterTransitions() async throws {
        let coordinator = DaveSessionCoordinator()
        try await coordinator.configureForDiscordVoice(
            groupId: 7_700,
            selfUserId: "424242424242424242",
            protocolVersion: 1
        )

        let nativeSource = "ProcessProposals"
        let nativeReason = "PublicMessage not for this epoch"
        await coordinator.failNextProposalProcessingForTesting(
            source: nativeSource,
            reason: nativeReason
        )

        // The seam intercepts this marker before the native boundary, so the
        // test does not depend on invented or version-specific MLS bytes.
        do {
            _ = try await coordinator.processDiscordProposalsForOutbound(
                Data("test-seam-proposal".utf8),
                recognizedUserIds: ["424242424242424242", "515151515151515151"]
            )
            XCTFail("A native proposal failure must fail the session closed")
        } catch let error as DaveError {
            guard case .sessionFailed = error else {
                return XCTFail("Expected .sessionFailed, got: \(error)")
            }
            XCTAssertEqual(error.recoveryHint, .recreateSession)
            XCTAssertNotEqual(error.recoveryHint, .retryLater)
        }

        var diagnostics = await coordinator.getDiagnostics()
        XCTAssertEqual(diagnostics.handshakeState, .failed)
        XCTAssertFalse(diagnostics.mediaReady)
        XCTAssertEqual(diagnostics.lastRecoveryAction, .failClosed)
        XCTAssertEqual(diagnostics.lastFailure?.code, .proposalsProcessingFailed)
        XCTAssertEqual(diagnostics.lastFailure?.origin, .nativeMls)
        XCTAssertEqual(diagnostics.lastFailure?.nativeSource, nativeSource)
        XCTAssertEqual(diagnostics.lastFailure?.nativeReason, nativeReason)
        XCTAssertTrue(diagnostics.lastMlsError?.contains(nativeReason) == true)
        XCTAssertEqual(
            diagnostics.recentEvents.filter { $0.kind == .sessionFailedClosed }.count,
            1,
            "the proposal failure must close the generation exactly once"
        )

        // Both following message types must stop at the failed-state guard;
        // neither marker is handed to the dead native MLS session.
        do {
            _ = try await coordinator.processDiscordCommitForOutbound(
                Data("must-not-reach-native-commit".utf8),
                transitionId: 81
            )
            XCTFail("A Commit must not run against a failed native session")
        } catch let error as DaveError {
            guard case .sessionFailed = error else {
                return XCTFail("Expected .sessionFailed for later Commit, got: \(error)")
            }
            XCTAssertEqual(error.recoveryHint, .recreateSession)
        }

        do {
            _ = try await coordinator.processDiscordWelcomeForOutbound(
                Data("must-not-reach-native-welcome".utf8),
                transitionId: 82,
                recognizedUserIds: ["424242424242424242"]
            )
            XCTFail("A Welcome must not run against a failed native session")
        } catch let error as DaveError {
            guard case .sessionFailed = error else {
                return XCTFail("Expected .sessionFailed for later Welcome, got: \(error)")
            }
            XCTAssertEqual(error.recoveryHint, .recreateSession)
        }

        diagnostics = await coordinator.getDiagnostics()
        XCTAssertEqual(diagnostics.lastFailure?.nativeSource, nativeSource)
        XCTAssertEqual(diagnostics.lastFailure?.nativeReason, nativeReason)
        XCTAssertEqual(
            diagnostics.recentEvents.filter { $0.kind == .sessionFailedClosed }.count,
            1,
            "later gateway messages must not close or classify the dead generation again"
        )
    }
}
