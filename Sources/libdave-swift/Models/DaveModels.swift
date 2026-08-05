import Foundation
import CDave

/// Supported media codecs for encryption.
public enum DaveCodec: UInt32, Codable, Sendable, CustomStringConvertible {
    case unknown = 0
    case opus = 1
    case vp8 = 2
    case vp9 = 3
    case h264 = 4
    case h265 = 5
    case av1 = 6

    public var description: String {
        switch self {
        case .unknown: return "Unknown"
        case .opus: return "Opus"
        case .vp8: return "VP8"
        case .vp9: return "VP9"
        case .h264: return "H.264"
        case .h265: return "H.265"
        case .av1: return "AV1"
        }
    }

    internal init(_ cValue: DAVECodec) {
        self = DaveCodec(rawValue: cValue.rawValue) ?? .unknown
    }

    internal var cValue: DAVECodec {
        return DAVECodec(rawValue: self.rawValue)
    }
}

/// Media stream type classification.
public enum DaveMediaType: UInt32, Codable, Sendable, CustomStringConvertible {
    case audio = 0
    case video = 1

    public var description: String {
        switch self {
        case .audio: return "Audio"
        case .video: return "Video"
        }
    }

    internal init(_ cValue: DAVEMediaType) {
        self = DaveMediaType(rawValue: cValue.rawValue) ?? .audio
    }

    internal var cValue: DAVEMediaType {
        return DAVEMediaType(rawValue: self.rawValue)
    }
}

/// Severity levels for logging.
public enum DaveLoggingSeverity: UInt32, Codable, Sendable, CustomStringConvertible {
    case verbose = 0
    case info = 1
    case warning = 2
    case error = 3
    case none = 4

    public var description: String {
        switch self {
        case .verbose: return "Verbose"
        case .info: return "Info"
        case .warning: return "Warning"
        case .error: return "Error"
        case .none: return "None"
        }
    }

    internal init(_ cValue: DAVELoggingSeverity) {
        self = DaveLoggingSeverity(rawValue: cValue.rawValue) ?? .none
    }

    internal var cValue: DAVELoggingSeverity {
        return DAVELoggingSeverity(rawValue: self.rawValue)
    }
}

/// Result codes returned by encryption operations.
public enum DaveEncryptorResultCode: UInt32, Error, Sendable, CustomStringConvertible {
    case success = 0
    case encryptionFailure = 1
    case missingKeyRatchet = 2
    case missingCryptor = 3
    case tooManyAttempts = 4

    public var description: String {
        switch self {
        case .success: return "Success"
        case .encryptionFailure: return "Encryption Failure"
        case .missingKeyRatchet: return "Missing Key Ratchet"
        case .missingCryptor: return "Missing Cryptor"
        case .tooManyAttempts: return "Too Many Attempts"
        }
    }

    internal init(_ cValue: DAVEEncryptorResultCode) {
        self = DaveEncryptorResultCode(rawValue: cValue.rawValue) ?? .encryptionFailure
    }
}

/// Result codes returned by decryption operations.
public enum DaveDecryptorResultCode: UInt32, Error, Sendable, CustomStringConvertible {
    case success = 0
    case decryptionFailure = 1
    case missingKeyRatchet = 2
    case invalidNonce = 3
    case missingCryptor = 4

    public var description: String {
        switch self {
        case .success: return "Success"
        case .decryptionFailure: return "Decryption Failure"
        case .missingKeyRatchet: return "Missing Key Ratchet"
        case .invalidNonce: return "Invalid Nonce"
        case .missingCryptor: return "Missing Cryptor"
        }
    }

    internal init(_ cValue: DAVEDecryptorResultCode) {
        self = DaveDecryptorResultCode(rawValue: cValue.rawValue) ?? .decryptionFailure
    }
}

/// Recovery guidance callers can use without parsing human-readable error text.
public enum DaveRecoveryHint: String, Codable, Sendable, CustomStringConvertible {
    /// No special recovery action is suggested.
    case none
    /// The operation raced a state transition; retry after the next DAVE event.
    case retryLater
    /// Wait for Discord's MLS external sender package before publishing a key package.
    case waitForExternalSender
    /// Notify Discord that the commit/welcome was invalid for the current session.
    case sendInvalidCommitWelcome
    /// Recreate the MLS session and publish a fresh key package.
    case recreateSession
    /// The caller should treat this as unrecoverable for the current voice session.
    case fatal

    public var description: String {
        rawValue
    }
}

/// Resource limits applied by ``DaveSessionCoordinator`` before untrusted
/// gateway bytes are handed to the native MLS implementation.
///
/// The defaults are intentionally generous for Discord voice calls while still
/// preventing a malformed gateway payload from turning into an unbounded
/// allocation or native parse attempt. Hosts with a known smaller deployment
/// may lower them further.
public struct DaveCoordinatorLimits: Sendable, Equatable {
    public var maximumMlsPayloadBytes: Int
    public var maximumRosterMembers: Int
    public var maximumMediaFrameBytes: Int
    public var maximumTrackedTransitions: Int
    public var maximumPendingOutboundActions: Int

    public init(
        maximumMlsPayloadBytes: Int = 1_048_576,
        maximumRosterMembers: Int = 1_000,
        maximumMediaFrameBytes: Int = 65_535,
        maximumTrackedTransitions: Int = 64,
        maximumPendingOutboundActions: Int = 64
    ) {
        self.maximumMlsPayloadBytes = max(1, maximumMlsPayloadBytes)
        self.maximumRosterMembers = max(1, maximumRosterMembers)
        self.maximumMediaFrameBytes = max(1, maximumMediaFrameBytes)
        self.maximumTrackedTransitions = max(1, maximumTrackedTransitions)
        self.maximumPendingOutboundActions = max(1, maximumPendingOutboundActions)
    }

    public static let `default` = DaveCoordinatorLimits()
}

/// Coarse lifecycle state for Discord's MLS external sender package.
public enum DaveExternalSenderState: String, Codable, Sendable {
    case missing
    /// Non-empty sender bytes were submitted to the current native session.
    /// The bundled C API does not expose parse success, so this is not proof
    /// that native MLS accepted the payload.
    case registered
}

/// Last meaningful recovery or state-machine action performed by the coordinator.
public enum DaveRecoveryAction: String, Codable, Sendable {
    case reset
    case recreateSession
    case rebuildEncryptor
    case registerExternalSender
    case sendInitialKeyPackage
    case processProposals
    case processWelcome
    case processCommit
    case pauseMedia
    case resumeMedia
    case invalidTransitionRecovery
    case stageTransition
    case activateTransition
    case prepareProtocolVersion
    case queueOutboundAction
    case acknowledgeOutboundAction
    case failClosed
}

/// Outbound Discord DAVE action emitted by the high-level coordinator helpers.
public enum DiscordDaveOutboundAction: Sendable, Equatable {
    /// Send as binary opcode 26 (`daveMlsKeyPackage`).
    case mlsKeyPackage(Data)
    /// Send as binary opcode 28 (`daveMlsCommitWelcome`).
    case mlsCommitWelcome(Data)
    /// Send as voice gateway opcode 23 (`daveTransitionReady`).
    case transitionReady(UInt64)
    /// Send as voice gateway opcode 31 (`daveMlsInvalidCommitWelcome`).
    case invalidCommitWelcome(UInt64)
}

/// A gateway action kept in the coordinator's bounded outbox until the host
/// acknowledges a successful WebSocket write. The identifier is stable across
/// retries, so callers can resend the exact same bytes without re-running MLS.
public struct DiscordDaveOutboundActionEnvelope: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let action: DiscordDaveOutboundAction

    public init(id: UUID = UUID(), action: DiscordDaveOutboundAction) {
        self.id = id
        self.action = action
    }
}

/// A DAVE/MLS gateway event that can be consumed by the coordinator's safe
/// state-machine entry point. Transport-only downgrade handling remains the
/// voice client's responsibility because libdave does not own RTP transport
/// encryption.
public enum DiscordDaveGatewayEvent: Sendable, Equatable {
    case externalSender(Data)
    case proposals(Data, recognizedUserIds: [String])
    case welcome(Data, transitionId: UInt64, recognizedUserIds: [String])
    case commit(Data, transitionId: UInt64)
    case executeTransition(UInt64)
    /// Opcode 24's `transition_id` binds the prepared protocol context to the
    /// later Execute Transition. It must never be inferred from the MLS epoch.
    case prepareEpoch(protocolVersion: UInt16, epoch: UInt64, transitionId: UInt64)
}

/// Result of consuming a ``DiscordDaveGatewayEvent``. `pendingActions` remain
/// available from ``DaveSessionCoordinator/pendingDiscordGatewayActions()``
/// until each one is acknowledged after a successful gateway write.
public struct DiscordDaveGatewayResult: Sendable {
    public let pendingActions: [DiscordDaveOutboundActionEnvelope]
    public let mediaReady: Bool
    public let recoveryHint: DaveRecoveryHint
    public let diagnostics: DaveDiagnostics

    public init(
        pendingActions: [DiscordDaveOutboundActionEnvelope],
        mediaReady: Bool,
        recoveryHint: DaveRecoveryHint,
        diagnostics: DaveDiagnostics
    ) {
        self.pendingActions = pendingActions
        self.mediaReady = mediaReady
        self.recoveryHint = recoveryHint
        self.diagnostics = diagnostics
    }

    public var needsRecovery: Bool {
        switch recoveryHint {
        case .none, .retryLater, .waitForExternalSender:
            return false
        case .sendInvalidCommitWelcome, .recreateSession, .fatal:
            return true
        }
    }
}

/// Result from a high-level Discord DAVE state-machine step.
public struct DiscordDaveTransitionResult: Sendable {
    public let outboundActions: [DiscordDaveOutboundAction]
    public let mediaReady: Bool
    public let recoveryHint: DaveRecoveryHint
    public let diagnostics: DaveDiagnostics

    public init(
        outboundActions: [DiscordDaveOutboundAction],
        mediaReady: Bool,
        recoveryHint: DaveRecoveryHint,
        diagnostics: DaveDiagnostics
    ) {
        self.outboundActions = outboundActions
        self.mediaReady = mediaReady
        self.recoveryHint = recoveryHint
        self.diagnostics = diagnostics
    }

    public var needsRecovery: Bool {
        switch recoveryHint {
        case .none, .retryLater, .waitForExternalSender:
            return false
        case .sendInvalidCommitWelcome, .recreateSession, .fatal:
            return true
        }
    }
}

/// Status for the coordinator-owned DAVE media-readiness watchdog.
public enum DaveMediaReadinessWatchdogStatus: Sendable, Equatable {
    case inactive
    case pending(secondsRemaining: TimeInterval)
    case timedOut(reason: String, recoveryHint: DaveRecoveryHint)
}

/// Errors thrown by the libdave-swift module.
public enum DaveError: Error, LocalizedError, Sendable {
    case sessionCreationFailed
    case encryptorCreationFailed
    case decryptorCreationFailed
    case handshakeFailed(reason: String)
    case protocolMismatch(expected: UInt16, actual: UInt16)
    case invalidTransition(message: String)
    case ratchetFailed(userId: String, reason: String)
    case encryptionFailed(reason: DaveEncryptorResultCode)
    case decryptionFailed(reason: DaveDecryptorResultCode)
    case bufferTooSmall
    case invalidState(message: String)
    case mediaNotReady
    case invalidExternalSender
    case externalSenderRejected(reason: String)
    case invalidDiscordUserId(String)
    case invalidDiscordGroupId(UInt64)
    case unsupportedProtocolVersion(requested: UInt16, maximumSupported: UInt16)
    case externalSenderRequired
    case externalSenderConflict
    case transitionConflict(transitionId: UInt64)
    case payloadTooLarge(kind: String, maximum: Int, actual: Int)
    case invalidMediaFrameSize(actual: Int, maximum: Int)
    case sessionFailed
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case .sessionCreationFailed:
            return "Failed to create DAVE session."
        case .encryptorCreationFailed:
            return "Failed to create media frame encryptor."
        case .decryptorCreationFailed:
            return "Failed to create media frame decryptor."
        case .handshakeFailed(let reason):
            return "DAVE handshake failed: \(reason)"
        case .protocolMismatch(let expected, let actual):
            return "DAVE protocol version mismatch: expected version \(expected), but got \(actual)."
        case .invalidTransition(let message):
            return "Invalid transition occurred: \(message)"
        case .ratchetFailed(let userId, let reason):
            return "Failed to transition key ratchet for user '\(userId)': \(reason)"
        case .encryptionFailed(let reason):
            return "Media frame encryption failed: \(reason.description)"
        case .decryptionFailed(let reason):
            return "Media frame decryption failed: \(reason.description)"
        case .bufferTooSmall:
            return "The destination buffer capacity was insufficient."
        case .invalidState(let message):
            return "Invalid session state: \(message)"
        case .mediaNotReady:
            return "DAVE media is not ready. Wait for the matching Execute Transition signal before processing media."
        case .invalidExternalSender:
            return "Invalid external sender: the serialized payload must not be empty."
        case .externalSenderRejected(let reason):
            return "The native MLS implementation rejected the external sender: \(reason)"
        case .invalidDiscordUserId(let userId):
            return "Invalid Discord user ID: '\(userId)'. Expected a non-zero unsigned decimal Snowflake."
        case .invalidDiscordGroupId(let groupId):
            return "Invalid Discord group ID: '\(groupId)'. Expected a non-zero Guild Snowflake."
        case .unsupportedProtocolVersion(let requested, let maximumSupported):
            return "Unsupported DAVE protocol version \(requested). This library supports versions 1 through \(maximumSupported)."
        case .externalSenderRequired:
            return "A Discord MLS external sender package is required before publishing an initial key package."
        case .externalSenderConflict:
            return "Conflicting Discord MLS external sender packages were received for the same session."
        case .transitionConflict(let transitionId):
            return "Conflicting DAVE gateway payloads were received for transition \(transitionId)."
        case .payloadTooLarge(let kind, let maximum, let actual):
            return "DAVE \(kind) payload is too large (\(actual) bytes; maximum \(maximum))."
        case .invalidMediaFrameSize(let actual, let maximum):
            return "DAVE media frame is too large (\(actual) bytes; maximum \(maximum))."
        case .sessionFailed:
            return "The DAVE session has failed closed. Recreate it before accepting more gateway events."
        case .notConfigured:
            return "DAVE Session Coordinator is not configured. Please call configureForDiscordVoice first."
        }
    }

    /// Machine-readable recovery guidance for callers that want to automate
    /// Discord voice-session recovery without parsing `localizedDescription`.
    public var recoveryHint: DaveRecoveryHint {
        switch self {
        case .sessionCreationFailed, .encryptorCreationFailed, .decryptorCreationFailed:
            return .fatal
        case .handshakeFailed:
            return .sendInvalidCommitWelcome
        case .protocolMismatch:
            return .recreateSession
        case .invalidTransition:
            return .sendInvalidCommitWelcome
        case .ratchetFailed:
            return .recreateSession
        case .encryptionFailed(let reason):
            switch reason {
            case .missingKeyRatchet, .missingCryptor:
                return .retryLater
            case .tooManyAttempts, .encryptionFailure, .success:
                return .recreateSession
            }
        case .decryptionFailed(let reason):
            switch reason {
            case .missingKeyRatchet, .missingCryptor:
                return .retryLater
            case .invalidNonce, .decryptionFailure, .success:
                return .recreateSession
            }
        case .bufferTooSmall:
            return .fatal
        case .invalidState:
            return .retryLater
        case .mediaNotReady:
            return .retryLater
        case .invalidExternalSender:
            return .waitForExternalSender
        case .externalSenderRejected:
            return .recreateSession
        case .invalidDiscordUserId:
            return .fatal
        case .invalidDiscordGroupId, .unsupportedProtocolVersion:
            return .fatal
        case .externalSenderRequired:
            return .waitForExternalSender
        case .externalSenderConflict:
            return .recreateSession
        case .transitionConflict:
            return .recreateSession
        case .payloadTooLarge, .invalidMediaFrameSize:
            return .fatal
        case .sessionFailed:
            return .recreateSession
        case .notConfigured:
            return .fatal
        }
    }
}

/// Statistics for encryption operations.
public struct DaveEncryptorStats: Codable, Sendable {
    public let passthroughCount: UInt64
    public let encryptSuccessCount: UInt64
    public let encryptFailureCount: UInt64
    public let encryptDuration: UInt64
    public let encryptAttempts: UInt64
    public let encryptMaxAttempts: UInt64
    public let encryptMissingKeyCount: UInt64

    internal init(_ cStats: DAVEEncryptorStats) {
        self.passthroughCount = cStats.passthroughCount
        self.encryptSuccessCount = cStats.encryptSuccessCount
        self.encryptFailureCount = cStats.encryptFailureCount
        self.encryptDuration = cStats.encryptDuration
        self.encryptAttempts = cStats.encryptAttempts
        self.encryptMaxAttempts = cStats.encryptMaxAttempts
        self.encryptMissingKeyCount = cStats.encryptMissingKeyCount
    }
}

/// Statistics for decryption operations.
public struct DaveDecryptorStats: Codable, Sendable {
    public let passthroughCount: UInt64
    public let decryptSuccessCount: UInt64
    public let decryptFailureCount: UInt64
    public let decryptDuration: UInt64
    public let decryptAttempts: UInt64
    public let decryptMissingKeyCount: UInt64
    public let decryptInvalidNonceCount: UInt64

    internal init(_ cStats: DAVEDecryptorStats) {
        self.passthroughCount = cStats.passthroughCount
        self.decryptSuccessCount = cStats.decryptSuccessCount
        self.decryptFailureCount = cStats.decryptFailureCount
        self.decryptDuration = cStats.decryptDuration
        self.decryptAttempts = cStats.decryptAttempts
        self.decryptMissingKeyCount = cStats.decryptMissingKeyCount
        self.decryptInvalidNonceCount = cStats.decryptInvalidNonceCount
    }
}
