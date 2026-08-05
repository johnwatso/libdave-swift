import Foundation
import CDave

/// Opaque wrapper for a DAVE Key Ratchet.
///
/// `@unchecked Sendable` is justified because the wrapper is immutable after
/// init and the native handle is only read by the encryptor/decryptor it is
/// handed to; the wrapper itself performs no mutation outside `deinit`.
public final class DaveKeyRatchet: @unchecked Sendable {
    internal let handle: DAVEKeyRatchetHandle

    internal init(handle: DAVEKeyRatchetHandle) {
        self.handle = handle
    }

    deinit {
        daveKeyRatchetDestroy(handle)
    }
}

/// Opaque wrapper for the result of an MLS commit process.
public final class DaveCommitResult: @unchecked Sendable {
    internal let handle: DAVECommitResultHandle?

    internal init(handle: DAVECommitResultHandle?) {
        self.handle = handle
    }

    deinit {
        if let handle = handle {
            daveCommitResultDestroy(handle)
        }
    }

    /// Returns whether the commit processing failed.
    public var isFailed: Bool {
        guard let handle = handle else { return true }
        return daveCommitResultIsFailed(handle)
    }

    /// Returns whether the commit should be ignored.
    public var isIgnored: Bool {
        guard let handle = handle else { return false }
        return daveCommitResultIsIgnored(handle)
    }

    /// Lists the member IDs in the roster after this commit.
    public var rosterMemberIds: [UInt64] {
        guard let handle = handle else { return [] }
        var rosterIdsPtr: UnsafeMutablePointer<UInt64>? = nil
        var length: Int = 0
        daveCommitResultGetRosterMemberIds(handle, &rosterIdsPtr, &length)
        guard let ptr = rosterIdsPtr else { return [] }
        defer { daveFree(ptr) }
        guard length > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: ptr, count: length))
    }

    /// Retrieves the signature of a roster member.
    public func getRosterMemberSignature(rosterId: UInt64) -> Data? {
        guard let handle = handle else { return nil }
        var signaturePtr: UnsafeMutablePointer<UInt8>? = nil
        var length: Int = 0
        daveCommitResultGetRosterMemberSignature(handle, rosterId, &signaturePtr, &length)
        guard let ptr = signaturePtr else { return nil }
        defer { daveFree(ptr) }
        guard length > 0 else { return nil }
        return Data(bytes: ptr, count: length)
    }
}

/// Opaque wrapper for the result of processing an MLS welcome message.
public final class DaveWelcomeResult: @unchecked Sendable {
    internal let handle: DAVEWelcomeResultHandle

    internal init(handle: DAVEWelcomeResultHandle) {
        self.handle = handle
    }

    deinit {
        daveWelcomeResultDestroy(handle)
    }

    /// Lists the member IDs in the roster from this welcome message.
    public var rosterMemberIds: [UInt64] {
        var rosterIdsPtr: UnsafeMutablePointer<UInt64>? = nil
        var length: Int = 0
        daveWelcomeResultGetRosterMemberIds(handle, &rosterIdsPtr, &length)
        guard let ptr = rosterIdsPtr else { return [] }
        defer { daveFree(ptr) }
        guard length > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: ptr, count: length))
    }

    /// Retrieves the signature of a roster member from this welcome message.
    public func getRosterMemberSignature(rosterId: UInt64) -> Data? {
        var signaturePtr: UnsafeMutablePointer<UInt8>? = nil
        var length: Int = 0
        daveWelcomeResultGetRosterMemberSignature(handle, rosterId, &signaturePtr, &length)
        guard let ptr = signaturePtr else { return nil }
        defer { daveFree(ptr) }
        guard length > 0 else { return nil }
        return Data(bytes: ptr, count: length)
    }
}

/// A DAVE session handle managing group encryption state and MLS protocol integration.
///
/// > Important: The underlying native MLS session is **not thread-safe**. All
/// > calls on one `DaveSession` must be externally serialized — one thread,
/// > one serial queue, or one actor. `DaveSessionCoordinator` provides this
/// > serialization; use it unless you are building your own coordination layer.
/// > This type is intentionally not `Sendable` so the compiler flags attempts
/// > to share it across concurrency domains.
public final class DaveSession {
    internal let handle: DAVESessionHandle
    private let callbackBridge: DaveSessionCallbackBridge

    /// Returns the maximum protocol version supported by this library.
    public static var maxSupportedProtocolVersion: UInt16 {
        return daveMaxSupportedProtocolVersion()
    }

    /// Creates a new DAVE session.
    /// - Parameters:
    ///   - authSessionId: Identifier used to manage persistent key lifetimes.
    ///   - onMLSFailure: Callback invoked when an MLS failure occurs.
    public init(authSessionId: String? = nil, onMLSFailure: @escaping @Sendable (String, String) -> Void) throws {
        let bridge = DaveSessionCallbackBridge()
        bridge.onMLSFailure = onMLSFailure
        // Keep the raw callback context valid even if the native library
        // delivers a callback after session destruction. `deactivate()` in
        // `deinit` drops the user closure so the retained shell is inert.
        DaveNativeCallbackContextRetainer.shared.retainForNativeLifetime(bridge)
        let bridgePtr = Unmanaged.passUnretained(bridge).toOpaque()

        let authIdCString = authSessionId?.cString(using: .utf8)
        let handleOpt = daveSessionCreate(nil, authIdCString, daveMLSFailureCallbackBridge, bridgePtr)

        guard let handle = handleOpt else {
            bridge.deactivate()
            throw DaveError.sessionCreationFailed
        }

        self.handle = handle
        self.callbackBridge = bridge
    }

    deinit {
        // The native C API has no documented callback drain. Deactivate first
        // so any callback concurrent with or following destruction is inert;
        // the bridge remains retained by DaveNativeCallbackContextRetainer.
        callbackBridge.deactivate()
        daveSessionDestroy(handle)
    }

    /// Initializes a session with protocol version and group information.
    ///
    /// - Important: `selfUserId` must be a non-zero unsigned decimal Discord
    ///   Snowflake. ``DaveSessionCoordinator`` validates this before calling
    ///   the native implementation; low-level callers must do the same.
    public func initialize(version: UInt16, groupId: UInt64, selfUserId: String) {
        daveSessionInit(handle, version, groupId, selfUserId.cString(using: .utf8))
    }

    /// Resets the session state.
    public func reset() {
        daveSessionReset(handle)
    }

    /// Returns and clears the most recent native MLS failure (source, reason),
    /// if one was reported since the last call. Useful for attaching the real
    /// native reason to an error thrown right after a transition call.
    public func takeLastMLSFailure() -> (source: String, reason: String)? {
        callbackBridge.takeLastFailure()
    }

    /// Sets the protocol version for the session.
    public func setProtocolVersion(version: UInt16) {
        daveSessionSetProtocolVersion(handle, version)
    }

    /// Gets the current protocol version of the session.
    public var protocolVersion: UInt16 {
        return daveSessionGetProtocolVersion(handle)
    }

    /// Retrieves the authenticator from the last MLS epoch.
    public var lastEpochAuthenticator: Data? {
        var authPtr: UnsafeMutablePointer<UInt8>? = nil
        var length: Int = 0
        daveSessionGetLastEpochAuthenticator(handle, &authPtr, &length)
        guard let ptr = authPtr else { return nil }
        defer { daveFree(ptr) }
        guard length > 0 else { return nil }
        return Data(bytes: ptr, count: length)
    }

    /// Sets the external sender credentials.
    public func setExternalSender(_ externalSender: Data) {
        externalSender.withUnsafeBytes { rawBuffer in
            if let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                daveSessionSetExternalSender(handle, baseAddress, externalSender.count)
            }
        }
    }

    /// Processes MLS proposals and generates commit/welcome messages.
    public func processProposals(_ proposals: Data, recognizedUserIds: [String]) -> Data? {
        var outputPtr: UnsafeMutablePointer<UInt8>? = nil
        var outputLength: Int = 0

        let cStrings = recognizedUserIds.map { strdup($0) }
        defer {
            for ptr in cStrings {
                free(ptr)
            }
        }
        var cStringsPtr = cStrings.map { UnsafePointer<CChar>($0) }

        proposals.withUnsafeBytes { proposalsBuffer in
            let proposalsPtr = proposalsBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
            cStringsPtr.withUnsafeMutableBufferPointer { recognizedBuffer in
                daveSessionProcessProposals(
                    handle,
                    proposalsPtr,
                    proposals.count,
                    recognizedBuffer.baseAddress,
                    recognizedUserIds.count,
                    &outputPtr,
                    &outputLength
                )
            }
        }

        guard let ptr = outputPtr else { return nil }
        defer { daveFree(ptr) }
        guard outputLength > 0 else { return nil }
        return Data(bytes: ptr, count: outputLength)
    }

    /// Processes an incoming MLS commit message.
    public func processCommit(_ commit: Data) -> DaveCommitResult {
        let resultHandle = commit.withUnsafeBytes { commitBuffer -> DAVECommitResultHandle? in
            let commitPtr = commitBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return daveSessionProcessCommit(handle, commitPtr, commit.count)
        }
        return DaveCommitResult(handle: resultHandle)
    }

    /// Processes an incoming MLS welcome message to join a group.
    public func processWelcome(_ welcome: Data, recognizedUserIds: [String]) -> DaveWelcomeResult? {
        let cStrings = recognizedUserIds.map { strdup($0) }
        defer {
            for ptr in cStrings {
                free(ptr)
            }
        }
        var cStringsPtr = cStrings.map { UnsafePointer<CChar>($0) }

        let resultHandle = welcome.withUnsafeBytes { welcomeBuffer -> DAVEWelcomeResultHandle? in
            let welcomePtr = welcomeBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return cStringsPtr.withUnsafeMutableBufferPointer { recognizedBuffer in
                return daveSessionProcessWelcome(
                    handle,
                    welcomePtr,
                    welcome.count,
                    recognizedBuffer.baseAddress,
                    recognizedUserIds.count
                )
            }
        }

        guard let resHandle = resultHandle else { return nil }
        return DaveWelcomeResult(handle: resHandle)
    }

    /// Gets the marshalled MLS key package.
    public var marshalledKeyPackage: Data? {
        var outputPtr: UnsafeMutablePointer<UInt8>? = nil
        var outputLength: Int = 0
        daveSessionGetMarshalledKeyPackage(handle, &outputPtr, &outputLength)
        guard let ptr = outputPtr else { return nil }
        defer { daveFree(ptr) }
        guard outputLength > 0 else { return nil }
        return Data(bytes: ptr, count: outputLength)
    }

    /// Gets a key ratchet for a specific user.
    public func getKeyRatchet(userId: String) -> DaveKeyRatchet? {
        guard let rHandle = daveSessionGetKeyRatchet(handle, userId.cString(using: .utf8)) else { return nil }
        return DaveKeyRatchet(handle: rHandle)
    }

    /// Computes a pairwise fingerprint for identity verification with another user.
    ///
    /// The callback receives `nil` if the native library produced no fingerprint,
    /// so an awaiting caller can always resume rather than hang indefinitely.
    ///
    /// The bundled native implementation invokes the callback synchronously.
    /// The bridge nevertheless remains valid for process lifetime because the
    /// C API does not document callback drain semantics; a late or duplicate
    /// callback is safely ignored after the first delivery.
    public func getPairwiseFingerprint(
        version: UInt16,
        userId: String,
        callback: @escaping @Sendable (Data?) -> Void
    ) {
        // Dedicated per-call bridge: concurrent requests cannot clobber one
        // another's closure. Keep its raw callback context valid even if the
        // native implementation ever changes its callback timing.
        let bridge = DaveFingerprintCallbackBridge(callback: callback)
        DaveNativeCallbackContextRetainer.shared.retainForNativeLifetime(bridge)
        let bridgePtr = Unmanaged.passUnretained(bridge).toOpaque()
        userId.withCString { userIdPtr in
            daveSessionGetPairwiseFingerprint(
                handle,
                version,
                userIdPtr,
                davePairwiseFingerprintCallbackBridge,
                bridgePtr
            )
        }
    }

    /// Async variant of ``getPairwiseFingerprint(version:userId:callback:)``.
    ///
    /// Returns `nil` when the native library produced no fingerprint (e.g. the
    /// remote user is not in the current MLS group).
    public func pairwiseFingerprint(version: UInt16, userId: String) async -> Data? {
        await withCheckedContinuation { continuation in
            getPairwiseFingerprint(version: version, userId: userId) { fingerprint in
                continuation.resume(returning: fingerprint)
            }
        }
    }
}
