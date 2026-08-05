import Foundation
import CDave

/// Keeps C callback contexts alive after their Swift owners have gone away.
///
/// The native C API stores `void *` callback contexts but does not provide an
/// unregister-and-drain operation, nor does it document that destruction
/// waits for callbacks already queued on another thread. Releasing a Swift
/// object immediately after destroying its native owner would therefore leave
/// a possible use-after-free in the C-to-Swift callback trampoline.
///
/// Contexts registered here deliberately live until process exit. Their
/// owners call `deactivate()` during teardown, which releases application
/// closures and makes later callbacks no-ops. This is a small, intentional
/// tombstone allocation per native callback owner; it is the only safe
/// lifetime policy available with the current ABI. The native library should
/// eventually provide either an unregister-and-drain API or a documented
/// guarantee that no callback can begin after its owner is destroyed.
internal final class DaveNativeCallbackContextRetainer: @unchecked Sendable {
    static let shared = DaveNativeCallbackContextRetainer()

    private let lock = NSLock()
    private var contexts: [AnyObject] = []

    private init() {}

    func retainForNativeLifetime(_ context: AnyObject) {
        lock.lock()
        contexts.append(context)
        lock.unlock()
    }
}

/// Internal class to route C-style callbacks to Swift closures in a thread-safe manner.
internal final class DaveSessionCallbackBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var isActive = true
    private var _onMLSFailure: (@Sendable (String, String) -> Void)?
    private var _lastFailure: (source: String, reason: String)?

    var onMLSFailure: (@Sendable (String, String) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onMLSFailure
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            guard isActive else { return }
            _onMLSFailure = newValue
        }
    }

    /// Records a native MLS failure synchronously (so callers can read the
    /// reason immediately after a native call returns) and forwards it to the
    /// registered closure. The native side may invoke the failure callback
    /// inline during `processCommit`/`processWelcome`/`processProposals`; the
    /// closure path hops to the actor asynchronously, so the synchronous
    /// `_lastFailure` slot is what lets us attach the real reason to a throw.
    func recordFailure(source: String, reason: String) {
        lock.lock()
        guard isActive else {
            lock.unlock()
            return
        }
        _lastFailure = (source, reason)
        let closure = _onMLSFailure
        lock.unlock()
        closure?(source, reason)
    }

    /// Returns and clears the most recently recorded native failure, if any.
    func takeLastFailure() -> (source: String, reason: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard isActive else { return nil }
        let failure = _lastFailure
        _lastFailure = nil
        return failure
    }

    /// Stops routing callbacks and drops application-owned state. The bridge
    /// itself remains retained by ``DaveNativeCallbackContextRetainer`` so a
    /// late native invocation can safely return without touching a released
    /// Swift object.
    func deactivate() {
        lock.lock()
        isActive = false
        _onMLSFailure = nil
        _lastFailure = nil
        lock.unlock()
    }

    init() {}
}

/// Global MLS Failure callback router.
internal func daveMLSFailureCallbackBridge(
    source: UnsafePointer<CChar>?,
    reason: UnsafePointer<CChar>?,
    userData: UnsafeMutableRawPointer?
) {
    guard let userData = userData else { return }
    let bridge = Unmanaged<DaveSessionCallbackBridge>.fromOpaque(userData).takeUnretainedValue()
    let sourceStr = source.flatMap { String(cString: $0) } ?? "Unknown"
    let reasonStr = reason.flatMap { String(cString: $0) } ?? "Unknown"
    bridge.recordFailure(source: sourceStr, reason: reasonStr)
}

/// Single-shot bridge for one pairwise-fingerprint request.
///
/// Each `getPairwiseFingerprint` call gets its own bridge so concurrent
/// requests cannot clobber each other's closure (the previous shared-bridge
/// design could drop a callback, leaving an awaiting caller wedged forever).
internal final class DaveFingerprintCallbackBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (Data?) -> Void)?

    init(callback: @escaping @Sendable (Data?) -> Void) {
        self.callback = callback
    }

    /// Delivers at most once. A malformed or late native callback cannot
    /// resume a Swift continuation twice.
    func deliver(_ fingerprint: Data?) {
        lock.lock()
        let callback = self.callback
        self.callback = nil
        lock.unlock()
        callback?(fingerprint)
    }
}

/// Global Pairwise Fingerprint callback router.
///
/// The bridge is retained for native lifetime because the C API does not
/// document callback timing or a drain operation. `deliver` itself is
/// single-shot, so duplicate callbacks are harmless.
internal func davePairwiseFingerprintCallbackBridge(
    fingerprint: UnsafePointer<UInt8>?,
    length: Int,
    userData: UnsafeMutableRawPointer?
) {
    guard let userData = userData else { return }
    let bridge = Unmanaged<DaveFingerprintCallbackBridge>.fromOpaque(userData).takeUnretainedValue()
    let data = fingerprint.flatMap { length > 0 ? Data(bytes: $0, count: length) : nil }
    bridge.deliver(data)
}

/// Internal class to route encryptor callbacks in a thread-safe manner.
internal final class DaveEncryptorCallbackBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var isActive = true
    private var _onProtocolVersionChanged: (@Sendable () -> Void)?

    var onProtocolVersionChanged: (@Sendable () -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onProtocolVersionChanged
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            guard isActive else { return }
            _onProtocolVersionChanged = newValue
        }
    }

    /// Invokes the current callback, if this bridge still belongs to a live
    /// encryptor. Copying the closure under the lock keeps callback replacement
    /// and native delivery race-free.
    func notifyProtocolVersionChanged() {
        lock.lock()
        guard isActive else {
            lock.unlock()
            return
        }
        let closure = _onProtocolVersionChanged
        lock.unlock()
        closure?()
    }

    /// Makes all future native deliveries no-ops and releases the callback
    /// closure. See ``DaveNativeCallbackContextRetainer`` for why the bridge
    /// object itself cannot be reclaimed deterministically yet.
    func deactivate() {
        lock.lock()
        isActive = false
        _onProtocolVersionChanged = nil
        lock.unlock()
    }

    init() {}
}

/// Global Encryptor Protocol Version Changed callback router.
internal func daveEncryptorProtocolVersionChangedCallbackBridge(userData: UnsafeMutableRawPointer?) {
    guard let userData = userData else { return }
    let bridge = Unmanaged<DaveEncryptorCallbackBridge>.fromOpaque(userData).takeUnretainedValue()
    bridge.notifyProtocolVersionChanged()
}
