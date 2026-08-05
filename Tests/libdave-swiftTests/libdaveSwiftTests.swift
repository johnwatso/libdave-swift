import XCTest
@testable import libdave_swift

final class libdaveSwiftTests: XCTestCase {

    func testSupportedProtocolVersion() {
        let version = DaveSession.maxSupportedProtocolVersion
        XCTAssertGreaterThanOrEqual(version, 1, "Supported protocol version should be at least 1")
        print("Max Supported Protocol Version: \(version)")
    }

    func testSessionCreationAndInitialization() {
        let failure = LockedBox(FailureCapture())

        do {
            let session = try DaveSession(authSessionId: nil) { source, reason in
                failure.set(FailureCapture(logged: true, source: source, reason: reason))
            }

            XCTAssertNotNil(session, "Session should not be nil")

            // Initialize session with group details
            session.initialize(version: 1, groupId: 12345, selfUserId: "123456789012345678")

            // Verify version is as set
            XCTAssertEqual(session.protocolVersion, 1, "Session protocol version should be 1")

            // Reset session
            session.reset()
            XCTAssertEqual(session.protocolVersion, 0, "Protocol version should reset to 0 after reset")

            let capturedFailure = failure.value
            XCTAssertFalse(
                capturedFailure.logged,
                "MLS failures should not have been logged: \(capturedFailure.source) - \(capturedFailure.reason)"
            )

        } catch {
            XCTFail("Failed to create DAVE session with error: \(error.localizedDescription)")
        }
    }

    func testEncryptorDecryptorCreationAndProperties() {
        do {
            let encryptor = try DaveEncryptor()
            let decryptor = try DaveDecryptor()

            XCTAssertNotNil(encryptor)
            XCTAssertNotNil(decryptor)

            // Passthrough is false by default
            XCTAssertFalse(encryptor.isPassthroughMode)
            XCTAssertFalse(encryptor.hasKeyRatchet)

            // Enable passthrough mode
            encryptor.setPassthroughMode(true)
            decryptor.transitionToPassthroughMode(true)

            XCTAssertTrue(encryptor.isPassthroughMode)

            // Test max ciphertext sizing
            let maxCipherCapacity = encryptor.maxCiphertextByteSize(mediaType: .audio, frameSize: 100)
            XCTAssertGreaterThanOrEqual(maxCipherCapacity, 100)

            let maxPlainCapacity = decryptor.maxPlaintextByteSize(mediaType: .audio, encryptedFrameSize: 100)
            XCTAssertGreaterThanOrEqual(maxPlainCapacity, 100)

        } catch {
            XCTFail("Failed encryptor/decryptor setup: \(error.localizedDescription)")
        }
    }

    func testPassthroughEncryptionDecryption() {
        do {
            let encryptor = try DaveEncryptor()
            let decryptor = try DaveDecryptor()

            encryptor.setPassthroughMode(true)
            decryptor.transitionToPassthroughMode(true)

            let originalFrame = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])

            // SSRC assigns to codec
            encryptor.assignSsrcToCodec(ssrc: 9999, codec: .opus)

            // Encrypt in passthrough mode (returns the exact same bytes)
            let encrypted = try encryptor.encrypt(mediaType: .audio, ssrc: 9999, frame: originalFrame)
            XCTAssertEqual(encrypted, originalFrame, "In passthrough mode, encrypted frame should match original")

            // Decrypt in passthrough mode
            let decrypted = try decryptor.decrypt(mediaType: .audio, encryptedFrame: encrypted)
            XCTAssertEqual(decrypted, originalFrame, "Decrypted frame should match original")

            // Verify stats
            let encStats = encryptor.stats(mediaType: .audio)
            XCTAssertEqual(encStats.passthroughCount, 1)

            let decStats = decryptor.stats(mediaType: .audio)
            XCTAssertEqual(decStats.passthroughCount, 1)

        } catch {
            XCTFail("Passthrough encryption/decryption failed: \(error.localizedDescription)")
        }
    }

    func testLoggerRegistration() {
        let logReceived = LockedBox(false)
        DaveLogger.setLogSink(minSeverity: .verbose) { severity, file, line, message in
            logReceived.set(true)
            print("[\(severity)] [\(file):\(line)] \(message)")
        }
        
        // Trigger a log by creating a session (session creation prints logs)
        _ = try? DaveSession(authSessionId: nil) { _, _ in }
        
        DaveLogger.removeLogSink()
        XCTAssertTrue(logReceived.value, "The log sink should have received at least one C++ log message")
    }

    // MARK: - New Expanded Tests for Improvements

    func testCoordinatorConcurrentPassthroughEncryption() async throws {
        let coordinator = DaveSessionCoordinator()
        try await coordinator.configureForDiscordVoice(groupId: 12345, selfUserId: "123456789012345678", protocolVersion: 1)
        try await coordinator.setPassthroughMode(true)
        _ = await coordinator.markDiscordMediaReady(reason: "passthrough test setup")

        let originalFrame = Data([0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff])

        // Spawn 50 concurrent tasks requesting encryption
        await withTaskGroup(of: Data?.self) { group in
            for i in 0..<50 {
                group.addTask {
                    do {
                        return try await coordinator.encryptDiscordAudioFrame(originalFrame, ssrc: UInt32(1000 + i))
                    } catch {
                        return nil
                    }
                }
            }

            for await result in group {
                XCTAssertNotNil(result, "Encryption should succeed in passthrough mode")
                XCTAssertEqual(result, originalFrame, "Passthrough encryption should return original frame")
            }
        }
    }

    func testCoordinatorResetAndDiagnostics() async throws {
        let coordinator = DaveSessionCoordinator()

        // Before configuration
        var diagnostics = await coordinator.getDiagnostics()
        XCTAssertEqual(diagnostics.handshakeState, .uninitialized)
        XCTAssertEqual(diagnostics.appliedTransitionCount, 0)
        XCTAssertFalse(diagnostics.isExternalSenderRegistered)

        // Configure
        try await coordinator.configureForDiscordVoice(groupId: 9999, selfUserId: "999", protocolVersion: 1)
        diagnostics = await coordinator.getDiagnostics()
        XCTAssertEqual(diagnostics.handshakeState, .initialized)
        XCTAssertEqual(diagnostics.protocolVersion, 1)

        // Arbitrary bytes must never masquerade as a valid Discord-issued
        // external sender. A synchronous native parse failure fails closed.
        let mockExternalSender = Data([1, 2, 3, 4, 5])
        do {
            try await coordinator.setExternalSender(mockExternalSender)
            XCTFail("Malformed external-sender bytes must be rejected")
        } catch let error as DaveError {
            guard case .externalSenderRejected = error else {
                return XCTFail("Expected .externalSenderRejected, got: \(error)")
            }
        }
        diagnostics = await coordinator.getDiagnostics()
        XCTAssertEqual(diagnostics.handshakeState, .failed)
        XCTAssertFalse(diagnostics.isExternalSenderRegistered)
        XCTAssertEqual(diagnostics.externalSenderState, .missing)
        XCTAssertEqual(diagnostics.lastRecoveryAction, .failClosed)

        // Reset
        await coordinator.reset()
        diagnostics = await coordinator.getDiagnostics()
        XCTAssertEqual(diagnostics.handshakeState, .uninitialized)
        XCTAssertEqual(diagnostics.appliedTransitionCount, 0)
        XCTAssertFalse(diagnostics.isExternalSenderRegistered)
    }

    func testCoordinatorResetDiscardsOutboundCryptor() async throws {
        let coordinator = DaveSessionCoordinator()
        try await coordinator.configureForDiscordVoice(groupId: 9753, selfUserId: "9753", protocolVersion: 1)
        try await coordinator.setPassthroughMode(true)
        _ = await coordinator.markDiscordMediaReady(reason: "passthrough test setup")

        let frame = Data([0xaa, 0xbb])
        let firstCiphertext = try await coordinator.encryptDiscordAudioFrame(frame, ssrc: 1)
        XCTAssertEqual(firstCiphertext, frame)

        await coordinator.reset()
        do {
            _ = try await coordinator.encryptDiscordAudioFrame(frame, ssrc: 1)
            XCTFail("Reset must keep media paused")
        } catch let error as DaveError {
            guard case .mediaNotReady = error else {
                return XCTFail("Expected .mediaNotReady after reset, got: \(error)")
            }
        }

        // Once media is explicitly allowed again, the missing encryptor from
        // the discarded generation must still prevent outbound media.
        _ = await coordinator.markDiscordMediaReady(reason: "verify reset discarded encryptor")
        do {
            _ = try await coordinator.encryptDiscordAudioFrame(frame, ssrc: 1)
            XCTFail("Reset must discard the encryptor and fail closed")
        } catch let error as DaveError {
            guard case .invalidState = error else {
                return XCTFail("Expected .invalidState after reset, got: \(error)")
            }
        }

        try await coordinator.recreateSessionState()
        let diagnosticsAfterRecreation = await coordinator.getDiagnostics()
        XCTAssertEqual(diagnosticsAfterRecreation.protocolVersion, 1)
        try await coordinator.setPassthroughMode(true)
        _ = await coordinator.markDiscordMediaReady(reason: "passthrough test recreation")
        let recreatedCiphertext = try await coordinator.encryptDiscordAudioFrame(frame, ssrc: 1)
        XCTAssertEqual(recreatedCiphertext, frame)
    }

    func testCoordinatorRejectsInvalidDiscordUserIds() async throws {
        let coordinator = DaveSessionCoordinator()

        do {
            try await coordinator.configureForDiscordVoice(groupId: 7654, selfUserId: "not-a-snowflake", protocolVersion: 1)
            XCTFail("Expected invalid Discord user ID to be rejected")
        } catch let error as DaveError {
            guard case .invalidDiscordUserId("not-a-snowflake") = error else {
                return XCTFail("Expected .invalidDiscordUserId, got: \(error)")
            }
        }

        try await coordinator.configureForDiscordVoice(groupId: 7654, selfUserId: "7654", protocolVersion: 1)
        _ = await coordinator.markDiscordMediaReady(reason: "validate remote user ID")

        do {
            _ = try await coordinator.decryptDiscordAudioFrame(Data([1, 2, 3]), from: "remote-user")
            XCTFail("Expected invalid remote user ID to be rejected")
        } catch let error as DaveError {
            guard case .invalidDiscordUserId("remote-user") = error else {
                return XCTFail("Expected .invalidDiscordUserId, got: \(error)")
            }
        }
    }

    func testCoordinatorRejectsEmptyExternalSender() async throws {
        let coordinator = DaveSessionCoordinator()
        try await coordinator.configureForDiscordVoice(groupId: 7655, selfUserId: "7655", protocolVersion: 1)

        do {
            try await coordinator.setExternalSender(Data())
            XCTFail("Expected an empty external sender to be rejected")
        } catch let error as DaveError {
            guard case .invalidExternalSender = error else {
                return XCTFail("Expected .invalidExternalSender, got: \(error)")
            }
        }

        let diagnostics = await coordinator.getDiagnostics()
        XCTAssertEqual(diagnostics.externalSenderState, .missing)
        XCTAssertFalse(diagnostics.isExternalSenderRegistered)
    }

    func testCoordinatorInvalidTransitions() async throws {
        let coordinator = DaveSessionCoordinator()

        // Attempt transition before configuration -> notConfigured error
        do {
            try await coordinator.processDiscordTransition(.commit(Data([0, 1, 2])))
            XCTFail("Should have thrown DaveError.notConfigured")
        } catch let error as DaveError {
            if case .notConfigured = error {
                // Success
            } else {
                XCTFail("Expected .notConfigured error, got: \(error)")
            }
        } catch {
            XCTFail("Expected DaveError, got: \(error)")
        }

        // Configure
        try await coordinator.configureForDiscordVoice(groupId: 1111, selfUserId: "111", protocolVersion: 1)

        // Malformed native transitions fail closed. The exact original error
        // can be a handshake failure or a raced callback's sessionFailed, but
        // the postcondition is always a failed coordinator.
        do {
            try await coordinator.processDiscordTransition(.welcome(Data([0, 1, 2]), recognizedUserIds: ["111"]))
            XCTFail("Malformed Welcome must be rejected")
        } catch let error as DaveError {
            switch error {
            case .handshakeFailed, .sessionFailed:
                break
            default:
                XCTFail("Expected a fail-closed Welcome error, got: \(error)")
            }
        } catch {
            XCTFail("Expected DaveError, got: \(error)")
        }
        var diagnostics = await coordinator.getDiagnostics()
        XCTAssertEqual(diagnostics.handshakeState, .failed)
        XCTAssertEqual(diagnostics.lastRecoveryAction, .failClosed)

        // A new session generation is required before consuming another
        // transition after failure.
        try await coordinator.recreateSessionState()

        // Invalid Commit transition has the same fail-closed contract.
        do {
            try await coordinator.processDiscordTransition(.commit(Data([0, 1, 2])))
            XCTFail("Malformed Commit must be rejected")
        } catch let error as DaveError {
            switch error {
            case .handshakeFailed, .sessionFailed:
                break
            default:
                XCTFail("Expected a fail-closed Commit error, got: \(error)")
            }
        } catch {
            XCTFail("Expected DaveError, got: \(error)")
        }
        diagnostics = await coordinator.getDiagnostics()
        XCTAssertEqual(diagnostics.handshakeState, .failed)
        XCTAssertEqual(diagnostics.lastRecoveryAction, .failClosed)
    }

    func testCoordinatorRejectsEmptyTransitions() async throws {
        let coordinator = DaveSessionCoordinator()
        try await coordinator.configureForDiscordVoice(groupId: 2222, selfUserId: "222", protocolVersion: 1)

        func assertInvalidTransition(
            _ block: () async throws -> Void,
            _ label: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            do {
                try await block()
                XCTFail("Should have thrown .invalidTransition for \(label)", file: file, line: line)
            } catch let error as DaveError {
                guard case .invalidTransition = error else {
                    return XCTFail("Expected .invalidTransition for \(label), got: \(error)", file: file, line: line)
                }
            } catch {
                XCTFail("Expected DaveError for \(label), got: \(error)", file: file, line: line)
            }
        }

        // Empty payloads are rejected before crossing into native code, so a
        // malformed/empty announcement can never wedge a native call.
        await assertInvalidTransition({
            try await coordinator.processDiscordTransition(.commit(Data()))
        }, "empty commit")
        var diagnostics = await coordinator.getDiagnostics()
        XCTAssertEqual(diagnostics.handshakeState, .failed)
        try await coordinator.recreateSessionState()

        await assertInvalidTransition({
            try await coordinator.processDiscordTransition(.welcome(Data(), recognizedUserIds: ["222"]))
        }, "empty welcome")
        diagnostics = await coordinator.getDiagnostics()
        XCTAssertEqual(diagnostics.handshakeState, .failed)
        try await coordinator.recreateSessionState()

        await assertInvalidTransition({
            _ = try await coordinator.processProposals(Data(), recognizedUserIds: ["222"])
        }, "empty proposals")
        diagnostics = await coordinator.getDiagnostics()
        XCTAssertEqual(diagnostics.handshakeState, .initialized)
    }

    func testCoordinatorHighLevelDiagnosticsAndWatchdog() async throws {
        let coordinator = DaveSessionCoordinator()

        let configured = try await coordinator.configureDiscordVoiceSession(
            groupId: 3333,
            selfUserId: "333",
            protocolVersion: 1
        )
        XCTAssertEqual(configured.recoveryHint, .waitForExternalSender)
        XCTAssertFalse(configured.needsRecovery)
        XCTAssertFalse(configured.mediaReady)
        XCTAssertEqual(configured.diagnostics.externalSenderState, .missing)
        XCTAssertFalse(configured.diagnostics.hasSentInitialKeyPackage)

        // Do not fabricate MLS credentials in a unit test. Publishing is
        // explicitly blocked until a real Discord external sender arrives.
        do {
            _ = try await coordinator.publishDiscordInitialKeyPackage()
            XCTFail("Initial key package must require a Discord external sender")
        } catch let error as DaveError {
            guard case .externalSenderRequired = error else {
                return XCTFail("Expected .externalSenderRequired, got: \(error)")
            }
        }

        var diagnostics = await coordinator.getDiagnostics()
        XCTAssertFalse(diagnostics.hasIssuedInitialKeyPackage)
        XCTAssertFalse(diagnostics.hasSentInitialKeyPackage)

        let pending = await coordinator.markDiscordMediaNotReady(
            reason: "unit test refresh",
            pendingTransitionId: 44,
            pendingEpoch: 2,
            timeout: 5
        )
        guard case .pending(let secondsRemaining) = pending else {
            return XCTFail("Expected watchdog to be pending")
        }
        XCTAssertGreaterThan(secondsRemaining, 0)
        XCTAssertLessThanOrEqual(secondsRemaining, 5)

        diagnostics = await coordinator.getDiagnostics()
        XCTAssertFalse(diagnostics.mediaReady)
        XCTAssertEqual(diagnostics.pendingTransitionId, 44)
        XCTAssertEqual(diagnostics.pendingEpoch, 2)
        XCTAssertEqual(diagnostics.lastRecoveryAction, .pauseMedia)

        // A pending transition ID is a safety boundary. Manual readiness must
        // not bypass the matching Execute Transition and revive stale media.
        let ready = await coordinator.markDiscordMediaReady(reason: "unit test complete")
        guard case .pending(let remaining) = ready else {
            return XCTFail("Manual readiness must not override a pending transition")
        }
        XCTAssertGreaterThan(remaining, 0)
        diagnostics = await coordinator.getDiagnostics()
        XCTAssertFalse(diagnostics.mediaReady)
        XCTAssertEqual(diagnostics.pendingTransitionId, 44)
        XCTAssertEqual(diagnostics.pendingEpoch, 2)
        XCTAssertEqual(diagnostics.lastRecoveryAction, .pauseMedia)

        // Cancel the scheduled watchdog explicitly so this test does not leave
        // a delayed task alive after the coordinator's intended assertion.
        await coordinator.reset()
    }

    /// A paused Discord transition must block both media directions even when
    /// passthrough is enabled. This exercises the coordinator gate without
    /// requiring a real MLS welcome/commit fixture.
    func testCoordinatorMediaReadinessGatesPassthroughFrames() async throws {
        let coordinator = DaveSessionCoordinator()
        try await coordinator.configureForDiscordVoice(groupId: 3456, selfUserId: "3456", protocolVersion: 1)
        try await coordinator.setPassthroughMode(true)

        let frame = Data([0x01, 0x02, 0x03])

        func assertMediaNotReady(
            _ operation: () async throws -> Void,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            do {
                try await operation()
                XCTFail("Expected media operation to be gated while media is paused", file: file, line: line)
            } catch let error as DaveError {
                guard case .mediaNotReady = error else {
                    return XCTFail("Expected .mediaNotReady, got: \(error)", file: file, line: line)
                }
            } catch {
                XCTFail("Expected DaveError.mediaNotReady, got: \(error)", file: file, line: line)
            }
        }

        await assertMediaNotReady({
            _ = try await coordinator.encryptDiscordAudioFrame(frame, ssrc: 42)
        })
        await assertMediaNotReady({
            _ = try await coordinator.decryptDiscordAudioFrame(frame, from: "9001")
        })

        _ = await coordinator.markDiscordMediaReady(reason: "passthrough test setup")
        let encrypted = try await coordinator.encryptDiscordAudioFrame(frame, ssrc: 42)
        XCTAssertEqual(encrypted, frame)
        let decrypted = try await coordinator.decryptDiscordAudioFrame(encrypted, from: "9001")
        XCTAssertEqual(decrypted, frame)

        _ = await coordinator.markDiscordMediaNotReady(reason: "test transition")
        await assertMediaNotReady({
            _ = try await coordinator.encryptDiscordAudioFrame(frame, ssrc: 42)
        })
        await assertMediaNotReady({
            _ = try await coordinator.decryptDiscordAudioFrame(frame, from: "9001")
        })
    }

    /// Receiving an execute-transition signal before MLS has established a
    /// ratchet must not resume media just because the signal was received.
    func testExecuteDiscordTransitionStaysPausedBeforeHandshakeIsReady() async throws {
        let coordinator = DaveSessionCoordinator()
        try await coordinator.configureForDiscordVoice(groupId: 3457, selfUserId: "3457", protocolVersion: 1)
        try await coordinator.setPassthroughMode(true)

        let result = await coordinator.executeDiscordTransition(77)
        XCTAssertEqual(result.recoveryHint, .retryLater)
        XCTAssertFalse(result.mediaReady)
        XCTAssertEqual(result.diagnostics.pendingTransitionId, 77)

        do {
            _ = try await coordinator.encryptDiscordAudioFrame(Data([0x04]), ssrc: 77)
            XCTFail("Media must remain gated until the handshake is ready")
        } catch let error as DaveError {
            guard case .mediaNotReady = error else {
                return XCTFail("Expected .mediaNotReady, got: \(error)")
            }
        }
    }

    // MARK: - Inbound media (decrypt path)

    // A true encrypted round-trip cannot run in unit tests: the native library
    // only derives key ratchets once a real MLS group exists, which requires
    // Discord's external sender to complete a handshake. Passthrough exercises
    // the same coordinator decryptor lifecycle and native decrypt call.
    func testCoordinatorPassthroughDecryptRoundTrip() async throws {
        let coordinator = DaveSessionCoordinator()
        try await coordinator.configureForDiscordVoice(groupId: 6666, selfUserId: "666", protocolVersion: 1)
        try await coordinator.setPassthroughMode(true)
        _ = await coordinator.markDiscordMediaReady(reason: "passthrough test setup")

        let frame = Data([0x10, 0x20, 0x30, 0x40, 0x50])
        let encrypted = try await coordinator.encryptDiscordAudioFrame(frame, ssrc: 777)
        XCTAssertEqual(encrypted, frame)

        // The remote user's decryptor is created lazily on first decrypt and
        // follows the coordinator's passthrough mode.
        let decrypted = try await coordinator.decryptDiscordAudioFrame(encrypted, from: "1001")
        XCTAssertEqual(decrypted, frame)

        let maybeStats = await coordinator.decryptorStats(for: "1001")
        let stats = try XCTUnwrap(maybeStats)
        XCTAssertEqual(stats.passthroughCount, 1)

        // No decryptor exists for a user we never received a frame from.
        let missing = await coordinator.decryptorStats(for: "1002")
        XCTAssertNil(missing)
    }

    func testCoordinatorResetDiscardsInboundDecryptors() async throws {
        let coordinator = DaveSessionCoordinator()
        try await coordinator.configureForDiscordVoice(groupId: 6667, selfUserId: "6667", protocolVersion: 1)
        try await coordinator.setPassthroughMode(true)
        _ = await coordinator.markDiscordMediaReady(reason: "passthrough test setup")

        _ = try await coordinator.decryptDiscordAudioFrame(Data([0x20]), from: "1005")
        let existingStats = await coordinator.decryptorStats(for: "1005")
        XCTAssertNotNil(existingStats)

        await coordinator.reset()
        let discardedStats = await coordinator.decryptorStats(for: "1005")
        XCTAssertNil(discardedStats)
    }

    func testCoordinatorDecryptRequiresConfiguration() async throws {
        let coordinator = DaveSessionCoordinator()
        do {
            _ = try await coordinator.decryptDiscordAudioFrame(Data([1, 2, 3]), from: "remote-user")
            XCTFail("Should have thrown DaveError.notConfigured")
        } catch let error as DaveError {
            guard case .notConfigured = error else {
                return XCTFail("Expected .notConfigured, got: \(error)")
            }
        }
    }

    func testCoordinatorDecryptWithoutRatchetThrowsTypedError() async throws {
        let coordinator = DaveSessionCoordinator()
        try await coordinator.configureForDiscordVoice(groupId: 7777, selfUserId: "777", protocolVersion: 1)
        _ = await coordinator.markDiscordMediaReady(reason: "exercise missing ratchet error")

        // No MLS group is established, so the remote user has no ratchet and
        // passthrough is off: decrypt must fail with a typed DaveError the
        // host can map to a recovery hint, never trap or return garbage.
        do {
            _ = try await coordinator.decryptDiscordAudioFrame(Data([9, 9, 9, 9]), from: "1003")
            XCTFail("Should have thrown DaveError.decryptionFailed")
        } catch let error as DaveError {
            guard case .decryptionFailed = error else {
                return XCTFail("Expected .decryptionFailed, got: \(error)")
            }
        }
    }

    func testAsyncPairwiseFingerprint() async throws {
        // Without an established MLS group the native library reports no
        // fingerprint; the async wrappers must resume with nil, not hang.
        let session = try DaveSession(authSessionId: nil) { _, _ in }
        session.initialize(version: 1, groupId: 8888, selfUserId: "888")
        let fingerprint = await session.pairwiseFingerprint(version: 0, userId: "1004")
        XCTAssertNil(fingerprint)

        let coordinator = DaveSessionCoordinator()
        do {
            _ = try await coordinator.pairwiseFingerprint(version: 0, userId: "1004")
            XCTFail("Should have thrown DaveError.notConfigured before configuration")
        } catch let error as DaveError {
            guard case .notConfigured = error else {
                return XCTFail("Expected .notConfigured, got: \(error)")
            }
        }

        try await coordinator.configureForDiscordVoice(groupId: 8888, selfUserId: "888", protocolVersion: 1)
        let coordinatorFingerprint = try await coordinator.pairwiseFingerprint(version: 0, userId: "1004")
        XCTAssertNil(coordinatorFingerprint)
    }

    func testDaveErrorRecoveryHints() {
        XCTAssertEqual(DaveError.sessionCreationFailed.recoveryHint, .fatal)
        XCTAssertEqual(DaveError.handshakeFailed(reason: "bad welcome").recoveryHint, .sendInvalidCommitWelcome)
        XCTAssertEqual(DaveError.invalidTransition(message: "empty").recoveryHint, .sendInvalidCommitWelcome)
        XCTAssertEqual(DaveError.ratchetFailed(userId: "user", reason: "missing").recoveryHint, .recreateSession)
        XCTAssertEqual(DaveError.encryptionFailed(reason: .missingKeyRatchet).recoveryHint, .retryLater)
        XCTAssertEqual(DaveError.encryptionFailed(reason: .encryptionFailure).recoveryHint, .recreateSession)
        XCTAssertEqual(DaveError.mediaNotReady.recoveryHint, .retryLater)
        XCTAssertEqual(DaveError.invalidExternalSender.recoveryHint, .waitForExternalSender)
        XCTAssertEqual(DaveError.invalidDiscordUserId("bad").recoveryHint, .fatal)
        XCTAssertEqual(DaveError.notConfigured.recoveryHint, .fatal)
    }

    func testHighLevelInvalidTransitionRecoveryEmitsGatewayActions() async throws {
        let coordinator = DaveSessionCoordinator()
        try await coordinator.configureForDiscordVoice(groupId: 4444, selfUserId: "444", protocolVersion: 1)

        let result = try await coordinator.processDiscordCommitForOutbound(
            Data(),
            transitionId: 88,
            recoveryTimeout: 0.5
        )

        XCTAssertEqual(result.recoveryHint, .waitForExternalSender)
        XCTAssertFalse(result.needsRecovery)
        XCTAssertFalse(result.mediaReady)
        XCTAssertEqual(result.outboundActions.count, 1)
        guard case .invalidCommitWelcome(88) = result.outboundActions[0] else {
            return XCTFail("Expected invalid commit/welcome recovery action first")
        }
        XCTAssertFalse(result.diagnostics.hasIssuedInitialKeyPackage)
        XCTAssertFalse(result.diagnostics.hasSentInitialKeyPackage)
        XCTAssertEqual(result.diagnostics.pendingTransitionId, 88)
        XCTAssertEqual(result.diagnostics.externalSenderState, .missing)
        XCTAssertEqual(result.diagnostics.lastRecoveryAction, .invalidTransitionRecovery)
    }

    func testMediaReadinessWatchdogTimesOut() async throws {
        let coordinator = DaveSessionCoordinator()
        try await coordinator.configureForDiscordVoice(groupId: 5555, selfUserId: "555", protocolVersion: 1)

        _ = await coordinator.markDiscordMediaNotReady(reason: "watchdog unit test", timeout: 0.01)
        let timedOut = await coordinator.evaluateMediaReadinessWatchdog(now: Date().addingTimeInterval(1))
        guard case .timedOut(let reason, let recoveryHint) = timedOut else {
            return XCTFail("Expected watchdog timeout")
        }
        XCTAssertEqual(reason, "watchdog unit test")
        XCTAssertEqual(recoveryHint, .recreateSession)

        _ = await coordinator.markDiscordMediaReady(reason: "watchdog unit test complete")
        let inactive = await coordinator.evaluateMediaReadinessWatchdog(now: Date().addingTimeInterval(2))
        XCTAssertEqual(inactive, .inactive)
    }

    // MARK: - Persisted signature key pairs

    /// A session configured with an `authSessionId` must be able to marshal
    /// its MLS key package. This is the regression that shipped in builds
    /// carrying the null persisted-key backend: `GetPersistedKeyPair`
    /// returned nothing, leaf-node init aborted, and every key-package
    /// request failed with "Failed to generate marshalled key package".
    func testAuthSessionIdProducesKeyPackageAndPersistsKeyFile() async throws {
        let keyStore = try makeTemporaryKeyStore()
        defer { XCTAssertNoThrow(try keyStore.close()) }

        let coordinator = DaveSessionCoordinator(authSessionId: "persist-test-\(UUID().uuidString)")
        _ = try await coordinator.configureDiscordVoiceSession(
            groupId: 424242,
            selfUserId: "424242424242424242",
            protocolVersion: 1
        )

        let keyPackage = try await coordinator.getMarshalledKeyPackage()
        XCTAssertFalse(keyPackage.isEmpty, "session with authSessionId must yield a key package")

        let storageDir = keyStore.root.appendingPathComponent("Discord Key Storage")
        let stored = (try? FileManager.default.contentsOfDirectory(atPath: storageDir.path)) ?? []
        XCTAssertFalse(stored.isEmpty, "a signature key file must be persisted to the key store")
    }

    /// The persisted key file must be reused, not regenerated, by later
    /// sessions with the same auth session id.
    func testPersistedKeyFileIsStableAcrossSessions() async throws {
        let keyStore = try makeTemporaryKeyStore()
        defer { XCTAssertNoThrow(try keyStore.close()) }

        let authSessionId = "persist-stable-\(UUID().uuidString)"
        let first = DaveSessionCoordinator(authSessionId: authSessionId)
        _ = try await first.configureDiscordVoiceSession(groupId: 1, selfUserId: "111111111111111111", protocolVersion: 1)
        _ = try await first.getMarshalledKeyPackage()

        let storageDir = keyStore.root.appendingPathComponent("Discord Key Storage")
        let files = try FileManager.default.contentsOfDirectory(atPath: storageDir.path)
        let keyFile = try XCTUnwrap(files.first)
        let originalContents = try Data(contentsOf: storageDir.appendingPathComponent(keyFile))

        let second = DaveSessionCoordinator(authSessionId: authSessionId)
        _ = try await second.configureDiscordVoiceSession(groupId: 2, selfUserId: "111111111111111111", protocolVersion: 1)
        _ = try await second.getMarshalledKeyPackage()

        let laterContents = try Data(contentsOf: storageDir.appendingPathComponent(keyFile))
        XCTAssertEqual(originalContents, laterContents, "the persisted signature key must be reused, not rewritten")
    }

    /// Sessions with no auth session id keep working with ephemeral keys and
    /// never touch the key store.
    func testNilAuthSessionIdStillYieldsKeyPackage() async throws {
        let keyStore = try makeTemporaryKeyStore()
        defer { XCTAssertNoThrow(try keyStore.close()) }

        let coordinator = DaveSessionCoordinator(authSessionId: nil)
        _ = try await coordinator.configureDiscordVoiceSession(
            groupId: 434343,
            selfUserId: "434343434343434343",
            protocolVersion: 1
        )
        let keyPackage = try await coordinator.getMarshalledKeyPackage()
        XCTAssertFalse(keyPackage.isEmpty)

        let storageDir = keyStore.root.appendingPathComponent("Discord Key Storage")
        let stored = (try? FileManager.default.contentsOfDirectory(atPath: storageDir.path)) ?? []
        XCTAssertTrue(stored.isEmpty, "ephemeral sessions must not write to the key store")
    }

    /// Point the generic key store at a fresh temp directory via
    /// XDG_CONFIG_HOME (read by the backend on every lookup). The scope
    /// restores a caller-provided config path exactly, rather than assuming
    /// the variable was initially unset, and removes its temporary directory.
    private func makeTemporaryKeyStore() throws -> TemporaryKeyStore {
        try TemporaryKeyStore()
    }

    func testMalformedExternalSenderReplayFixtureFailsClosed() async throws {
        let fixtureURL = try XCTUnwrap(Bundle.module.url(
            forResource: "discord-dave-recovery-sequence",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        let data = try Data(contentsOf: fixtureURL)
        let events = try JSONDecoder().decode([DiscordDaveReplayEvent].self, from: data)
        let coordinator = DaveSessionCoordinator()

        var sawNativeSenderFailure = false
        for event in events {
            switch event.event {
            case "configure":
                let result = try await coordinator.configureDiscordVoiceSession(
                    groupId: try XCTUnwrap(event.groupId),
                    selfUserId: try XCTUnwrap(event.selfUserId),
                    protocolVersion: try XCTUnwrap(event.protocolVersion)
                )
                XCTAssertEqual(result.recoveryHint, .waitForExternalSender)

            case "externalSender":
                let externalSender = try dataFromHex(try XCTUnwrap(event.externalSenderHex))
                do {
                    _ = try await coordinator.registerDiscordExternalSender(
                        externalSender,
                        publishInitialKeyPackage: false
                    )
                    XCTFail("Malformed external-sender bytes must not be accepted")
                } catch let error as DaveError {
                    guard event.expectedError == "externalSenderRejected",
                          case .externalSenderRejected(let reason) = error else {
                        return XCTFail("Expected \(event.expectedError ?? "a DaveError"), got: \(error)")
                    }
                    XCTAssertFalse(reason.isEmpty)
                    sawNativeSenderFailure = true
                }

            case "prepareEpoch":
                do {
                    _ = try await coordinator.prepareDiscordEpoch(
                        protocolVersion: try XCTUnwrap(event.protocolVersion),
                        epoch: try XCTUnwrap(event.epoch),
                        transitionId: try XCTUnwrap(event.transitionId)
                    )
                    XCTFail("A failed MLS session must reject later Prepare Epoch events")
                } catch let error as DaveError {
                    guard event.expectedError == "sessionFailed", case .sessionFailed = error else {
                        return XCTFail("Expected \(event.expectedError ?? "a DaveError"), got: \(error)")
                    }
                }

            default:
                XCTFail("Unknown replay event: \(event.event)")
            }
        }

        let diagnostics = await coordinator.getDiagnostics()
        XCTAssertTrue(sawNativeSenderFailure)
        XCTAssertEqual(diagnostics.handshakeState, .failed)
        XCTAssertEqual(diagnostics.lastRecoveryAction, .failClosed)
        XCTAssertEqual(diagnostics.externalSenderState, .missing)
        XCTAssertFalse(diagnostics.mediaReady)
    }

    private struct DiscordDaveReplayEvent: Decodable {
        let event: String
        let groupId: UInt64?
        let selfUserId: String?
        let protocolVersion: UInt16?
        let epoch: UInt64?
        let transitionId: UInt64?
        let externalSenderHex: String?
        let expectedError: String?
    }

    private final class TemporaryKeyStore {
        let root: URL
        private let previousXDGConfigHome: String?
        private var isClosed = false

        init() throws {
            previousXDGConfigHome = getenv("XDG_CONFIG_HOME").map { String(cString: $0) }
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("libdave-keystore-\(UUID().uuidString)")

            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            guard setenv("XDG_CONFIG_HOME", root.path, 1) == 0 else {
                try? FileManager.default.removeItem(at: root)
                throw NSError(
                    domain: "libdaveSwiftTests",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Could not set XDG_CONFIG_HOME for test key store"]
                )
            }
        }

        func close() throws {
            guard !isClosed else { return }
            isClosed = true

            var cleanupFailures: [String] = []
            if let previousXDGConfigHome {
                if setenv("XDG_CONFIG_HOME", previousXDGConfigHome, 1) != 0 {
                    cleanupFailures.append("Could not restore XDG_CONFIG_HOME")
                }
            } else if unsetenv("XDG_CONFIG_HOME") != 0 {
                cleanupFailures.append("Could not unset XDG_CONFIG_HOME")
            }

            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                cleanupFailures.append("Could not remove temporary key store: \(error.localizedDescription)")
            }

            guard cleanupFailures.isEmpty else {
                throw NSError(
                    domain: "libdaveSwiftTests",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: cleanupFailures.joined(separator: "; ")]
                )
            }
        }

        deinit {
            try? close()
        }
    }

    private struct FailureCapture {
        var logged = false
        var source = ""
        var reason = ""
    }

    private final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Value

        init(_ value: Value) {
            self.storage = value
        }

        var value: Value {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func set(_ value: Value) {
            lock.lock()
            storage = value
            lock.unlock()
        }
    }

    private func dataFromHex(_ hex: String) throws -> Data {
        let clean = hex.filter { !$0.isWhitespace }
        guard clean.count.isMultiple(of: 2) else {
            throw NSError(domain: "libdaveSwiftTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Odd-length hex string"])
        }

        var bytes: [UInt8] = []
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else {
                throw NSError(domain: "libdaveSwiftTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid hex byte"])
            }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}
