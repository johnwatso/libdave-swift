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

/// Holds key ratchets that have been replaced but that native code may still
/// read from.
///
/// `dave.h` documents that `daveEncryptorSetKeyRatchet` and
/// `daveDecryptorTransitionToKeyRatchet` do **not** take ownership of the
/// handle they are given. libdave's decryptor also keeps decrypting with the
/// previous epoch's ratchet for a short transition window, so that frames
/// already in flight when a re-key lands are not dropped. Releasing the
/// replaced Swift wrapper immediately would call `daveKeyRatchetDestroy` on a
/// handle the native side can still dereference during that window.
///
/// Replaced ratchets are therefore parked here and released only once the
/// window has comfortably passed. The cost is a handful of small native
/// objects held for a few extra seconds per re-key.
internal enum DaveRetiredHandlePoolLimits {
    /// libdave expires a media transition on the order of ten seconds. Hold
    /// well past that so a late frame can never reach a freed ratchet.
    static let grace: Duration = .seconds(30)
    /// Ceiling for pathological re-key storms. Re-keys are seconds apart in
    /// practice, so this is never reached by normal Discord traffic.
    static let maximumRetained = 8
}

internal struct DaveRetiredHandlePool<Element: AnyObject> {

    private var retired: [(element: Element, retiredAt: ContinuousClock.Instant)] = []

    /// Parks a replaced ratchet, first releasing any whose window has passed.
    mutating func retire(_ ratchet: Element) {
        prune()
        retired.append((ratchet, ContinuousClock.now))
        if retired.count > DaveRetiredHandlePoolLimits.maximumRetained {
            retired.removeFirst(retired.count - DaveRetiredHandlePoolLimits.maximumRetained)
        }
    }

    /// Releases ratchets whose transition window has elapsed. Uses a monotonic
    /// clock so a wall-clock adjustment cannot free one early.
    mutating func prune() {
        guard !retired.isEmpty else { return }
        let now = ContinuousClock.now
        retired.removeAll { now - $0.retiredAt >= DaveRetiredHandlePoolLimits.grace }
    }

    /// Number of ratchets currently parked. Exposed for tests.
    var count: Int { retired.count }
}

/// The pool as used by the media cryptors. It is generic only so its bounding
/// behavior can be tested without an established MLS group, which is the one
/// thing that can produce a real ratchet handle.
internal typealias DaveRetiredRatchetPool = DaveRetiredHandlePool<DaveKeyRatchet>

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
        // The native backend interpolates this id into a key-store filename.
        // Validate before it can escape the identity directory.
        if let authSessionId {
            try DavePersistedIdentityStore.validate(authSessionId: authSessionId)
        }

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

        if authSessionId != nil {
            // Native code creates the key file 0600 but leaves the directory
            // world-readable. Tighten it as soon as it can exist.
            DavePersistedIdentityStore.hardenStoragePermissions()
        }
    }

    deinit {
        // The native C API has no documented callback drain. Deactivate first
        // so any callback concurrent with or following destruction is inert;
        // the bridge is then retired, which keeps it allocated for a grace
        // window before DaveNativeCallbackContextRetainer reclaims it.
        callbackBridge.deactivate()
        DaveNativeCallbackContextRetainer.shared.retireAfterNativeLifetime(callbackBridge)
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
    ///
    /// An empty payload is rejected here rather than forwarded: the native
    /// unmarshaller reads the buffer without checking its length and crashes
    /// the process on zero bytes. Checking `baseAddress` for `nil` is not a
    /// sufficient guard, because empty `Data` may still vend a non-`nil`
    /// pointer. The rejection is recorded as an MLS failure so it surfaces
    /// through ``takeLastMLSFailure()`` on the usual path.
    public func setExternalSender(_ externalSender: Data) {
        guard !externalSender.isEmpty else {
            callbackBridge.recordFailure(
                source: "libdave-swift",
                reason: "External sender payload was empty"
            )
            return
        }

        externalSender.withUnsafeBytes { rawBuffer in
            if let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                daveSessionSetExternalSender(handle, baseAddress, externalSender.count)
            }
        }
    }

    /// Processes MLS proposals and generates commit/welcome messages.
    ///
    /// Returns `nil` for an empty payload rather than forwarding it: see the
    /// note on ``setExternalSender(_:)`` for why zero-length buffers are not
    /// handed to native code.
    public func processProposals(_ proposals: Data, recognizedUserIds: [String]) -> Data? {
        guard !proposals.isEmpty else { return nil }
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
    ///
    /// An empty payload yields a failed result without entering native code.
    public func processCommit(_ commit: Data) -> DaveCommitResult {
        guard !commit.isEmpty else { return DaveCommitResult(handle: nil) }
        let resultHandle = commit.withUnsafeBytes { commitBuffer -> DAVECommitResultHandle? in
            let commitPtr = commitBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return daveSessionProcessCommit(handle, commitPtr, commit.count)
        }
        return DaveCommitResult(handle: resultHandle)
    }

    /// Processes an incoming MLS welcome message to join a group.
    ///
    /// Returns `nil` for an empty payload without entering native code.
    public func processWelcome(_ welcome: Data, recognizedUserIds: [String]) -> DaveWelcomeResult? {
        guard !welcome.isEmpty else { return nil }
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
        _ = requestPairwiseFingerprint(version: version, userId: userId, callback: callback)
    }

    /// Issues one fingerprint request and returns its single-shot bridge, so an
    /// `async` caller can also complete it from a timeout path.
    ///
    /// This stays synchronous on purpose: callers that hold a `DaveSession`
    /// inside an actor can issue the request without sending the (deliberately
    /// non-`Sendable`) session across an isolation boundary, and then await the
    /// returned bridge, which is safe to share.
    @discardableResult
    internal func requestPairwiseFingerprint(
        version: UInt16,
        userId: String,
        callback: @escaping @Sendable (Data?) -> Void
    ) -> DaveFingerprintCallbackBridge {
        // Dedicated per-call bridge: concurrent requests cannot clobber one
        // another's closure. Keep its raw callback context valid even if the
        // native implementation ever changes its callback timing; the bridge
        // retires itself once the one expected callback has been consumed.
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
        return bridge
    }

    /// Async variant of ``getPairwiseFingerprint(version:userId:callback:)``.
    ///
    /// Returns `nil` when the native library produced no fingerprint (e.g. the
    /// remote user is not in the current MLS group), and also when the native
    /// callback does not arrive within `timeout`.
    ///
    /// The bundled implementation calls back synchronously, so the timeout
    /// never fires in practice. It exists so that a future native change (or a
    /// wedged native call) degrades to a `nil` answer instead of suspending the
    /// caller forever and leaking its callback context.
    public func pairwiseFingerprint(
        version: UInt16,
        userId: String,
        timeout: Duration = .seconds(5)
    ) async -> Data? {
        let resume = DaveSingleShotResume<Data?>()
        let bridge = requestPairwiseFingerprint(version: version, userId: userId) { fingerprint in
            resume.deliver(fingerprint)
        }

        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            // Completes the bridge as well, so its callback context stops being
            // retained even though native code never delivered.
            bridge.deliver(nil)
        }
        defer { timeoutTask.cancel() }

        return await withCheckedContinuation { continuation in
            resume.attach(continuation)
        }
    }
}
