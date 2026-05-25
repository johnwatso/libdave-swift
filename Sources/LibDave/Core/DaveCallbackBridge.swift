import Foundation
import CDave

/// Internal class to route C-style callbacks to Swift closures in a thread-safe manner.
internal final class DaveSessionCallbackBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var _onMLSFailure: (@Sendable (String, String) -> Void)?
    private var _onPairwiseFingerprint: (@Sendable (Data) -> Void)?

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

    var onPairwiseFingerprint: (@Sendable (Data) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onPairwiseFingerprint
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _onPairwiseFingerprint = newValue
        }
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
    bridge.onMLSFailure?(sourceStr, reasonStr)
}

/// Global Pairwise Fingerprint callback router.
internal func davePairwiseFingerprintCallbackBridge(
    fingerprint: UnsafePointer<UInt8>?,
    length: Int,
    userData: UnsafeMutableRawPointer?
) {
    guard let userData = userData else { return }
    let bridge = Unmanaged<DaveSessionCallbackBridge>.fromOpaque(userData).takeUnretainedValue()
    if let fingerprint = fingerprint {
        let data = Data(bytes: fingerprint, count: length)
        bridge.onPairwiseFingerprint?(data)
    }
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
