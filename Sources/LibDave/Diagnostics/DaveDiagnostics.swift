import Foundation

/// Defines the handshake/registration states of the DAVE coordinator.
public enum DaveHandshakeState: String, Codable, Sendable {
    case uninitialized = "Uninitialized"
    case initialized = "Initialized"
    case handshaking = "Handshaking"
    case ready = "Ready"
    case failed = "Failed"
}

/// Lightweight diagnostics exposing session state and encryption health.
public struct DaveDiagnostics: Codable, Sendable, CustomDebugStringConvertible {
    public let protocolVersion: UInt16
    public let currentEpoch: UInt64
    public let handshakeState: DaveHandshakeState
    public let encryptionStats: DaveEncryptorStats?
    public let lastMlsError: String?
    public let lastTransitionTimestamp: Date?
    public let isExternalSenderRegistered: Bool

    public init(
        protocolVersion: UInt16,
        currentEpoch: UInt64,
        handshakeState: DaveHandshakeState,
        encryptionStats: DaveEncryptorStats?,
        lastMlsError: String?,
        lastTransitionTimestamp: Date?,
        isExternalSenderRegistered: Bool
    ) {
        self.protocolVersion = protocolVersion
        self.currentEpoch = currentEpoch
        self.handshakeState = handshakeState
        self.encryptionStats = encryptionStats
        self.lastMlsError = lastMlsError
        self.lastTransitionTimestamp = lastTransitionTimestamp
        self.isExternalSenderRegistered = isExternalSenderRegistered
    }

    public var debugDescription: String {
        let timestampStr = lastTransitionTimestamp.flatMap { ISO8601DateFormatter().string(from: $0) } ?? "None"
        var statsStr = "None"
        if let stats = encryptionStats {
            statsStr = "Success: \(stats.encryptSuccessCount), Failure: \(stats.encryptFailureCount), Passthrough: \(stats.passthroughCount)"
        }
        return """
        DaveDiagnostics:
          Protocol Version: \(protocolVersion)
          Current Epoch: \(currentEpoch)
          Handshake State: \(handshakeState.rawValue)
          External Sender Registered: \(isExternalSenderRegistered)
          Last MLS Error: \(lastMlsError ?? "None")
          Last Transition Timestamp: \(timestampStr)
          Encryption Stats (Audio): \(statsStr)
        """
    }
}
