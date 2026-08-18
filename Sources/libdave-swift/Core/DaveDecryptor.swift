import Foundation
import CDave

/// A decryptor for media frames (audio/video) in a DAVE session.
///
/// > Important: The underlying native decryptor is **not thread-safe**. All
/// > calls on one `DaveDecryptor` must be externally serialized (one thread,
/// > queue, or actor — `DaveSessionCoordinator` provides this). This type is
/// > intentionally not `Sendable` so the compiler flags attempts to share it
/// > across concurrency domains.
public final class DaveDecryptor {
    internal let handle: DAVEDecryptorHandle
    // `daveDecryptorTransitionToKeyRatchet` borrows this handle; it does not
    // take ownership. Retain the wrapper for the lifetime of the assignment.
    private var keyRatchet: DaveKeyRatchet?
    // A transition does not discard the previous ratchet immediately: native
    // code keeps using it to decrypt frames that were already in flight when
    // the re-key landed. Park replaced ratchets so that window cannot read a
    // destroyed handle.
    private var retiredRatchets = DaveRetiredRatchetPool()

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
    ///
    /// The previously installed ratchet stays allocated for a grace window,
    /// because the native decryptor continues to use it for frames from the
    /// prior epoch until its transition expires.
    public func transitionToKeyRatchet(_ keyRatchet: DaveKeyRatchet) {
        if let previous = self.keyRatchet, previous !== keyRatchet {
            retiredRatchets.retire(previous)
        }
        self.keyRatchet = keyRatchet
        daveDecryptorTransitionToKeyRatchet(handle, keyRatchet.handle)
    }

    /// Transitions to or from passthrough mode.
    public func transitionToPassthroughMode(_ enabled: Bool) {
        daveDecryptorTransitionToPassthroughMode(handle, enabled)
    }

    /// Calculates the maximum plaintext size for a given ciphertext frame size.
    public func maxPlaintextByteSize(mediaType: DaveMediaType, encryptedFrameSize: Int) -> Int {
        // The C API takes `size_t`; never allow a negative Swift `Int` to be
        // reinterpreted as a huge unsigned allocation request.
        guard encryptedFrameSize >= 0 else { return 0 }
        return daveDecryptorGetMaxPlaintextByteSize(handle, mediaType.cValue, encryptedFrameSize)
    }

    /// Decrypts an encrypted media frame.
    /// - Parameters:
    ///   - mediaType: Media type (audio or video).
    ///   - encryptedFrame: The encrypted frame bytes.
    /// - Returns: The decrypted plaintext frame bytes.
    public func decrypt(mediaType: DaveMediaType, encryptedFrame: Data) throws -> Data {
        // Cheap no-op unless a recent transition parked a ratchet; this is what
        // releases them once their window has passed on a steady media path.
        retiredRatchets.prune()
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

        // Return a right-sized, zero-based copy (see note in DaveEncryptor).
        return Data(plaintextData.prefix(bytesWritten))
    }

    /// Gets decryption statistics for a given media type.
    public func stats(mediaType: DaveMediaType) -> DaveDecryptorStats {
        var cStats = DAVEDecryptorStats()
        daveDecryptorGetStats(handle, mediaType.cValue, &cStats)
        return DaveDecryptorStats(cStats)
    }
}
