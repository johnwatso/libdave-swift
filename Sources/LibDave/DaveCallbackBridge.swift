import Foundation
import CDave

/// Internal class to route C-style callbacks to Swift closures.
internal class DaveSessionCallbackBridge {
    var onMLSFailure: ((String, String) -> Void)?
    var onPairwiseFingerprint: ((Data) -> Void)?

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

/// Internal class to route encryptor callbacks.
internal class DaveEncryptorCallbackBridge {
    var onProtocolVersionChanged: (() -> Void)?

    init() {}
}

/// Global Encryptor Protocol Version Changed callback router.
internal func daveEncryptorProtocolVersionChangedCallbackBridge(userData: UnsafeMutableRawPointer?) {
    guard let userData = userData else { return }
    let bridge = Unmanaged<DaveEncryptorCallbackBridge>.fromOpaque(userData).takeUnretainedValue()
    bridge.onProtocolVersionChanged?()
}
