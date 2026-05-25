import XCTest
@testable import LibDave

final class LibDaveTests: XCTestCase {

    func testSupportedProtocolVersion() {
        let version = DaveSession.maxSupportedProtocolVersion
        XCTAssertGreaterThanOrEqual(version, 1, "Supported protocol version should be at least 1")
        print("Max Supported Protocol Version: \(version)")
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
}
