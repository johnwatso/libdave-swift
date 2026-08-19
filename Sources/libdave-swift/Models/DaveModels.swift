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

/// What the coordinator does when the MLS roster contains a member the host
/// never listed as recognized.
///
/// Discord supplies the expected participants alongside a Welcome. A member
/// present in the resulting MLS roster but absent from that list is exactly the
/// signal an end-to-end encrypted call is supposed to make visible: someone is
/// in the cryptographic group who is not in the call the user believes they
/// joined.
public enum DaveRosterVerificationPolicy: String, Codable, Sendable {
    /// Surface unrecognized members through results and diagnostics, but let
    /// media continue. The host decides how to present or act on it.
    case report
    /// Treat an unrecognized member as unrecoverable: fail the session closed
    /// so no media is encrypted to, or decrypted from, that group.
    case failClosed
}

/// Resource limits applied by ``DaveSessionCoordinator`` before untrusted
/// gateway bytes are handed to the native MLS implementation.
///
/// The defaults are intentionally generous for Discord voice calls while still
/// preventing a malformed gateway payload from turning into an unbounded
/// allocation or native parse attempt. Hosts with a known smaller deployment
/// may lower them further.
public struct DaveCoordinatorLimits: Sendable, Equatable, Codable {
    public var maximumMlsPayloadBytes: Int
    public var maximumRosterMembers: Int
    public var maximumMediaFrameBytes: Int
    public var maximumTrackedTransitions: Int
    public var maximumPendingOutboundActions: Int
    /// Default seconds a transition may stay un-executed before the media
    /// readiness watchdog fails the session closed. Individual calls may still
    /// pass an explicit timeout.
    public var mediaReadinessTimeout: TimeInterval
    /// How an MLS roster member the host never recognized is handled.
    public var unrecognizedRosterMemberPolicy: DaveRosterVerificationPolicy
    /// State-machine events kept in the bounded diagnostic trace reported by
    /// ``DaveDiagnostics/recentEvents``. Older events are dropped first.
    public var traceEventCapacity: Int
    /// Events buffered per live subscriber of
    /// ``DaveSessionCoordinator/diagnosticEvents(bufferSize:)`` before the
    /// oldest are dropped. A slow consumer degrades its own stream rather than
    /// growing memory or stalling the coordinator.
    public var diagnosticEventBufferSize: Int

    public init(
        maximumMlsPayloadBytes: Int = 1_048_576,
        maximumRosterMembers: Int = 1_000,
        maximumMediaFrameBytes: Int = 65_535,
        maximumTrackedTransitions: Int = 64,
        maximumPendingOutboundActions: Int = 64,
        mediaReadinessTimeout: TimeInterval = 10,
        unrecognizedRosterMemberPolicy: DaveRosterVerificationPolicy = .report,
        traceEventCapacity: Int = 200,
        diagnosticEventBufferSize: Int = 256
    ) {
        self.maximumMlsPayloadBytes = max(1, maximumMlsPayloadBytes)
        self.maximumRosterMembers = max(1, maximumRosterMembers)
        self.maximumMediaFrameBytes = max(1, maximumMediaFrameBytes)
        self.maximumTrackedTransitions = max(1, maximumTrackedTransitions)
        self.maximumPendingOutboundActions = max(1, maximumPendingOutboundActions)
        self.mediaReadinessTimeout = max(0, mediaReadinessTimeout)
        self.unrecognizedRosterMemberPolicy = unrecognizedRosterMemberPolicy
        // A trace is a diagnostic aid, never a reason to grow without bound.
        self.traceEventCapacity = min(max(0, traceEventCapacity), 2_000)
        self.diagnosticEventBufferSize = min(max(1, diagnosticEventBufferSize), 4_096)
    }

    public static let `default` = DaveCoordinatorLimits()
}

/// Lifecycle state for Discord's MLS external sender package.
///
/// > Note: There is deliberately no `accepted` case. `daveSessionSetExternalSender`
/// > returns `void`, and the bundled C API exposes no query for whether a
/// > pending MLS group was created, so acceptance is not observable — only
/// > rejection is, through the native failure callback. Claiming `accepted`
/// > would be asserting something this library cannot check. If the native API
/// > later reports parse success, a case can be added without disturbing these.
public enum DaveExternalSenderState: String, Codable, Sendable {
    /// No external sender has been submitted for this session generation.
    case missing
    /// Non-empty sender bytes were handed to native MLS and no failure was
    /// reported. This is *not* proof that native MLS accepted the payload.
    case submitted
    /// Native MLS reported a failure for the submitted sender. The session is
    /// failed closed; recreate it before submitting another.
    case rejected

    /// Decoding accepts the pre-3.0 spelling `registered`, which meant exactly
    /// what ``submitted`` means now. Diagnostics are archived and forwarded to
    /// monitoring pipelines, so renaming a case must not turn existing records
    /// into decode errors.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "registered":
            self = .submitted
        default:
            guard let value = DaveExternalSenderState(rawValue: raw) else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "Unknown DaveExternalSenderState value '\(raw)'"
                    )
                )
            }
            self = value
        }
    }
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
    /// MLS roster after the most recently applied transition, as decimal
    /// Discord Snowflakes. Empty until a Welcome or Commit has been applied.
    public let rosterUserIds: [String]
    /// Roster members the host never listed as recognized. A non-empty value
    /// means the cryptographic group contains someone the voice session did
    /// not announce; see ``DaveRosterVerificationPolicy``.
    public let unrecognizedRosterUserIds: [String]

    public init(
        pendingActions: [DiscordDaveOutboundActionEnvelope],
        mediaReady: Bool,
        recoveryHint: DaveRecoveryHint,
        diagnostics: DaveDiagnostics,
        rosterUserIds: [String] = [],
        unrecognizedRosterUserIds: [String] = []
    ) {
        self.pendingActions = pendingActions
        self.mediaReady = mediaReady
        self.recoveryHint = recoveryHint
        self.diagnostics = diagnostics
        self.rosterUserIds = rosterUserIds
        self.unrecognizedRosterUserIds = unrecognizedRosterUserIds
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
    /// MLS roster after the most recently applied transition, as decimal
    /// Discord Snowflakes. Empty until a Welcome or Commit has been applied.
    public let rosterUserIds: [String]
    /// Roster members the host never listed as recognized. See
    /// ``DiscordDaveGatewayResult/unrecognizedRosterUserIds``.
    public let unrecognizedRosterUserIds: [String]

    public init(
        outboundActions: [DiscordDaveOutboundAction],
        mediaReady: Bool,
        recoveryHint: DaveRecoveryHint,
        diagnostics: DaveDiagnostics,
        rosterUserIds: [String] = [],
        unrecognizedRosterUserIds: [String] = []
    ) {
        self.outboundActions = outboundActions
        self.mediaReady = mediaReady
        self.recoveryHint = recoveryHint
        self.diagnostics = diagnostics
        self.rosterUserIds = rosterUserIds
        self.unrecognizedRosterUserIds = unrecognizedRosterUserIds
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
    case invalidAuthSessionId(String)
    case unrecognizedRosterMembers(userIds: [String])

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
        case .invalidAuthSessionId(let authSessionId):
            return "Invalid auth session ID: '\(authSessionId)'. It is used as a key-store filename, so it must be non-empty, at most 128 UTF-8 bytes, and free of path separators, '..', and control characters."
        case .unrecognizedRosterMembers(let userIds):
            return "The MLS roster contains \(userIds.count) member(s) the voice session never recognized: \(userIds.joined(separator: ", "))."
        }
    }

    /// Machine-readable classification, for callers that branch on failures
    /// rather than parsing `localizedDescription`.
    public var failureCode: DaveFailureCode {
        switch self {
        case .sessionCreationFailed, .encryptorCreationFailed, .decryptorCreationFailed:
            return .encryptorUnavailable
        case .handshakeFailed:
            return .commitProcessingFailed
        case .protocolMismatch, .unsupportedProtocolVersion:
            return .protocolVersionRejected
        case .invalidTransition:
            return .invalidPayload
        case .ratchetFailed:
            return .keyRatchetUnavailable
        case .encryptionFailed, .decryptionFailed:
            return .keyRatchetUnavailable
        case .bufferTooSmall:
            return .invalidPayload
        case .invalidState:
            return .unknown
        case .mediaNotReady:
            return .keyRatchetUnavailable
        case .invalidExternalSender:
            return .invalidPayload
        case .externalSenderRejected:
            return .externalSenderRejected
        case .externalSenderRequired:
            return .externalSenderMissing
        case .externalSenderConflict:
            return .externalSenderConflict
        case .invalidDiscordUserId, .invalidDiscordGroupId, .invalidAuthSessionId:
            return .invalidPayload
        case .transitionConflict:
            return .transitionConflict
        case .payloadTooLarge, .invalidMediaFrameSize:
            return .resourceLimitExceeded
        case .sessionFailed:
            return .nativeMlsFailure
        case .notConfigured:
            return .unknown
        case .unrecognizedRosterMembers:
            return .unrecognizedRosterMembers
        }
    }

    /// Where the failure came from.
    public var failureOrigin: DaveFailureOrigin {
        switch self {
        case .handshakeFailed, .externalSenderRejected, .sessionFailed, .ratchetFailed:
            return .nativeMls
        case .unrecognizedRosterMembers:
            return .policy
        default:
            return .wrapper
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
        case .invalidAuthSessionId:
            return .fatal
        case .unrecognizedRosterMembers:
            return .recreateSession
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
