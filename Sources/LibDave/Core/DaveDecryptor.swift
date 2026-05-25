import Foundation
import CDave

/// A decryptor for media frames (audio/video) in a DAVE session.
public final class DaveDecryptor: @unchecked Sendable {
    internal let handle: DAVEDecryptorHandle

    /// Creates a new media frame decryptor.
    public init() throws {
        guard let handle = daveDecryptorCreate() else {
            throw DaveError.decryptorCreationFailed
        }
        self.handle = handle
    }

    deinit {
        daveDecryptorDestroy(handle)
    }

    /// Transitions the decryptor to use a new key ratchet.
    public func transitionToKeyRatchet(_ keyRatchet: DaveKeyRatchet) {
        daveDecryptorTransitionToKeyRatchet(handle, keyRatchet.handle)
    }

    /// Transitions to or from passthrough mode.
    public func transitionToPassthroughMode(_ enabled: Bool) {
        daveDecryptorTransitionToPassthroughMode(handle, enabled)
    }

    /// Calculates the maximum plaintext size for a given ciphertext frame size.
    public func maxPlaintextByteSize(mediaType: DaveMediaType, encryptedFrameSize: Int) -> Int {
        return daveDecryptorGetMaxPlaintextByteSize(handle, mediaType.cValue, encryptedFrameSize)
    }

    /// Decrypts an encrypted media frame.
    /// - Parameters:
    ///   - mediaType: Media type (audio or video).
    ///   - encryptedFrame: The encrypted frame bytes.
    /// - Returns: The decrypted plaintext frame bytes.
    public func decrypt(mediaType: DaveMediaType, encryptedFrame: Data) throws -> Data {
        let maxCapacity = maxPlaintextByteSize(mediaType: mediaType, encryptedFrameSize: encryptedFrame.count)
        var plaintextData = Data(count: maxCapacity)
        var bytesWritten: Int = 0

        let result = encryptedFrame.withUnsafeBytes { encBuffer -> DAVEDecryptorResultCode in
            let encPtr = encBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return plaintextData.withUnsafeMutableBytes { plainBuffer -> DAVEDecryptorResultCode in
                let plainPtr = plainBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
                return daveDecryptorDecrypt(
                    handle,
                    mediaType.cValue,
                    encPtr,
                    encryptedFrame.count,
                    plainPtr,
                    maxCapacity,
                    &bytesWritten
                )
            }
        }

        guard result == DAVE_DECRYPTOR_RESULT_CODE_SUCCESS else {
            throw DaveError.decryptionFailed(reason: DaveDecryptorResultCode(result))
        }

        return plaintextData.prefix(bytesWritten)
    }

    /// Gets decryption statistics for a given media type.
    public func stats(mediaType: DaveMediaType) -> DaveDecryptorStats {
        var cStats = DAVEDecryptorStats()
        daveDecryptorGetStats(handle, mediaType.cValue, &cStats)
        return DaveDecryptorStats(cStats)
    }
}
