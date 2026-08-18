import Foundation
import CDave

/// An encryptor for media frames (audio/video) in a DAVE session.
///
/// > Important: The underlying native encryptor is **not thread-safe**. All
/// > calls on one `DaveEncryptor` must be externally serialized (one thread,
/// > queue, or actor — `DaveSessionCoordinator` provides this). This type is
/// > intentionally not `Sendable` so the compiler flags attempts to share it
/// > across concurrency domains.
public final class DaveEncryptor {
    internal let handle: DAVEEncryptorHandle
    /// A single stable callback context is used for the complete native
    /// encryptor lifetime. Replacing the Swift closure never replaces the raw
    /// pointer retained by native code, avoiding a stale-pointer race.
    private let callbackBridge: DaveEncryptorCallbackBridge
    private let bridgePointer: UnsafeMutableRawPointer
    /// Set only after the native API receives `bridgePointer`; until then the
    /// bridge is owned solely by this Swift encryptor and needs no tombstone.
    private var callbackBridgeRetainedForNativeLifetime = false
    // `daveEncryptorSetKeyRatchet` borrows this handle; it does not take
    // ownership. Keep the Swift wrapper alive for every native encrypt call.
    private var keyRatchet: DaveKeyRatchet?
    // Replaced ratchets are parked rather than destroyed, for the same reason
    // as in `DaveDecryptor`: the C API borrows the handle, so nothing here can
    // prove native code has finished with it the instant it is replaced.
    private var retiredRatchets = DaveRetiredRatchetPool()
    private let lock = NSLock()

    /// Creates a new media frame encryptor.
    public init() throws {
        guard let handle = daveEncryptorCreate() else {
            throw DaveError.encryptorCreationFailed
        }

        let bridge = DaveEncryptorCallbackBridge()
        self.handle = handle
        self.callbackBridge = bridge
        self.bridgePointer = Unmanaged.passUnretained(bridge).toOpaque()
    }

    deinit {
        // Do this before native teardown: a callback emitted by destruction,
        // or one already queued on another thread, becomes a harmless no-op.
        callbackBridge.deactivate()
        if callbackBridgeRetainedForNativeLifetime {
            // The C API has no documented drain operation, but clearing the
            // registration asks the current native implementation to stop
            // future delivery before destruction. The tombstone remains for
            // any callback that was already in flight.
            daveEncryptorSetProtocolVersionChangedCallback(handle, nil, nil)
            // Retire only what native code was actually handed; an unregistered
            // bridge is owned solely by this encryptor and needs no tombstone.
            DaveNativeCallbackContextRetainer.shared.retireAfterNativeLifetime(callbackBridge)
        }
        daveEncryptorDestroy(handle)
    }

    /// Sets the key ratchet for encryption.
    public func setKeyRatchet(_ keyRatchet: DaveKeyRatchet) {
        // Retain before crossing the native boundary so the handle remains
        // valid even when the caller supplied a temporary local value.
        if let previous = self.keyRatchet, previous !== keyRatchet {
            retiredRatchets.retire(previous)
        }
        self.keyRatchet = keyRatchet
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
        // The C API takes `size_t`; never allow a negative Swift `Int` to be
        // reinterpreted as a huge unsigned allocation request.
        guard frameSize >= 0 else { return 0 }
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
        // Releases parked ratchets once their window has passed (see
        // `setKeyRatchet`); a no-op on the common steady-state path.
        retiredRatchets.prune()
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

        // Return a right-sized, zero-based copy. `prefix` would hand back a
        // slice that retains the full max-capacity allocation and carries a
        // non-zero startIndex (so caller `result[0]` would trap).
        return Data(encryptedData.prefix(bytesWritten))
    }

    /// Sets a callback to be notified when the protocol version changes.
    public func setProtocolVersionChangedCallback(_ callback: @escaping @Sendable () -> Void) {
        lock.lock()
        if !callbackBridgeRetainedForNativeLifetime {
            DaveNativeCallbackContextRetainer.shared.retainForNativeLifetime(callbackBridge)
            callbackBridgeRetainedForNativeLifetime = true
        }
        callbackBridge.onProtocolVersionChanged = callback
        lock.unlock()

        // The native setter may synchronously deliver the callback. Do not
        // hold the wrapper lock across that call, or a client callback that
        // updates its own registration could deadlock.
        daveEncryptorSetProtocolVersionChangedCallback(
            handle,
            daveEncryptorProtocolVersionChangedCallbackBridge,
            bridgePointer
        )
    }

    /// Gets encryption statistics for a given media type.
    public func stats(mediaType: DaveMediaType) -> DaveEncryptorStats {
        var cStats = DAVEEncryptorStats()
        daveEncryptorGetStats(handle, mediaType.cValue, &cStats)
        return DaveEncryptorStats(cStats)
    }
}
