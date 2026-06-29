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
            let session = try DaveSession(authSessionId: "test-auth-session") { source, reason in
                failure.set(FailureCapture(logged: true, source: source, reason: reason))
            }

            XCTAssertNotNil(session, "Session should not be nil")

            // Initialize session with group details
            session.initialize(version: 1, groupId: 12345, selfUserId: "user-123")

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
        _ = try? DaveSession(authSessionId: "test-logger") { _, _ in }
        
        DaveLogger.removeLogSink()
        XCTAssertTrue(logReceived.value, "The log sink should have received at least one C++ log message")
    }

    // MARK: - New Expanded Tests for Improvements

    func testCoordinatorConcurrentPassthroughEncryption() async throws {
        let coordinator = DaveSessionCoordinator(authSessionId: "concurrent-test")
        try await coordinator.configureForDiscordVoice(groupId: 12345, selfUserId: "user-123", protocolVersion: 1)
        try await coordinator.setPassthroughMode(true)

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
        let coordinator = DaveSessionCoordinator(authSessionId: "reset-test")

        // Before configuration
        var diagnostics = await coordinator.getDiagnostics()
        XCTAssertEqual(diagnostics.handshakeState, .uninitialized)
        XCTAssertEqual(diagnostics.currentEpoch, 0)
        XCTAssertFalse(diagnostics.isExternalSenderRegistered)

        // Configure
        try await coordinator.configureForDiscordVoice(groupId: 9999, selfUserId: "user-999", protocolVersion: 1)
        diagnostics = await coordinator.getDiagnostics()
        XCTAssertEqual(diagnostics.handshakeState, .initialized)
        XCTAssertEqual(diagnostics.protocolVersion, 1)

        // Set external sender
        let mockExternalSender = Data([1, 2, 3, 4, 5])
        try await coordinator.setExternalSender(mockExternalSender)
        diagnostics = await coordinator.getDiagnostics()
        XCTAssertTrue(diagnostics.isExternalSenderRegistered)

        // Reset
        await coordinator.reset()
        diagnostics = await coordinator.getDiagnostics()
        XCTAssertEqual(diagnostics.handshakeState, .uninitialized)
        XCTAssertEqual(diagnostics.currentEpoch, 0)
        XCTAssertFalse(diagnostics.isExternalSenderRegistered)
    }

    func testCoordinatorInvalidTransitions() async throws {
        let coordinator = DaveSessionCoordinator(authSessionId: "transition-test")

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
        try await coordinator.configureForDiscordVoice(groupId: 1111, selfUserId: "user-111", protocolVersion: 1)

        // Invalid Welcome transition -> handshakeFailed error
        do {
            try await coordinator.processDiscordTransition(.welcome(Data([0, 1, 2]), recognizedUserIds: ["user-111"]))
            XCTFail("Should have thrown DaveError.handshakeFailed")
        } catch let error as DaveError {
            switch error {
            case .handshakeFailed(let reason):
                XCTAssertTrue(reason.contains("Welcome") || reason.contains("returned nil"))
            default:
                XCTFail("Expected .handshakeFailed error, got: \(error)")
            }
        } catch {
            XCTFail("Expected DaveError, got: \(error)")
        }

        // Invalid Commit transition -> handshakeFailed error
        do {
            try await coordinator.processDiscordTransition(.commit(Data([0, 1, 2])))
            XCTFail("Should have thrown DaveError.handshakeFailed")
        } catch let error as DaveError {
            switch error {
            case .handshakeFailed(let reason):
                XCTAssertTrue(reason.contains("Commit"))
            default:
                XCTFail("Expected .handshakeFailed error, got: \(error)")
            }
        } catch {
            XCTFail("Expected DaveError, got: \(error)")
        }
    }

    func testCoordinatorRejectsEmptyTransitions() async throws {
        let coordinator = DaveSessionCoordinator(authSessionId: "empty-test")
        try await coordinator.configureForDiscordVoice(groupId: 2222, selfUserId: "user-222", protocolVersion: 1)

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

        await assertInvalidTransition({
            try await coordinator.processDiscordTransition(.welcome(Data(), recognizedUserIds: ["user-222"]))
        }, "empty welcome")

        await assertInvalidTransition({
            _ = try await coordinator.processProposals(Data(), recognizedUserIds: ["user-222"])
        }, "empty proposals")
    }

    func testCoordinatorHighLevelDiagnosticsAndWatchdog() async throws {
        let coordinator = DaveSessionCoordinator(authSessionId: "high-level-test")

        let configured = try await coordinator.configureDiscordVoiceSession(
            groupId: 3333,
            selfUserId: "user-333",
            protocolVersion: 1
        )
        XCTAssertEqual(configured.recoveryHint, .waitForExternalSender)
        XCTAssertFalse(configured.needsRecovery)
        XCTAssertFalse(configured.mediaReady)
        XCTAssertEqual(configured.diagnostics.externalSenderState, .missing)
        XCTAssertFalse(configured.diagnostics.hasSentInitialKeyPackage)

        let registered = try await coordinator.registerDiscordExternalSender(
            Data([1, 2, 3, 4, 5]),
            publishInitialKeyPackage: false
        )
        XCTAssertEqual(registered.recoveryHint, .none)
        XCTAssertEqual(registered.diagnostics.externalSenderState, .registered)
        XCTAssertFalse(registered.diagnostics.hasSentInitialKeyPackage)
        XCTAssertTrue(registered.outboundActions.isEmpty)

        await coordinator.markInitialKeyPackageSent()
        var diagnostics = await coordinator.getDiagnostics()
        XCTAssertTrue(diagnostics.hasSentInitialKeyPackage)
        XCTAssertEqual(diagnostics.lastRecoveryAction, .sendInitialKeyPackage)

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

        let ready = await coordinator.markDiscordMediaReady(reason: "unit test complete")
        XCTAssertEqual(ready, .inactive)
        diagnostics = await coordinator.getDiagnostics()
        XCTAssertTrue(diagnostics.mediaReady)
        XCTAssertNil(diagnostics.pendingTransitionId)
        XCTAssertNil(diagnostics.pendingEpoch)
        XCTAssertEqual(diagnostics.lastRecoveryAction, .resumeMedia)
    }

    func testDaveErrorRecoveryHints() {
        XCTAssertEqual(DaveError.sessionCreationFailed.recoveryHint, .fatal)
        XCTAssertEqual(DaveError.handshakeFailed(reason: "bad welcome").recoveryHint, .sendInvalidCommitWelcome)
        XCTAssertEqual(DaveError.invalidTransition(message: "empty").recoveryHint, .sendInvalidCommitWelcome)
        XCTAssertEqual(DaveError.ratchetFailed(userId: "user", reason: "missing").recoveryHint, .recreateSession)
        XCTAssertEqual(DaveError.encryptionFailed(reason: .missingKeyRatchet).recoveryHint, .retryLater)
        XCTAssertEqual(DaveError.encryptionFailed(reason: .encryptionFailure).recoveryHint, .recreateSession)
        XCTAssertEqual(DaveError.notConfigured.recoveryHint, .fatal)
    }

    func testHighLevelInvalidTransitionRecoveryEmitsGatewayActions() async throws {
        let coordinator = DaveSessionCoordinator(authSessionId: "invalid-recovery-test")
        try await coordinator.configureForDiscordVoice(groupId: 4444, selfUserId: "user-444", protocolVersion: 1)
        _ = try await coordinator.registerDiscordExternalSender(
            Data([1, 2, 3, 4, 5]),
            publishInitialKeyPackage: false
        )

        let result = try await coordinator.processDiscordCommitForOutbound(
            Data([0, 1, 2]),
            transitionId: 88,
            recoveryTimeout: 0.5
        )

        XCTAssertEqual(result.recoveryHint, .recreateSession)
        XCTAssertTrue(result.needsRecovery)
        XCTAssertFalse(result.mediaReady)
        XCTAssertGreaterThanOrEqual(result.outboundActions.count, 1)
        guard case .invalidCommitWelcome(88) = result.outboundActions[0] else {
            return XCTFail("Expected invalid commit/welcome recovery action first")
        }
        if result.outboundActions.count > 1 {
            guard case .mlsKeyPackage(let keyPackage) = result.outboundActions[1] else {
                return XCTFail("Expected replacement key package action second")
            }
            XCTAssertFalse(keyPackage.isEmpty)
            XCTAssertTrue(result.diagnostics.hasSentInitialKeyPackage)
        } else {
            XCTAssertNotNil(result.diagnostics.lastMlsError)
            XCTAssertFalse(result.diagnostics.hasSentInitialKeyPackage)
        }
        XCTAssertEqual(result.diagnostics.pendingTransitionId, 88)
        XCTAssertEqual(result.diagnostics.externalSenderState, .registered)
        XCTAssertEqual(result.diagnostics.lastRecoveryAction, .invalidTransitionRecovery)
    }

    func testMediaReadinessWatchdogTimesOut() async throws {
        let coordinator = DaveSessionCoordinator(authSessionId: "watchdog-test")
        try await coordinator.configureForDiscordVoice(groupId: 5555, selfUserId: "user-555", protocolVersion: 1)

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

    func testDiscordRecoveryReplayFixture() async throws {
        let fixtureURL = try XCTUnwrap(Bundle.module.url(
            forResource: "discord-dave-recovery-sequence",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        let data = try Data(contentsOf: fixtureURL)
        let events = try JSONDecoder().decode([DiscordDaveReplayEvent].self, from: data)
        let coordinator = DaveSessionCoordinator(authSessionId: "replay-fixture-test")

        var sawInvalidTransitionRecovery = false
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
                let result = try await coordinator.registerDiscordExternalSender(
                    externalSender,
                    publishInitialKeyPackage: false
                )
                XCTAssertTrue(result.outboundActions.isEmpty)

            case "prepareEpoch":
                let result = try await coordinator.prepareDiscordEpoch(
                    protocolVersion: try XCTUnwrap(event.protocolVersion),
                    epoch: try XCTUnwrap(event.epoch)
                )
                XCTAssertEqual(result.diagnostics.pendingEpoch, event.epoch)

            case "invalidTransition":
                let transitionId = try XCTUnwrap(event.transitionId)
                let result = try await coordinator.recoverDiscordInvalidTransition(transitionId: transitionId)
                XCTAssertGreaterThanOrEqual(result.outboundActions.count, 1)
                guard case .invalidCommitWelcome(transitionId) = result.outboundActions[0] else {
                    return XCTFail("Expected invalid commit/welcome recovery action first")
                }
                XCTAssertEqual(result.diagnostics.pendingTransitionId, transitionId)
                sawInvalidTransitionRecovery = true

            default:
                XCTFail("Unknown replay event: \(event.event)")
            }
        }

        let diagnostics = await coordinator.getDiagnostics()
        XCTAssertTrue(sawInvalidTransitionRecovery)
        XCTAssertEqual(diagnostics.externalSenderState, .registered)
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
