import Foundation
import CDave

/// Internal class to route C-style callbacks to Swift closures in a thread-safe manner.
internal final class DaveSessionCallbackBridge: @unchecked Sendable {
    private let lock = NSLock()
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
        _lastFailure = (source, reason)
        let closure = _onMLSFailure
        lock.unlock()
        closure?(source, reason)
    }

    /// Returns and clears the most recently recorded native failure, if any.
    func takeLastFailure() -> (source: String, reason: String)? {
        lock.lock()
        defer { lock.unlock() }
        let failure = _lastFailure
        _lastFailure = nil
        return failure
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
    let callback: @Sendable (Data?) -> Void
    init(callback: @escaping @Sendable (Data?) -> Void) {
        self.callback = callback
    }
}

/// Global Pairwise Fingerprint callback router.
///
/// Consumes (`takeRetainedValue`) the per-call bridge so it is invoked at most
/// once and never leaks once the native side calls back.
internal func davePairwiseFingerprintCallbackBridge(
    fingerprint: UnsafePointer<UInt8>?,
    length: Int,
    userData: UnsafeMutableRawPointer?
) {
    guard let userData = userData else { return }
    let bridge = Unmanaged<DaveFingerprintCallbackBridge>.fromOpaque(userData).takeRetainedValue()
    let data = fingerprint.flatMap { length > 0 ? Data(bytes: $0, count: length) : nil }
    bridge.callback(data)
}

/// Internal class to route encryptor callbacks in a thread-safe manner.
internal final class DaveEncryptorCallbackBridge: @unchecked Sendable {
    private let lock = NSLock()
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
            _onProtocolVersionChanged = newValue
        }
    }

    init() {}
}

/// Global Encryptor Protocol Version Changed callback router.
internal func daveEncryptorProtocolVersionChangedCallbackBridge(userData: UnsafeMutableRawPointer?) {
    guard let userData = userData else { return }
    let bridge = Unmanaged<DaveEncryptorCallbackBridge>.fromOpaque(userData).takeUnretainedValue()
    bridge.onProtocolVersionChanged?()
}
