import Foundation
import CDave

/// An encryptor for media frames (audio/video) in a DAVE session.
public final class DaveEncryptor: @unchecked Sendable {
    internal let handle: DAVEEncryptorHandle
    private var bridgePointer: UnsafeMutableRawPointer? = nil
    private let lock = NSLock()

    /// Creates a new media frame encryptor.
    public init() throws {
        guard let handle = daveEncryptorCreate() else {
            throw DaveError.encryptorCreationFailed
        }
        self.handle = handle
    }

    deinit {
        daveEncryptorDestroy(handle)
        if let bridgePtr = bridgePointer {
            Unmanaged<DaveEncryptorCallbackBridge>.fromOpaque(bridgePtr).release()
        }
    }

    /// Sets the key ratchet for encryption.
    public func setKeyRatchet(_ keyRatchet: DaveKeyRatchet) {
        daveEncryptorSetKeyRatchet(handle, keyRatchet.handle)
    }

    /// Enables or disables passthrough mode (frames pass through unencrypted).
    public func setPassthroughMode(_ enabled: Bool) {
        daveEncryptorSetPassthroughMode(handle, enabled)
    }

    /// Associates an SSRC (Synchronization Source) with a specific codec.
    public func assignSsrcToCodec(ssrc: UInt32, codec: DaveCodec) {
        daveEncryptorAssignSsrcToCodec(handle, ssrc, codec.cValue)
    }

    /// Gets the current protocol version used by the encryptor.
    public var protocolVersion: UInt16 {
        return daveEncryptorGetProtocolVersion(handle)
    }

    /// Calculates the maximum ciphertext size for a given plaintext frame size.
    public func maxCiphertextByteSize(mediaType: DaveMediaType, frameSize: Int) -> Int {
        return daveEncryptorGetMaxCiphertextByteSize(handle, mediaType.cValue, frameSize)
    }

    /// Checks if the encryptor has a key ratchet.
    public var hasKeyRatchet: Bool {
        return daveEncryptorHasKeyRatchet(handle)
    }

    /// Checks if the encryptor is in passthrough mode.
    public var isPassthroughMode: Bool {
        return daveEncryptorIsPassthroughMode(handle)
    }

    /// Encrypts a media frame.
    /// - Parameters:
    ///   - mediaType: Media type (audio or video).
    ///   - ssrc: SSRC of the stream.
    ///   - frame: The plaintext frame bytes.
    /// - Returns: The encrypted frame bytes.
    public func encrypt(mediaType: DaveMediaType, ssrc: UInt32, frame: Data) throws -> Data {
        let maxCapacity = maxCiphertextByteSize(mediaType: mediaType, frameSize: frame.count)
        var encryptedData = Data(count: maxCapacity)
        var bytesWritten: Int = 0

        let result = frame.withUnsafeBytes { frameBuffer -> DAVEEncryptorResultCode in
            let framePtr = frameBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return encryptedData.withUnsafeMutableBytes { encBuffer -> DAVEEncryptorResultCode in
                let encPtr = encBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
                return daveEncryptorEncrypt(
                    handle,
                    mediaType.cValue,
                    ssrc,
                    framePtr,
                    frame.count,
                    encPtr,
                    maxCapacity,
                    &bytesWritten
                )
            }
        }

        guard result == DAVE_ENCRYPTOR_RESULT_CODE_SUCCESS else {
            throw DaveError.encryptionFailed(reason: DaveEncryptorResultCode(result))
        }

        return encryptedData.prefix(bytesWritten)
    }

    /// Sets a callback to be notified when the protocol version changes.
    public func setProtocolVersionChangedCallback(_ callback: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }

        if let oldBridgePtr = bridgePointer {
            Unmanaged<DaveEncryptorCallbackBridge>.fromOpaque(oldBridgePtr).release()
        }

        let bridge = DaveEncryptorCallbackBridge()
        bridge.onProtocolVersionChanged = callback
        let bridgePtr = Unmanaged.passRetained(bridge).toOpaque()

        daveEncryptorSetProtocolVersionChangedCallback(
            handle,
            daveEncryptorProtocolVersionChangedCallbackBridge,
            bridgePtr
        )
        self.bridgePointer = bridgePtr
    }

    /// Gets encryption statistics for a given media type.
    public func stats(mediaType: DaveMediaType) -> DaveEncryptorStats {
        var cStats = DAVEEncryptorStats()
        daveEncryptorGetStats(handle, mediaType.cValue, &cStats)
        return DaveEncryptorStats(cStats)
    }
}
