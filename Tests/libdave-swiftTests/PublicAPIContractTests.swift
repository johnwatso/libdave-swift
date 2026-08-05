import Foundation
import XCTest
import libdave_swift

/// These tests intentionally import the module like a package consumer rather
/// than using `@testable`. They protect the public API and wire-format contracts
/// that a separately released SwiftBot integration relies on.
final class PublicAPIContractTests: XCTestCase {
    func testDiagnosticsRoundTripsThroughPublicCodableAPI() throws {
        let timestamp = Date(timeIntervalSince1970: 1_735_689_600)
        let diagnostics = DaveDiagnostics(
            sessionGeneration: 3,
            protocolVersion: 1,
            appliedTransitionCount: 7,
            handshakeState: .ready,
            encryptionStats: nil,
            lastMlsError: "example native failure",
            lastTransitionTimestamp: timestamp,
            isExternalSenderRegistered: true,
            mediaReady: false,
            pendingEpoch: 8,
            pendingTransitionId: 42,
            activeTransitionId: 41,
            pendingTransitionIds: [42, 43],
            externalSenderState: .registered,
            lastRecoveryAction: .pauseMedia,
            hasIssuedInitialKeyPackage: true,
            hasSentInitialKeyPackage: true,
            pendingOutboundActionCount: 2
        )

        let decoded = try JSONDecoder().decode(
            DaveDiagnostics.self,
            from: JSONEncoder().encode(diagnostics)
        )

        XCTAssertEqual(decoded.protocolVersion, 1)
        XCTAssertEqual(decoded.sessionGeneration, 3)
        XCTAssertEqual(decoded.appliedTransitionCount, 7)
        XCTAssertEqual(decoded.handshakeState, .ready)
        XCTAssertEqual(decoded.lastMlsError, "example native failure")
        XCTAssertEqual(decoded.lastTransitionTimestamp, timestamp)
        XCTAssertTrue(decoded.isExternalSenderRegistered)
        XCTAssertFalse(decoded.mediaReady)
        XCTAssertEqual(decoded.pendingEpoch, 8)
        XCTAssertEqual(decoded.pendingTransitionId, 42)
        XCTAssertEqual(decoded.activeTransitionId, 41)
        XCTAssertEqual(decoded.pendingTransitionIds, [42, 43])
        XCTAssertEqual(decoded.externalSenderState, .registered)
        XCTAssertEqual(decoded.lastRecoveryAction, .pauseMedia)
        XCTAssertTrue(decoded.hasIssuedInitialKeyPackage)
        XCTAssertTrue(decoded.hasSentInitialKeyPackage)
        XCTAssertEqual(decoded.pendingOutboundActionCount, 2)
    }

    func testPublicRecoveryHintsRemainSafeToAutomate() {
        XCTAssertEqual(DaveError.mediaNotReady.recoveryHint, .retryLater)
        XCTAssertEqual(DaveError.invalidExternalSender.recoveryHint, .waitForExternalSender)
        XCTAssertEqual(
            DaveError.externalSenderRejected(reason: "invalid MLS encoding").recoveryHint,
            .recreateSession
        )
        XCTAssertEqual(DaveError.protocolMismatch(expected: 1, actual: 2).recoveryHint, .recreateSession)
        XCTAssertEqual(DaveError.externalSenderConflict.recoveryHint, .recreateSession)
        XCTAssertEqual(DaveError.invalidDiscordUserId("invalid").recoveryHint, .fatal)

        let retry = DiscordDaveTransitionResult(
            outboundActions: [],
            mediaReady: false,
            recoveryHint: .retryLater,
            diagnostics: makeDiagnostics()
        )
        XCTAssertFalse(retry.needsRecovery)

        let recreate = DiscordDaveTransitionResult(
            outboundActions: [.invalidCommitWelcome(42)],
            mediaReady: false,
            recoveryHint: .recreateSession,
            diagnostics: makeDiagnostics()
        )
        XCTAssertTrue(recreate.needsRecovery)
    }

    func testOutboundActionPayloadsAreEquatableAndPreserved() {
        let payload = Data([0x01, 0x02, 0x03])

        XCTAssertEqual(
            DiscordDaveOutboundAction.mlsKeyPackage(payload),
            DiscordDaveOutboundAction.mlsKeyPackage(payload)
        )
        XCTAssertEqual(
            DiscordDaveOutboundAction.mlsCommitWelcome(payload),
            DiscordDaveOutboundAction.mlsCommitWelcome(payload)
        )
        XCTAssertEqual(
            DiscordDaveOutboundAction.transitionReady(42),
            DiscordDaveOutboundAction.transitionReady(42)
        )
        XCTAssertEqual(
            DiscordDaveOutboundAction.invalidCommitWelcome(42),
            DiscordDaveOutboundAction.invalidCommitWelcome(42)
        )
        XCTAssertNotEqual(
            DiscordDaveOutboundAction.transitionReady(42),
            DiscordDaveOutboundAction.transitionReady(43)
        )
    }

    func testCoordinatorLimitsClampUnsafeValues() {
        let limits = DaveCoordinatorLimits(
            maximumMlsPayloadBytes: 0,
            maximumRosterMembers: -1,
            maximumMediaFrameBytes: 0,
            maximumTrackedTransitions: -1,
            maximumPendingOutboundActions: 0
        )

        XCTAssertEqual(limits.maximumMlsPayloadBytes, 1)
        XCTAssertEqual(limits.maximumRosterMembers, 1)
        XCTAssertEqual(limits.maximumMediaFrameBytes, 1)
        XCTAssertEqual(limits.maximumTrackedTransitions, 1)
        XCTAssertEqual(limits.maximumPendingOutboundActions, 1)
    }

    func testGatewayOutboxEnvelopeUsesStableCallerSuppliedIdentifier() {
        let identifier = UUID(uuidString: "CDA660E2-B092-4D74-9AF9-11C8E2D6D3B0")!
        let envelope = DiscordDaveOutboundActionEnvelope(
            id: identifier,
            action: .transitionReady(42)
        )

        XCTAssertEqual(envelope.id, identifier)
        XCTAssertEqual(envelope.action, .transitionReady(42))
    }

    func testGatewayResultPreservesStablePendingEnvelope() {
        let identifier = UUID(uuidString: "8EAEC083-E5E8-4862-9687-1978056454A4")!
        let envelope = DiscordDaveOutboundActionEnvelope(
            id: identifier,
            action: .mlsKeyPackage(Data([0x01, 0x02]))
        )
        let result = DiscordDaveGatewayResult(
            pendingActions: [envelope],
            mediaReady: false,
            recoveryHint: .retryLater,
            diagnostics: makeDiagnostics()
        )

        XCTAssertEqual(result.pendingActions, [envelope])
        XCTAssertFalse(result.mediaReady)
        XCTAssertEqual(result.recoveryHint, .retryLater)
        XCTAssertFalse(result.needsRecovery)
    }

    func testPrepareEpochGatewayEventCarriesTransitionIdentity() {
        let event: DiscordDaveGatewayEvent = .prepareEpoch(
            protocolVersion: 1,
            epoch: 2,
            transitionId: 42
        )

        guard case let .prepareEpoch(protocolVersion, epoch, transitionId) = event else {
            return XCTFail("Expected Prepare Epoch gateway event")
        }
        XCTAssertEqual(protocolVersion, 1)
        XCTAssertEqual(epoch, 2)
        XCTAssertEqual(transitionId, 42)
    }

    func testPrepareEpochPublicHelperRequiresConfiguredSession() async {
        let coordinator = DaveSessionCoordinator()

        do {
            _ = try await coordinator.prepareDiscordEpoch(
                protocolVersion: 1,
                epoch: 2,
                transitionId: 42
            )
            XCTFail("Prepare Epoch without a session must be rejected")
        } catch let error as DaveError {
            guard case .notConfigured = error else {
                return XCTFail("Expected .notConfigured, got: \(error)")
            }
        } catch {
            XCTFail("Expected DaveError, got: \(error)")
        }
    }

    func testCoordinatorRejectsOversizedUntrustedInputsBeforeMediaOrMLSProcessing() async throws {
        let limits = DaveCoordinatorLimits(
            maximumMlsPayloadBytes: 2,
            maximumRosterMembers: 1,
            maximumMediaFrameBytes: 1
        )
        let coordinator = DaveSessionCoordinator(limits: limits)
        try await coordinator.configureForDiscordVoice(
            groupId: 9_002,
            selfUserId: "9002",
            protocolVersion: 1
        )

        do {
            try await coordinator.setExternalSender(Data([0x01, 0x02, 0x03]))
            XCTFail("Oversized external sender must not reach native MLS")
        } catch let error as DaveError {
            guard case .payloadTooLarge(let kind, let maximum, let actual) = error else {
                return XCTFail("Expected .payloadTooLarge, got: \(error)")
            }
            XCTAssertEqual(kind, "external sender")
            XCTAssertEqual(maximum, 2)
            XCTAssertEqual(actual, 3)
        }

        // Size validation is intentionally ahead of the media-readiness and
        // native-cryptor checks, so malformed RTP payloads fail predictably.
        do {
            _ = try await coordinator.encryptDiscordAudioFrame(Data([0x01, 0x02]), ssrc: 42)
            XCTFail("Oversized media must not reach the encryptor")
        } catch let error as DaveError {
            guard case .invalidMediaFrameSize(let actual, let maximum) = error else {
                return XCTFail("Expected .invalidMediaFrameSize, got: \(error)")
            }
            XCTAssertEqual(actual, 2)
            XCTAssertEqual(maximum, 1)
        }
    }

    func testCoordinatorValidatesGroupAndProtocolBeforeInitializingNativeState() async {
        let coordinator = DaveSessionCoordinator()

        do {
            try await coordinator.configureForDiscordVoice(
                groupId: 0,
                selfUserId: "9003",
                protocolVersion: 1
            )
            XCTFail("A zero Discord group ID must be rejected")
        } catch let error as DaveError {
            guard case .invalidDiscordGroupId(0) = error else {
                return XCTFail("Expected .invalidDiscordGroupId, got: \(error)")
            }
        } catch {
            XCTFail("Expected DaveError, got: \(error)")
        }

        do {
            try await coordinator.configureForDiscordVoice(
                groupId: 9_003,
                selfUserId: "9003",
                protocolVersion: 0
            )
            XCTFail("An unsupported protocol version must be rejected")
        } catch let error as DaveError {
            guard case .unsupportedProtocolVersion(let requested, let maximum) = error else {
                return XCTFail("Expected .unsupportedProtocolVersion, got: \(error)")
            }
            XCTAssertEqual(requested, 0)
            XCTAssertGreaterThanOrEqual(maximum, 1)
        } catch {
            XCTFail("Expected DaveError, got: \(error)")
        }
    }

    func testMediaReadinessWatchdogFailsClosedWithoutPolling() async throws {
        let coordinator = DaveSessionCoordinator()
        try await coordinator.configureForDiscordVoice(
            groupId: 9_004,
            selfUserId: "9004",
            protocolVersion: 1
        )
        try await coordinator.setPassthroughMode(true)
        _ = await coordinator.markDiscordMediaReady(reason: "watchdog setup")

        let frame = Data([0x01])
        let initialCiphertext = try await coordinator.encryptDiscordAudioFrame(frame, ssrc: 42)
        XCTAssertEqual(initialCiphertext, frame)

        _ = await coordinator.markDiscordMediaNotReady(
            reason: "autonomous watchdog test",
            timeout: 0.01
        )
        // No `evaluateMediaReadinessWatchdog()` call: the coordinator-owned
        // task itself must revoke the media capability after the deadline.
        try await Task.sleep(for: .milliseconds(100))

        let diagnostics = await coordinator.getDiagnostics()
        XCTAssertEqual(diagnostics.handshakeState, .failed)
        XCTAssertFalse(diagnostics.mediaReady)
        XCTAssertEqual(diagnostics.lastRecoveryAction, .failClosed)
        XCTAssertNotNil(diagnostics.lastMlsError)

        do {
            _ = try await coordinator.encryptDiscordAudioFrame(frame, ssrc: 42)
            XCTFail("Expired watchdog must block further media")
        } catch let error as DaveError {
            guard case .mediaNotReady = error else {
                return XCTFail("Expected .mediaNotReady after watchdog expiry, got: \(error)")
            }
        }
    }

    func testNegativeCapacityRequestsNeverReachUnsignedNativeParameters() throws {
        let encryptor = try DaveEncryptor()
        let decryptor = try DaveDecryptor()

        XCTAssertEqual(encryptor.maxCiphertextByteSize(mediaType: .audio, frameSize: -1), 0)
        XCTAssertEqual(decryptor.maxPlaintextByteSize(mediaType: .audio, encryptedFrameSize: -1), 0)
    }

    private func makeDiagnostics() -> DaveDiagnostics {
        DaveDiagnostics(
            protocolVersion: 1,
            appliedTransitionCount: 0,
            handshakeState: .initialized,
            encryptionStats: nil,
            lastMlsError: nil,
            lastTransitionTimestamp: nil,
            isExternalSenderRegistered: false
        )
    }
}
