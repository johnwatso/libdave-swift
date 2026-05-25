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

/// Errors thrown by the LibDave module.
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
        case .notConfigured:
            return "DAVE Session Coordinator is not configured. Please call configureForDiscordVoice first."
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
