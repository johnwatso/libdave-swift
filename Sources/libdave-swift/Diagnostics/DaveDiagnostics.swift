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
    public let mediaReady: Bool
    public let pendingEpoch: UInt64?
    public let pendingTransitionId: UInt64?
    public let externalSenderState: DaveExternalSenderState
    public let lastRecoveryAction: DaveRecoveryAction?
    public let hasSentInitialKeyPackage: Bool

    public init(
        protocolVersion: UInt16,
        currentEpoch: UInt64,
        handshakeState: DaveHandshakeState,
        encryptionStats: DaveEncryptorStats?,
        lastMlsError: String?,
        lastTransitionTimestamp: Date?,
        isExternalSenderRegistered: Bool,
        mediaReady: Bool = false,
        pendingEpoch: UInt64? = nil,
        pendingTransitionId: UInt64? = nil,
        externalSenderState: DaveExternalSenderState = .missing,
        lastRecoveryAction: DaveRecoveryAction? = nil,
        hasSentInitialKeyPackage: Bool = false
    ) {
        self.protocolVersion = protocolVersion
        self.currentEpoch = currentEpoch
        self.handshakeState = handshakeState
        self.encryptionStats = encryptionStats
        self.lastMlsError = lastMlsError
        self.lastTransitionTimestamp = lastTransitionTimestamp
        self.isExternalSenderRegistered = isExternalSenderRegistered
        self.mediaReady = mediaReady
        self.pendingEpoch = pendingEpoch
        self.pendingTransitionId = pendingTransitionId
        self.externalSenderState = externalSenderState
        self.lastRecoveryAction = lastRecoveryAction
        self.hasSentInitialKeyPackage = hasSentInitialKeyPackage
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
          Media Ready: \(mediaReady)
          External Sender Registered: \(isExternalSenderRegistered)
          External Sender State: \(externalSenderState.rawValue)
          Pending Epoch: \(pendingEpoch.map(String.init) ?? "None")
          Pending Transition ID: \(pendingTransitionId.map(String.init) ?? "None")
          Last Recovery Action: \(lastRecoveryAction?.rawValue ?? "None")
          Initial Key Package Sent: \(hasSentInitialKeyPackage)
          Last MLS Error: \(lastMlsError ?? "None")
          Last Transition Timestamp: \(timestampStr)
          Encryption Stats (Audio): \(statsStr)
        """
    }
}
