import XCTest
@testable import LibDave

final class LibDaveTests: XCTestCase {

    func testSupportedProtocolVersion() {
        let version = DaveSession.maxSupportedProtocolVersion
        XCTAssertGreaterThanOrEqual(version, 1, "Supported protocol version should be at least 1")
        print("Max Supported Protocol Version: \(version)")
    }

    func testLibDaveVersion() {
        XCTAssertEqual(LibDaveVersion, "1.0.0", "Version constant should be '1.0.0'")
    }

    func testSessionCreationAndInitialization() {
        var failureLogged = false
        var failureSource = ""
        var failureReason = ""

        do {
            let session = try DaveSession(authSessionId: "test-auth-session") { source, reason in
                failureLogged = true
                failureSource = source
                failureReason = reason
            }

            XCTAssertNotNil(session, "Session should not be nil")

            // Initialize session with group details
            session.initialize(version: 1, groupId: 12345, selfUserId: "user-123")

            // Verify version is as set
            XCTAssertEqual(session.protocolVersion, 1, "Session protocol version should be 1")

            // Reset session
            session.reset()
            XCTAssertEqual(session.protocolVersion, 0, "Protocol version should reset to 0 after reset")

            XCTAssertFalse(failureLogged, "MLS failures should not have been logged: \(failureSource) - \(failureReason)")

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
        var logReceived = false
        DaveLogger.setLogSink(minSeverity: .verbose) { severity, file, line, message in
            logReceived = true
            print("[\(severity)] [\(file):\(line)] \(message)")
        }
        
        // Trigger a log by creating a session (session creation prints logs)
        _ = try? DaveSession(authSessionId: "test-logger") { _, _ in }
        
        DaveLogger.removeLogSink()
        XCTAssertTrue(logReceived, "The log sink should have received at least one C++ log message")
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
}
