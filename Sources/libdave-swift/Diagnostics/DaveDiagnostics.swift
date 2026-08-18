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
    /// Monotonic identifier for the native MLS session currently owned by the
    /// coordinator. It changes after reset/recovery and is useful for
    /// correlating gateway logs without exposing key material.
    public let sessionGeneration: UInt64
    public let protocolVersion: UInt16
    /// Number of MLS transitions (welcome/commit) this coordinator has applied
    /// to the current session generation.
    ///
    /// The C API exposes no way to read the group's real MLS epoch, so this is
    /// a locally tracked counter — it does *not* match the epoch other group
    /// members see (e.g. joining an established group via welcome reports 1
    /// here regardless of the group's actual epoch).
    public let appliedTransitionCount: UInt64
    @available(*, deprecated, renamed: "appliedTransitionCount", message: "This was never the real MLS epoch, only a locally applied transition counter.")
    public var currentEpoch: UInt64 { appliedTransitionCount }
    public let handshakeState: DaveHandshakeState
    public let encryptionStats: DaveEncryptorStats?
    public let lastMlsError: String?
    public let lastTransitionTimestamp: Date?
    /// `true` means non-empty bytes were submitted to the native session. The
    /// current C API returns no parse status, so this is not cryptographic
    /// confirmation that the external sender was accepted.
    public let isExternalSenderRegistered: Bool
    public let mediaReady: Bool
    public let pendingEpoch: UInt64?
    public let pendingTransitionId: UInt64?
    /// Transition currently used by outbound media. A non-nil pending list
    /// means newer ratchets have been staged but are not active until Execute.
    public let activeTransitionId: UInt64?
    public let pendingTransitionIds: [UInt64]
    public let externalSenderState: DaveExternalSenderState
    public let lastRecoveryAction: DaveRecoveryAction?
    /// `true` after a key package has been generated/queued. It becomes
    /// `hasSentInitialKeyPackage` only after the host acknowledges delivery.
    public let hasIssuedInitialKeyPackage: Bool
    public let hasSentInitialKeyPackage: Bool
    public let pendingOutboundActionCount: Int
    /// Members in the MLS roster after the most recently applied transition.
    public let rosterMemberCount: Int
    /// Roster members the host never listed as recognized. Anything above zero
    /// means the cryptographic group is wider than the announced voice session.
    public let unrecognizedRosterMemberCount: Int
    /// Replay-ledger and staged-transition entries dropped to stay inside the
    /// configured bounds. A steadily rising value on a long call is expected;
    /// it is the signal that the session is aging out old state rather than
    /// hitting a hard limit.
    public let evictedTransitionCount: UInt64

    public init(
        sessionGeneration: UInt64 = 0,
        protocolVersion: UInt16,
        appliedTransitionCount: UInt64,
        handshakeState: DaveHandshakeState,
        encryptionStats: DaveEncryptorStats?,
        lastMlsError: String?,
        lastTransitionTimestamp: Date?,
        isExternalSenderRegistered: Bool,
        mediaReady: Bool = false,
        pendingEpoch: UInt64? = nil,
        pendingTransitionId: UInt64? = nil,
        activeTransitionId: UInt64? = nil,
        pendingTransitionIds: [UInt64] = [],
        externalSenderState: DaveExternalSenderState = .missing,
        lastRecoveryAction: DaveRecoveryAction? = nil,
        hasIssuedInitialKeyPackage: Bool = false,
        hasSentInitialKeyPackage: Bool = false,
        pendingOutboundActionCount: Int = 0,
        rosterMemberCount: Int = 0,
        unrecognizedRosterMemberCount: Int = 0,
        evictedTransitionCount: UInt64 = 0
    ) {
        self.sessionGeneration = sessionGeneration
        self.protocolVersion = protocolVersion
        self.appliedTransitionCount = appliedTransitionCount
        self.handshakeState = handshakeState
        self.encryptionStats = encryptionStats
        self.lastMlsError = lastMlsError
        self.lastTransitionTimestamp = lastTransitionTimestamp
        self.isExternalSenderRegistered = isExternalSenderRegistered
        self.mediaReady = mediaReady
        self.pendingEpoch = pendingEpoch
        self.pendingTransitionId = pendingTransitionId
        self.activeTransitionId = activeTransitionId
        self.pendingTransitionIds = pendingTransitionIds
        self.externalSenderState = externalSenderState
        self.lastRecoveryAction = lastRecoveryAction
        self.hasIssuedInitialKeyPackage = hasIssuedInitialKeyPackage
        self.hasSentInitialKeyPackage = hasSentInitialKeyPackage
        self.pendingOutboundActionCount = pendingOutboundActionCount
        self.rosterMemberCount = rosterMemberCount
        self.unrecognizedRosterMemberCount = unrecognizedRosterMemberCount
        self.evictedTransitionCount = evictedTransitionCount
    }

    /// Decoding tolerates payloads written by an older release: fields added
    /// after a diagnostics schema ships fall back to their defaults instead of
    /// failing the whole decode. Diagnostics are frequently persisted or
    /// forwarded to a monitoring pipeline, so a schema addition must not turn
    /// archived records into decode errors.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionGeneration = try container.decodeIfPresent(UInt64.self, forKey: .sessionGeneration) ?? 0
        protocolVersion = try container.decode(UInt16.self, forKey: .protocolVersion)
        appliedTransitionCount = try container.decode(UInt64.self, forKey: .appliedTransitionCount)
        handshakeState = try container.decode(DaveHandshakeState.self, forKey: .handshakeState)
        encryptionStats = try container.decodeIfPresent(DaveEncryptorStats.self, forKey: .encryptionStats)
        lastMlsError = try container.decodeIfPresent(String.self, forKey: .lastMlsError)
        lastTransitionTimestamp = try container.decodeIfPresent(Date.self, forKey: .lastTransitionTimestamp)
        isExternalSenderRegistered = try container.decode(Bool.self, forKey: .isExternalSenderRegistered)
        mediaReady = try container.decodeIfPresent(Bool.self, forKey: .mediaReady) ?? false
        pendingEpoch = try container.decodeIfPresent(UInt64.self, forKey: .pendingEpoch)
        pendingTransitionId = try container.decodeIfPresent(UInt64.self, forKey: .pendingTransitionId)
        activeTransitionId = try container.decodeIfPresent(UInt64.self, forKey: .activeTransitionId)
        pendingTransitionIds = try container.decodeIfPresent([UInt64].self, forKey: .pendingTransitionIds) ?? []
        externalSenderState = try container.decodeIfPresent(
            DaveExternalSenderState.self,
            forKey: .externalSenderState
        ) ?? .missing
        lastRecoveryAction = try container.decodeIfPresent(DaveRecoveryAction.self, forKey: .lastRecoveryAction)
        hasIssuedInitialKeyPackage = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasIssuedInitialKeyPackage
        ) ?? false
        hasSentInitialKeyPackage = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasSentInitialKeyPackage
        ) ?? false
        pendingOutboundActionCount = try container.decodeIfPresent(Int.self, forKey: .pendingOutboundActionCount) ?? 0
        rosterMemberCount = try container.decodeIfPresent(Int.self, forKey: .rosterMemberCount) ?? 0
        unrecognizedRosterMemberCount = try container.decodeIfPresent(
            Int.self,
            forKey: .unrecognizedRosterMemberCount
        ) ?? 0
        evictedTransitionCount = try container.decodeIfPresent(UInt64.self, forKey: .evictedTransitionCount) ?? 0
    }

    public var debugDescription: String {
        let timestampStr = lastTransitionTimestamp.flatMap { ISO8601DateFormatter().string(from: $0) } ?? "None"
        var statsStr = "None"
        if let stats = encryptionStats {
            statsStr = "Success: \(stats.encryptSuccessCount), Failure: \(stats.encryptFailureCount), Passthrough: \(stats.passthroughCount)"
        }
        return """
        DaveDiagnostics:
          Session Generation: \(sessionGeneration)
          Protocol Version: \(protocolVersion)
          Applied Transitions: \(appliedTransitionCount)
          Handshake State: \(handshakeState.rawValue)
          Media Ready: \(mediaReady)
          External Sender Registered: \(isExternalSenderRegistered)
          External Sender State: \(externalSenderState.rawValue)
          Pending Epoch: \(pendingEpoch.map(String.init) ?? "None")
          Pending Transition ID: \(pendingTransitionId.map(String.init) ?? "None")
          Active Transition ID: \(activeTransitionId.map(String.init) ?? "None")
          Staged Transition IDs: \(pendingTransitionIds.map(String.init).joined(separator: ", "))
          Last Recovery Action: \(lastRecoveryAction?.rawValue ?? "None")
          Initial Key Package Issued: \(hasIssuedInitialKeyPackage)
          Initial Key Package Sent: \(hasSentInitialKeyPackage)
          Pending Gateway Actions: \(pendingOutboundActionCount)
          Roster Members: \(rosterMemberCount)
          Unrecognized Roster Members: \(unrecognizedRosterMemberCount)
          Evicted Transitions: \(evictedTransitionCount)
          Last MLS Error: \(lastMlsError ?? "None")
          Last Transition Timestamp: \(timestampStr)
          Encryption Stats (Audio): \(statsStr)
        """
    }
}
