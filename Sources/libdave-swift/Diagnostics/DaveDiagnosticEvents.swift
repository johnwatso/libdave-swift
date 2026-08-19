import Foundation

/// What happened in the coordinator's state machine.
///
/// These are the observable transitions a host needs in order to explain a
/// voice session after the fact: what arrived, what it did, and what changed as
/// a result. Media frame processing is deliberately absent — it runs fifty
/// times a second per stream and would drown the signal.
public enum DaveDiagnosticEventKind: String, Codable, Sendable, CustomStringConvertible {
    /// The coordinator was configured for a Discord voice session.
    case sessionConfigured
    /// Session state was reset or recreated.
    case sessionReset
    /// The session failed closed; media capability was revoked.
    case sessionFailedClosed
    /// A gateway event arrived and was dispatched into the state machine.
    case gatewayEventReceived
    /// Discord's MLS external sender was submitted to native MLS.
    case externalSenderSubmitted
    /// An MLS welcome was processed.
    case welcomeProcessed
    /// An MLS commit was processed.
    case commitProcessed
    /// MLS proposals were processed into a commit/welcome payload.
    case proposalsProcessed
    /// A future outbound ratchet was staged, awaiting Execute Transition.
    case transitionStaged
    /// A staged transition became the active outbound media context.
    case transitionActivated
    /// A Discord epoch preparation was handled.
    case epochPrepared
    /// The roster from an applied transition was recorded and checked.
    case rosterApplied
    /// Media readiness changed.
    case mediaReadinessChanged
    /// The media-readiness watchdog started for a pending transition.
    case watchdogStarted
    /// The media-readiness watchdog expired and failed the session closed.
    case watchdogExpired
    /// A native MLS failure callback was received.
    case nativeMlsFailure
    /// A recovery action was taken.
    case recoveryPerformed
    /// An outbound gateway action was queued into the outbox.
    case outboundActionQueued
    /// The host acknowledged a successful gateway write.
    case outboundActionAcknowledged
    /// Bounded state was aged out to stay inside its configured limit.
    case stateEvicted

    public var description: String { rawValue }
}

/// The result of a state-machine event.
public enum DaveDiagnosticEventOutcome: String, Codable, Sendable, CustomStringConvertible {
    /// The event changed MLS state.
    case applied
    /// A future ratchet was recorded but is not yet in use.
    case staged
    /// A staged context became active for media.
    case activated
    /// A duplicate of an event already handled; served from the replay ledger.
    case replayed
    /// The event was refused before it could change state.
    case rejected
    /// The event failed after entering native MLS.
    case failed
    /// Informational: the event records a state change with no pass/fail sense.
    case observed

    public var description: String { rawValue }
}

/// Where a failure originated.
public enum DaveFailureOrigin: String, Codable, Sendable {
    /// Reported by the native MLS implementation.
    case nativeMls
    /// Detected by this wrapper before or after crossing into native code.
    case wrapper
    /// A configured policy (for example an unrecognized roster member) refused
    /// to continue even though nothing malfunctioned.
    case policy
}

/// Machine-readable failure classification.
///
/// Hosts should branch on this rather than parsing human-readable text, which
/// is not a stable interface.
public enum DaveFailureCode: String, Codable, Sendable {
    case externalSenderRejected
    case externalSenderConflict
    case externalSenderMissing
    case welcomeProcessingFailed
    case commitProcessingFailed
    case proposalsProcessingFailed
    case keyRatchetUnavailable
    case encryptorUnavailable
    case transitionConflict
    case watchdogExpired
    case protocolVersionRejected
    case unrecognizedRosterMembers
    case resourceLimitExceeded
    case invalidPayload
    case nativeMlsFailure
    case unknown
}

/// A structured, exportable description of a failure.
///
/// Every field is safe to log or ship to a monitoring pipeline: it carries
/// classification and the native library's own source/reason strings, never
/// MLS payloads, ratchets, keys, or external-sender bytes.
public struct DaveFailureReport: Codable, Sendable, Equatable {
    public let code: DaveFailureCode
    public let origin: DaveFailureOrigin
    /// The native MLS failure source, preserved verbatim and separately from
    /// the reason so it can be aggregated.
    public let nativeSource: String?
    /// The native MLS failure reason, preserved verbatim.
    public let nativeReason: String?
    /// Human-readable summary. Use ``code`` for logic, this for humans.
    public let message: String
    /// Generation of the session that failed, so a host can discard a report
    /// that belongs to a session it has already replaced.
    public let sessionGeneration: UInt64
    public let timestamp: Date

    public init(
        code: DaveFailureCode,
        origin: DaveFailureOrigin,
        nativeSource: String? = nil,
        nativeReason: String? = nil,
        message: String,
        sessionGeneration: UInt64,
        timestamp: Date = Date()
    ) {
        self.code = code
        self.origin = origin
        self.nativeSource = nativeSource
        self.nativeReason = nativeReason
        self.message = message
        self.sessionGeneration = sessionGeneration
        self.timestamp = timestamp
    }
}

/// One observable state-machine event.
///
/// The same value is appended to the bounded trace in ``DaveDiagnostics`` and
/// delivered to live subscribers of
/// ``DaveSessionCoordinator/diagnosticEvents(bufferSize:)``, so an after-the-fact
/// trace and a live stream cannot disagree.
///
/// > Important: Events never carry MLS payload bytes, ratchets, key material,
/// > or raw external-sender data. Payloads are represented only by their byte
/// > count, which is enough to correlate an event with a gateway log.
public struct DaveDiagnosticEvent: Codable, Sendable, Equatable, Identifiable {
    /// Monotonic sequence number within this coordinator, so a host can order
    /// events and detect a gap without relying on timestamp resolution.
    public let id: UInt64
    public let timestamp: Date
    /// Generation of the session this event belongs to. Events from a
    /// superseded generation can be discarded after a reset or recovery.
    public let sessionGeneration: UInt64
    public let kind: DaveDiagnosticEventKind
    public let outcome: DaveDiagnosticEventOutcome
    /// Discord transition ID, where the event relates to one.
    public let transitionId: UInt64?
    /// Media readiness *after* this event.
    public let mediaReady: Bool
    public let recoveryHint: DaveRecoveryHint
    /// Size of the associated gateway payload. The bytes themselves are never
    /// retained.
    public let payloadByteCount: Int?
    /// Outbound actions this event produced.
    public let emittedOutboundActionIds: [UUID]
    /// Outbound actions still awaiting acknowledgement after this event.
    public let pendingOutboundActionIds: [UUID]
    /// The action acknowledged by this event, if it was an acknowledgement.
    public let acknowledgedOutboundActionId: UUID?
    /// Short non-secret context, such as which gateway event kind arrived.
    public let detail: String?
    /// Structured failure, when this event represents one.
    public let failure: DaveFailureReport?

    public init(
        id: UInt64,
        timestamp: Date = Date(),
        sessionGeneration: UInt64,
        kind: DaveDiagnosticEventKind,
        outcome: DaveDiagnosticEventOutcome,
        transitionId: UInt64? = nil,
        mediaReady: Bool,
        recoveryHint: DaveRecoveryHint = .none,
        payloadByteCount: Int? = nil,
        emittedOutboundActionIds: [UUID] = [],
        pendingOutboundActionIds: [UUID] = [],
        acknowledgedOutboundActionId: UUID? = nil,
        detail: String? = nil,
        failure: DaveFailureReport? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sessionGeneration = sessionGeneration
        self.kind = kind
        self.outcome = outcome
        self.transitionId = transitionId
        self.mediaReady = mediaReady
        self.recoveryHint = recoveryHint
        self.payloadByteCount = payloadByteCount
        self.emittedOutboundActionIds = emittedOutboundActionIds
        self.pendingOutboundActionIds = pendingOutboundActionIds
        self.acknowledgedOutboundActionId = acknowledgedOutboundActionId
        self.detail = detail
        self.failure = failure
    }
}

/// Media-readiness watchdog state, in a form suitable for export.
///
/// ``DaveMediaReadinessWatchdogStatus`` remains the API for evaluating the
/// watchdog; this is its serializable snapshot, with the extra context a host
/// needs to explain why media is paused.
public struct DaveWatchdogDiagnostics: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case inactive
        case pending
        case timedOut
    }

    public let state: State
    /// Why the watchdog is running, or why it expired.
    public let reason: String?
    /// When the current wait began.
    public let startedAt: Date?
    /// Configured allowance for this wait, in seconds.
    public let timeout: TimeInterval?
    /// Seconds left before expiry, measured on a monotonic clock.
    public let secondsRemaining: TimeInterval?
    /// Recovery guidance, set when the watchdog has expired.
    public let recoveryHint: DaveRecoveryHint?

    public init(
        state: State,
        reason: String? = nil,
        startedAt: Date? = nil,
        timeout: TimeInterval? = nil,
        secondsRemaining: TimeInterval? = nil,
        recoveryHint: DaveRecoveryHint? = nil
    ) {
        self.state = state
        self.reason = reason
        self.startedAt = startedAt
        self.timeout = timeout
        self.secondsRemaining = secondsRemaining
        self.recoveryHint = recoveryHint
    }

    public static let inactive = DaveWatchdogDiagnostics(state: .inactive)
}


/// Thread-safe fan-out of diagnostic events to live subscribers.
///
/// Subscriber bookkeeping deliberately lives outside the coordinator actor.
/// Both teardown paths have to work when the actor is unavailable or already
/// going away: a cancelled consumer must remove itself without hopping onto an
/// actor that may be deallocating, and the coordinator's `deinit` must be able
/// to finish every stream. Without that, a consumer of a coordinator that has
/// been released stays suspended forever — one leaked task per voice session in
/// a client that builds a coordinator per connection.
internal final class DaveDiagnosticEventBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<DaveDiagnosticEvent>.Continuation] = [:]

    init() {}

    func add(_ id: UUID, _ continuation: AsyncStream<DaveDiagnosticEvent>.Continuation) {
        lock.lock()
        continuations[id] = continuation
        lock.unlock()
    }

    func remove(_ id: UUID) {
        lock.lock()
        let continuation = continuations.removeValue(forKey: id)
        lock.unlock()
        // Finishing an already-terminated stream is a harmless no-op.
        continuation?.finish()
    }

    /// Delivers to every subscriber. The snapshot is taken under the lock and
    /// yielded outside it, so a subscriber's buffering policy can never run
    /// while the lock is held.
    func yield(_ event: DaveDiagnosticEvent) {
        lock.lock()
        let snapshot = continuations
        lock.unlock()
        for continuation in snapshot.values {
            continuation.yield(event)
        }
    }

    func finishAll() {
        lock.lock()
        let snapshot = continuations
        continuations.removeAll()
        lock.unlock()
        for continuation in snapshot.values {
            continuation.finish()
        }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return continuations.count
    }
}
