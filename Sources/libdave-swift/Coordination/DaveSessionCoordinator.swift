import Foundation
import CryptoKit
import CDave

/// High-level actor orchestrating the DAVE/MLS session, key ratchets, and media encryption.
public actor DaveSessionCoordinator {
    private enum TransitionKind: String {
        case externalSender
        case proposals
        case welcome
        case commit
        case execute
        case prepareEpoch
    }

    /// The next outbound ratchet is deliberately kept separate from the active
    /// encryptor. Discord requires senders to keep using the old media context
    /// until the matching Execute Transition arrives.
    private struct StagedTransition {
        let transitionId: UInt64
        let outboundRatchet: DaveKeyRatchet?
        let protocolVersion: UInt16
        let source: TransitionKind
        var executeSeen: Bool
    }

    private struct TransitionLedgerEntry {
        let kind: TransitionKind
        let transitionId: UInt64?
        let payloadDigest: Data?
        let actions: [DiscordDaveOutboundAction]
        let recoveryHint: DaveRecoveryHint
        var outboundActionIDs: [UUID]
    }

    private struct ProcessedMlsTransition {
        let kind: TransitionKind
        let didApply: Bool
        let outboundRatchet: DaveKeyRatchet?
    }

    /// Label of the dedicated queue, also used by the test that verifies actor
    /// work really is confined to it.
    internal static let executorQueueLabel = "com.libdave.session.coordinator"

    /// Dedicated serial executor backing this actor.
    ///
    /// The DAVE/MLS calls underneath are synchronous, blocking C++/OpenSSL
    /// operations. Running them on Swift's shared cooperative thread pool means
    /// a single slow or wedged native call can starve unrelated async work in
    /// the host process. By pinning the actor to its own serial queue, any such
    /// stall is contained to this one thread — the rest of the host keeps
    /// running — while still serializing access to the (non-thread-safe) native
    /// session state.
    private let executorQueue = DispatchSerialQueue(label: executorQueueLabel)

#if DAVE_DEFAULT_ACTOR_EXECUTOR
    // Built only for the thread-sanitizer CI job. TSan cannot see the
    // happens-before edge that Swift's custom-executor enqueue path
    // establishes, so every hop between two actor-isolated methods is
    // reported as a race even though the queue provably serializes them
    // (see `ExecutorSerializationTests`). Running the sanitizer against the
    // default actor executor keeps race detection meaningful for the actual
    // state-machine logic instead of drowning it in false positives. Shipping
    // builds always use the dedicated queue below.
#else
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executorQueue.asUnownedSerialExecutor()
    }
#endif

    // Lifecycles owned by actor
    private var session: DaveSession?
    private var encryptor: DaveEncryptor?
    /// Ratchet installed on `encryptor` and currently used to encrypt outbound
    /// media. This is retained independently of `session`, whose MLS state may
    /// already have advanced to a staged future epoch.
    private var activeOutboundRatchet: DaveKeyRatchet?
    private var activeTransitionId: UInt64?
    /// One decryptor per remote user, created lazily on first decrypt and kept
    /// in step with the MLS roster after each applied welcome/commit.
    private var decryptors: [String: DaveDecryptor] = [:]
    /// Passthrough mode requested by the host; applied to the encryptor and to
    /// every current and future decryptor so both directions stay coherent.
    private var passthroughMode: Bool = false
    /// SSRCs already assigned to the Opus codec on the current encryptor, so
    /// the per-frame encrypt path skips the redundant native assignment call.
    private var assignedSsrcs: Set<UInt32> = []
    /// Monotonically increasing identity for the current encryptor. Native
    /// callbacks can arrive after an encryptor is torn down, so callbacks use
    /// this value to avoid mutating state for a replacement instance.
    private var encryptorGeneration: UInt64 = 0
    /// Monotonically increasing identity for the current MLS session. Native
    /// failure callbacks can arrive after recovery has replaced a session, so
    /// callback work carries this value before it touches coordinator state.
    private var sessionGeneration: UInt64 = 0

    /// Newer ratchets indexed by their Discord transition ID. They are only
    /// installed into the outbound encryptor at Execute Transition.
    private var stagedTransitions: [UInt64: StagedTransition] = [:]
    private var stagedTransitionOrder: [UInt64] = []
    /// A bounded replay ledger makes gateway resume/replay idempotent without
    /// handing the same MLS commit/welcome to native code twice.
    private var transitionLedger: [String: TransitionLedgerEntry] = [:]
    private var transitionLedgerOrder: [String] = []
    /// A bounded outbox lets the host retry the exact generated gateway bytes
    /// if a WebSocket write fails before it is acknowledged.
    private var pendingOutboundActions: [UUID: DiscordDaveOutboundAction] = [:]
    private var pendingOutboundActionOrder: [UUID] = []

    // Internal configurations
    private let authSessionId: String?
    private let limits: DaveCoordinatorLimits
    private var groupId: UInt64?
    private var selfUserId: String?
    
    // Internal state tracking
    private var protocolVersion: UInt16 = 0
    private var appliedTransitionCount: UInt64 = 0
    private var handshakeState: DaveHandshakeState = .uninitialized
    private var lastMlsError: String?
    private var lastTransitionTimestamp: Date?
    private var isExternalSenderRegistered: Bool = false
    private var externalSenderState: DaveExternalSenderState = .missing
    private var externalSenderData: Data?
    private var mediaReady: Bool = false
    private var pendingEpoch: UInt64?
    private var pendingTransitionId: UInt64?
    private var pendingProtocolVersion: UInt16?
    private var lastRecoveryAction: DaveRecoveryAction?
    private var hasIssuedInitialKeyPackage: Bool = false
    private var hasSentInitialKeyPackage: Bool = false
    /// Watchdog deadlines are tracked on a monotonic clock. Wall-clock time
    /// moves: an NTP correction or a sleep/wake cycle would otherwise either
    /// expire a healthy transition instantly or postpone a stalled one
    /// indefinitely, and this watchdog is a safety boundary for media.
    private var mediaReadinessWatchdogStartedAt: ContinuousClock.Instant?
    /// Wall-clock companion, used only by the `Date`-based evaluation overload
    /// that lets hosts and tests drive the watchdog from their own clock.
    private var mediaReadinessWatchdogStartedDate: Date?
    private var mediaReadinessWatchdogTimeout: TimeInterval
    private var mediaReadinessWatchdogReason: String?
    private var mediaReadinessWatchdogTask: Task<Void, Never>?
    /// Ledger and staged-transition entries dropped to stay inside the
    /// configured bounds. Surfaced through diagnostics so a host can see state
    /// aging out rather than guessing why an old replay was reprocessed.
    private var evictedTransitionCount: UInt64 = 0
    /// MLS roster after the most recently applied transition.
    private var rosterUserIds: [String] = []
    /// Per-member signature captured from the applying commit/welcome, for
    /// hosts that display or pin identity verification data.
    private var rosterMemberSignatures: [String: Data] = [:]
    /// Members the host most recently told us to expect. Populated from the
    /// `recognizedUserIds` supplied with a Welcome or with proposals.
    private var recognizedRosterUserIds: Set<String> = []
    /// Roster members absent from `recognizedRosterUserIds`.
    private var unrecognizedRosterUserIds: [String] = []
    /// Opcode 21 with transition ID zero is Discord's sole-member-reset
    /// signal. It immediately executes the new *pending* local group, which
    /// is intentionally not media-ready until native MLS later establishes a
    /// group through a real Commit or Welcome. Keep this fact separately from
    /// staged ratchets: there is no ratchet to stage yet, and leaving an empty
    /// staged transition behind would poison the next real transition ID.
    private var soleMemberResetExecuteSeen = false

    /// Creates a new coordinator.
    /// - Parameter authSessionId: Optional identifier for managing persistent key lifetimes.
    public init(authSessionId: String? = nil, limits: DaveCoordinatorLimits = .default) {
        self.authSessionId = authSessionId
        self.limits = limits
        self.mediaReadinessWatchdogTimeout = limits.mediaReadinessTimeout
    }

    /// Configures the coordinator specifically for Discord Voice usage.
    /// - Parameters:
    ///   - groupId: The target group identifier.
    ///   - selfUserId: The local client user ID.
    ///   - protocolVersion: The target protocol version (e.g. 1).
    public func configureForDiscordVoice(groupId: UInt64, selfUserId: String, protocolVersion: UInt16) throws {
        try validateDiscordGroupId(groupId)
        try validateDiscordUserId(selfUserId)
        try validateProtocolVersion(protocolVersion)
        self.groupId = groupId
        self.selfUserId = selfUserId
        self.protocolVersion = protocolVersion

        try recreateSessionState()
    }

    /// Configures a Discord Voice DAVE session and returns the first high-level
    /// state snapshot for callers that want to drive the gateway with emitted
    /// actions instead of assembling each step manually.
    @discardableResult
    public func configureDiscordVoiceSession(
        groupId: UInt64,
        selfUserId: String,
        protocolVersion: UInt16
    ) throws -> DiscordDaveTransitionResult {
        try configureForDiscordVoice(
            groupId: groupId,
            selfUserId: selfUserId,
            protocolVersion: protocolVersion
        )
        return makeDiscordResult(recoveryHint: .waitForExternalSender)
    }

    /// Resets the MLS session state using the native library's reset capabilities.
    public func reset() {
        // Invalidate callbacks from this session before reset/destroy can cause
        // them to run. A recovery must never be poisoned by an old failure.
        sessionGeneration &+= 1
        session?.reset()

        // All cryptors hold ratchets from the old session generation. Drop
        // both directions so media fails closed until the next MLS transition
        // installs fresh ratchets.
        encryptorGeneration &+= 1
        encryptor = nil
        activeOutboundRatchet = nil
        activeTransitionId = nil
        decryptors.removeAll()
        assignedSsrcs.removeAll()
        stagedTransitions.removeAll()
        stagedTransitionOrder.removeAll()
        transitionLedger.removeAll()
        transitionLedgerOrder.removeAll()
        pendingOutboundActions.removeAll()
        pendingOutboundActionOrder.removeAll()

        // Clear tracking state
        appliedTransitionCount = 0
        handshakeState = .uninitialized
        lastMlsError = nil
        lastTransitionTimestamp = Date()
        isExternalSenderRegistered = false
        externalSenderState = .missing
        externalSenderData = nil
        mediaReady = false
        pendingEpoch = nil
        pendingTransitionId = nil
        pendingProtocolVersion = nil
        lastRecoveryAction = .reset
        hasIssuedInitialKeyPackage = false
        hasSentInitialKeyPackage = false
        soleMemberResetExecuteSeen = false
        rosterUserIds.removeAll()
        rosterMemberSignatures.removeAll()
        recognizedRosterUserIds.removeAll()
        unrecognizedRosterUserIds.removeAll()
        clearMediaReadinessWatchdog()
    }

    /// Recreates the MLS session state and reinitializes with current settings.
    public func recreateSessionState() throws {
        reset()

        if let groupId = groupId, let selfUserId = selfUserId {
            try initializeSession(groupId: groupId, selfUserId: selfUserId)
        }
        lastRecoveryAction = .recreateSession
    }

    /// Rebuilds only the encryptor, preserving session state but invalidating existing ratchets.
    public func rebuildEncryptor() throws {
        encryptorGeneration &+= 1
        let generation = encryptorGeneration
        // Tear down the old native state before a throwing allocation so a
        // failed rebuild cannot leave an encryptor using a prior ratchet.
        encryptor = nil
        assignedSsrcs.removeAll()
        let replacementEncryptor = try DaveEncryptor()
        encryptor = replacementEncryptor
        // The fresh native encryptor has no SSRC->codec assignments and
        // defaults to passthrough off, so re-align both with tracked state.
        encryptor?.setPassthroughMode(passthroughMode)
        lastRecoveryAction = .rebuildEncryptor

        // Wire version changes to the actor safely
        replacementEncryptor.setProtocolVersionChangedCallback { [weak self] in
            guard let self = self else { return }
            Task {
                await self.handleProtocolVersionChanged(from: generation)
            }
        }

        // Reapply only the active ratchet. The native MLS session may already
        // be ahead of outbound media while a future ratchet waits for Execute.
        if let activeOutboundRatchet {
            encryptor?.setKeyRatchet(activeOutboundRatchet)
        }

        lastTransitionTimestamp = Date()
    }

    /// Processes an MLS transition for Discord Voice (e.g., Welcome or Commit).
    ///
    /// This legacy, low-level entry point has no Discord transition ID, so it
    /// cannot defer outbound activation until Execute. Prefer
    /// ``processDiscordWelcomeForOutbound(_:transitionId:recognizedUserIds:recoveryTimeout:)``,
    /// ``processDiscordCommitForOutbound(_:transitionId:recoveryTimeout:)``, or
    /// ``consumeDiscordGatewayEvent(_:)`` for production voice clients.
    /// - Parameter transition: The welcome or commit transition data.
    @available(
        *,
        deprecated,
        message: "This legacy API has no Discord transition ID. Use consumeDiscordGatewayEvent(_:) or the transition-ID-aware Welcome/Commit helpers."
    )
    public func processDiscordTransition(_ transition: DiscordTransition) throws {
        do {
            let processed = try processMlsTransition(transition)
            guard processed.didApply, let ratchet = processed.outboundRatchet else { return }
            activateOutboundRatchet(ratchet, transitionId: nil, reason: "legacy \(processed.kind.rawValue) processing")
            // The old API cannot associate the update with Execute. Fail closed
            // after activation rather than falsely claiming media is ready.
            beginMediaReadinessWait(reason: "Legacy \(processed.kind.rawValue) applied; transition ID was not supplied")
        } catch {
            failClosed(reason: "MLS transition failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Registers Discord's MLS external sender and optionally emits the initial
    /// key package action exactly once for this session generation.
    @discardableResult
    public func registerDiscordExternalSender(
        _ externalSender: Data,
        publishInitialKeyPackage: Bool = true
    ) throws -> DiscordDaveTransitionResult {
        try setExternalSender(externalSender)

        var actions: [DiscordDaveOutboundAction] = []
        if publishInitialKeyPackage,
           let keyPackageAction = try makeInitialKeyPackageActionIfNeeded(requireExternalSender: true) {
            actions.append(keyPackageAction)
        }

        return makeDiscordResult(actions: actions)
    }

    /// Emits the initial key package action exactly once for this session
    /// generation. An external sender is always required: Discord rejects MLS
    /// group creation without it, so a timer-based fallback is not safe.
    @discardableResult
    public func publishDiscordInitialKeyPackage() throws -> DiscordDaveTransitionResult {
        var actions: [DiscordDaveOutboundAction] = []
        guard externalSenderState == .registered else {
            throw DaveError.externalSenderRequired
        }
        if let keyPackageAction = try makeInitialKeyPackageActionIfNeeded(requireExternalSender: true) {
            actions.append(keyPackageAction)
        }
        return makeDiscordResult(actions: actions)
    }

    /// Marks the current generation's initial key package as already published
    /// for callers that still send `getMarshalledKeyPackage()` manually.
    public func markInitialKeyPackageSent() {
        hasIssuedInitialKeyPackage = true
        hasSentInitialKeyPackage = true
        lastRecoveryAction = .sendInitialKeyPackage
        lastTransitionTimestamp = Date()
    }

    /// Processes Discord MLS proposals and returns the commit/welcome payload
    /// action to send back through the voice gateway.
    @discardableResult
    public func processDiscordProposalsForOutbound(
        _ proposals: Data,
        recognizedUserIds: [String]
    ) throws -> DiscordDaveTransitionResult {
        let commitWelcome = try processProposals(proposals, recognizedUserIds: recognizedUserIds)
        return makeDiscordResult(actions: [.mlsCommitWelcome(commitWelcome)])
    }

    /// Processes a Discord Welcome transition and returns either transition-ready
    /// or a complete invalid-transition recovery action set.
    @discardableResult
    public func processDiscordWelcomeForOutbound(
        _ welcome: Data,
        transitionId: UInt64,
        recognizedUserIds: [String],
        recoveryTimeout: TimeInterval? = nil
    ) throws -> DiscordDaveTransitionResult {
        if let cached = cachedTransitionResult(
            kind: .welcome,
            transitionId: transitionId,
            payload: welcome
        ) {
            return cached
        }
        do {
            try validateMlsTransitionIdentity(
                kind: .welcome,
                transitionId: transitionId,
                payload: welcome
            )
            try ensureTransitionLedgerCapacity(
                for: ledgerKey(kind: .welcome, transitionId: transitionId, payload: welcome)
            )
            let processed = try processMlsTransition(.welcome(welcome, recognizedUserIds: recognizedUserIds))
            if processed.didApply, let ratchet = processed.outboundRatchet {
                let executeAlreadySeen = try stageOutboundTransition(
                    id: transitionId,
                    ratchet: ratchet,
                    source: .welcome,
                    protocolVersion: pendingProtocolVersion ?? protocolVersion
                )
                // Initialization transitions use ID zero. Discord does not
                // send Transition Ready/Execute around their Commit/Welcome;
                // native MLS has already supplied the ratchet, so activate it
                // immediately. Later nonzero transitions remain Execute-gated.
                if transitionId == 0 {
                    activateStagedTransition(transitionId, reason: "initialization welcome")
                } else if executeAlreadySeen {
                    activateStagedTransition(transitionId, reason: "Execute arrived before welcome")
                } else if activeOutboundRatchet == nil {
                    beginMediaReadinessWait(
                        reason: "Welcome applied; waiting for Execute Transition \(transitionId)",
                        timeout: recoveryTimeout
                    )
                }
            }
            // Transition ID zero is the sole-member-reset initialization
            // signal. It executes immediately and must not emit Opcode 23.
            let actions: [DiscordDaveOutboundAction] = transitionId == 0 ? [] : [.transitionReady(transitionId)]
            let result = makeDiscordResult(actions: actions)
            storeTransitionResult(
                kind: .welcome,
                transitionId: transitionId,
                payload: welcome,
                actions: result.outboundActions,
                recoveryHint: result.recoveryHint
            )
            return result
        } catch let error as DaveError where error.recoveryHint == .sendInvalidCommitWelcome {
            return try recoverDiscordInvalidTransition(transitionId: transitionId, timeout: recoveryTimeout)
        } catch {
            failClosed(reason: "Welcome \(transitionId) failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Processes a Discord Commit transition and returns either transition-ready
    /// or a complete invalid-transition recovery action set.
    @discardableResult
    public func processDiscordCommitForOutbound(
        _ commit: Data,
        transitionId: UInt64,
        recoveryTimeout: TimeInterval? = nil
    ) throws -> DiscordDaveTransitionResult {
        if let cached = cachedTransitionResult(
            kind: .commit,
            transitionId: transitionId,
            payload: commit
        ) {
            return cached
        }
        do {
            try validateMlsTransitionIdentity(
                kind: .commit,
                transitionId: transitionId,
                payload: commit
            )
            try ensureTransitionLedgerCapacity(
                for: ledgerKey(kind: .commit, transitionId: transitionId, payload: commit)
            )
            let processed = try processMlsTransition(.commit(commit))
            if processed.didApply, let ratchet = processed.outboundRatchet {
                let executeAlreadySeen = try stageOutboundTransition(
                    id: transitionId,
                    ratchet: ratchet,
                    source: .commit,
                    protocolVersion: pendingProtocolVersion ?? protocolVersion
                )
                // See the Welcome path: a Commit carrying initialization ID
                // zero establishes its returned ratchet immediately; ordinary
                // transitions stay staged until their matching Execute.
                if transitionId == 0 {
                    activateStagedTransition(transitionId, reason: "initialization commit")
                } else if executeAlreadySeen {
                    activateStagedTransition(transitionId, reason: "Execute arrived before commit")
                } else if activeOutboundRatchet == nil {
                    beginMediaReadinessWait(
                        reason: "Commit applied; waiting for Execute Transition \(transitionId)",
                        timeout: recoveryTimeout
                    )
                }
            }
            // See the corresponding Welcome path: initialization transition
            // zero is immediately executable and has no ready acknowledgement.
            let actions: [DiscordDaveOutboundAction] = transitionId == 0 ? [] : [.transitionReady(transitionId)]
            let result = makeDiscordResult(actions: actions)
            storeTransitionResult(
                kind: .commit,
                transitionId: transitionId,
                payload: commit,
                actions: result.outboundActions,
                recoveryHint: result.recoveryHint
            )
            return result
        } catch let error as DaveError where error.recoveryHint == .sendInvalidCommitWelcome {
            return try recoverDiscordInvalidTransition(transitionId: transitionId, timeout: recoveryTimeout)
        } catch {
            failClosed(reason: "Commit \(transitionId) failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Handles Discord's execute-transition signal. Media is marked ready only
    /// once MLS processing has installed a ratchet and the coordinator is ready.
    @discardableResult
    public func executeDiscordTransition(_ transitionId: UInt64) -> DiscordDaveTransitionResult {
        guard handshakeState != .failed else {
            return makeDiscordResult(recoveryHint: .recreateSession)
        }
        if let cached = cachedTransitionResult(kind: .execute, transitionId: transitionId, payload: nil) {
            return cached
        }

        // Discord's sole-member reset is sent as Opcode 24 (epoch 1), followed
        // by Opcode 21 with transition ID zero. Unlike normal transitions, it
        // is executed immediately and has no following Opcode 22. Native
        // libdave represents the fresh local group as pending, so it cannot
        // produce a ratchet yet; preserve the executed state and remain
        // fail-closed until a real Commit/Welcome establishes one.
        if transitionId == 0, (pendingEpoch == 1 || soleMemberResetExecuteSeen) {
            return executeDiscordSoleMemberReset()
        }

        // A repeated Execute for the currently active context is a benign
        // gateway replay. Do not create a placeholder that could later be
        // mistaken for a fresh MLS transition after the ledger is pruned.
        if activeTransitionId == transitionId {
            let result = makeDiscordResult()
            storeTransitionResult(
                kind: .execute,
                transitionId: transitionId,
                payload: nil,
                actions: result.outboundActions,
                recoveryHint: result.recoveryHint
            )
            return result
        }

        if stagedTransitions[transitionId] != nil {
            activateStagedTransition(transitionId, reason: "execute transition \(transitionId)")
            let result = makeDiscordResult()
            storeTransitionResult(
                kind: .execute,
                transitionId: transitionId,
                payload: nil,
                actions: result.outboundActions,
                recoveryHint: result.recoveryHint
            )
            return result
        }

        // Gateway v8 may deliver a buffered Execute before the corresponding
        // binary commit/welcome. Retain the signal; staging the matching MLS
        // transition later activates it immediately.
        stageExecuteBeforeMls(transitionId)
        if activeOutboundRatchet == nil {
            beginMediaReadinessWait(reason: "Execute Transition \(transitionId) arrived before MLS was ready")
        }
        let result = makeDiscordResult(recoveryHint: .retryLater)
        storeTransitionResult(
            kind: .execute,
            transitionId: transitionId,
            payload: nil,
            actions: result.outboundActions,
            recoveryHint: result.recoveryHint
        )
        return result
    }

    /// Executes Discord's special sole-member-reset initialization transition.
    ///
    /// Discord sends this as Opcode 21 with transition ID `0` immediately after
    /// an epoch-1 reset. The native session deliberately keeps the fresh local
    /// group pending until a later Commit or Welcome establishes it, so there
    /// is no ratchet to activate here. This method records the authorization,
    /// clears the ordinary ten-second transition watchdog, and keeps media
    /// fail-closed rather than mistaking a pending local group for one that can
    /// encrypt media.
    private func executeDiscordSoleMemberReset() -> DiscordDaveTransitionResult {
        if let cached = cachedTransitionResult(kind: .execute, transitionId: 0, payload: nil) {
            return cached
        }

        guard pendingEpoch == 1 || soleMemberResetExecuteSeen else {
            // The sentinel is only valid for initialization. Treat an isolated
            // ID-zero Execute exactly like other out-of-order gateway events.
            stageExecuteBeforeMls(0)
            if activeOutboundRatchet == nil {
                beginMediaReadinessWait(reason: "Execute Transition 0 arrived before MLS was ready")
            }
            let result = makeDiscordResult(recoveryHint: .retryLater)
            storeTransitionResult(
                kind: .execute,
                transitionId: 0,
                payload: nil,
                actions: result.outboundActions,
                recoveryHint: result.recoveryHint
            )
            return result
        }

        soleMemberResetExecuteSeen = true
        mediaReady = false
        // The Epoch-1 Prepare transition is now semantically executed. It is
        // not an MLS readiness deadline: a solo client can legitimately remain
        // pending until another member joins and produces the first commit.
        pendingEpoch = nil
        pendingTransitionId = nil
        pendingProtocolVersion = nil
        clearMediaReadinessWatchdog()
        // Keep this patch release source-compatible: the existing pause-media
        // diagnostic already describes the only safe outcome here.
        lastRecoveryAction = .pauseMedia
        lastTransitionTimestamp = Date()

        let result = makeDiscordResult()
        storeTransitionResult(
            kind: .execute,
            transitionId: 0,
            payload: nil,
            actions: result.outboundActions,
            recoveryHint: result.recoveryHint
        )
        return result
    }

    /// Prepares a Discord DAVE epoch. Epoch `1` creates/recreates an MLS group
    /// and therefore needs a new key package. Later epochs retain the active
    /// outbound ratchet until the subsequent matching Execute Transition.
    @discardableResult
    public func prepareDiscordEpoch(
        protocolVersion: UInt16,
        epoch: UInt64,
        transitionId: UInt64,
        timeout: TimeInterval? = nil
    ) throws -> DiscordDaveTransitionResult {
        guard groupId != nil, selfUserId != nil else {
            throw DaveError.notConfigured
        }
        try ensureAcceptingGatewayEvents()
        guard epoch > 0 else {
            throw DaveError.invalidTransition(message: "Prepare Epoch must be greater than zero")
        }
        try validateProtocolVersion(protocolVersion)

        if epoch > 1 {
            do {
                // A retained-group protocol change must not tear down working
                // media. Prepare new receive and send contexts, but keep the
                // current outbound ratchet active until the *matching* Execute
                // Transition authorizes it.
                guard let session, let selfUserId else {
                    throw DaveError.notConfigured
                }
                session.setProtocolVersion(version: protocolVersion)
                pendingProtocolVersion = protocolVersion
                pendingEpoch = epoch

                try prepareExistingDecryptorsForCurrentSession()
                guard let ratchet = session.getKeyRatchet(userId: selfUserId) else {
                    throw DaveError.ratchetFailed(
                        userId: selfUserId,
                        reason: "Could not prepare key ratchet for protocol transition"
                    )
                }
                let executeAlreadySeen = try stageOutboundTransition(
                    id: transitionId,
                    ratchet: ratchet,
                    source: .prepareEpoch,
                    protocolVersion: protocolVersion
                )
                if executeAlreadySeen {
                    activateStagedTransition(
                        transitionId,
                        reason: "Execute arrived before Prepare Epoch"
                    )
                } else if activeOutboundRatchet == nil {
                    beginMediaReadinessWait(
                        reason: "Prepare Epoch \(epoch); waiting for Execute Transition \(transitionId)",
                        timeout: timeout
                    )
                }
                lastRecoveryAction = .prepareProtocolVersion
                lastTransitionTimestamp = Date()
                return makeDiscordResult(actions: [.transitionReady(transitionId)])
            } catch {
                failClosed(reason: "Prepare Epoch \(epoch) failed: \(error.localizedDescription)")
                throw error
            }
        }

        let cachedExternalSender = externalSenderData
        // A resumed gateway can deliver Execute before its corresponding
        // Prepare Epoch. Recreating an epoch-1 group clears old MLS state, but
        // must not discard that authorization signal; the later Welcome/Commit
        // will consume this placeholder and activate immediately.
        let executeAlreadySeen = stagedTransitions[transitionId]?.executeSeen ?? false
        self.protocolVersion = protocolVersion
        try recreateSessionState()
        if executeAlreadySeen {
            stageExecuteBeforeMls(transitionId)
        }

        var actions: [DiscordDaveOutboundAction] = []
        if let cachedExternalSender {
            try setExternalSender(cachedExternalSender)
            try appendInitialKeyPackageActionIfAvailable(to: &actions, requireExternalSender: true)
        }

        _ = markDiscordMediaNotReady(
            reason: "prepare epoch \(epoch)",
            pendingTransitionId: transitionId,
            pendingEpoch: epoch,
            timeout: timeout
        )

        return makeDiscordResult(
            actions: actions,
            recoveryHint: cachedExternalSender == nil ? .waitForExternalSender : .none
        )
    }

    /// Recovers from an invalid commit/welcome by recreating local MLS state,
    /// preserving a cached external sender, and emitting the Discord recovery
    /// actions in send order.
    @discardableResult
    public func recoverDiscordInvalidTransition(
        transitionId: UInt64,
        timeout: TimeInterval? = nil
    ) throws -> DiscordDaveTransitionResult {
        let cachedExternalSender = externalSenderData
        try recreateSessionState()

        var actions: [DiscordDaveOutboundAction] = [.invalidCommitWelcome(transitionId)]
        if let cachedExternalSender {
            try setExternalSender(cachedExternalSender)
            try appendInitialKeyPackageActionIfAvailable(to: &actions, requireExternalSender: true)
        }

        _ = markDiscordMediaNotReady(
            reason: "invalid transition \(transitionId) recovery",
            pendingTransitionId: transitionId,
            timeout: timeout
        )
        lastRecoveryAction = .invalidTransitionRecovery

        return makeDiscordResult(
            actions: actions,
            recoveryHint: cachedExternalSender == nil ? .waitForExternalSender : .recreateSession
        )
    }

    /// Marks DAVE media as unavailable while a new Discord MLS transition is in
    /// flight and starts the coordinator-owned readiness watchdog.
    @discardableResult
    public func markDiscordMediaNotReady(
        reason: String,
        pendingTransitionId: UInt64? = nil,
        pendingEpoch: UInt64? = nil,
        timeout: TimeInterval? = nil
    ) -> DaveMediaReadinessWatchdogStatus {
        guard handshakeState != .failed else {
            return .timedOut(reason: "DAVE session failed closed", recoveryHint: .recreateSession)
        }
        mediaReady = false
        // A generic pause must not retain an unrelated old ID: otherwise a
        // later valid Execute can be rejected forever as a false mismatch.
        self.pendingTransitionId = pendingTransitionId
        self.pendingEpoch = pendingEpoch
        mediaReadinessWatchdogStartedAt = .now
        mediaReadinessWatchdogStartedDate = Date()
        mediaReadinessWatchdogTimeout = max(0, timeout ?? limits.mediaReadinessTimeout)
        mediaReadinessWatchdogReason = reason
        lastRecoveryAction = .pauseMedia
        lastTransitionTimestamp = Date()
        scheduleMediaReadinessWatchdog()
        return evaluateMediaReadinessWatchdog()
    }

    /// Marks DAVE media as ready and clears any pending readiness watchdog.
    @discardableResult
    @available(
        *,
        deprecated,
        message: "Use executeDiscordTransition(_:) or consumeDiscordGatewayEvent(_:) so readiness is bound to Discord's matching transition ID."
    )
    public func markDiscordMediaReady(reason: String? = nil) -> DaveMediaReadinessWatchdogStatus {
        guard handshakeState != .failed else {
            return .timedOut(reason: "DAVE session failed closed", recoveryHint: .recreateSession)
        }
        // This remains for advanced/manual integrations and passthrough tests,
        // but it must not override a known staged transition. Production voice
        // clients should call `executeDiscordTransition` instead.
        guard pendingTransitionId == nil, stagedTransitions.isEmpty else {
            return evaluateMediaReadinessWatchdog()
        }
        mediaReady = true
        pendingEpoch = nil
        pendingTransitionId = nil
        lastRecoveryAction = .resumeMedia
        lastTransitionTimestamp = Date()
        clearMediaReadinessWatchdog()
        return .inactive
    }

    /// Evaluates whether an in-flight DAVE media refresh has exceeded its
    /// allowed readiness window.
    ///
    /// - Parameter now: Optional wall-clock instant to evaluate against, for
    ///   hosts and tests that drive the watchdog from their own clock. When
    ///   omitted, a monotonic clock is used, so the deadline survives system
    ///   clock adjustments and sleep/wake.
    public func evaluateMediaReadinessWatchdog(now: Date? = nil) -> DaveMediaReadinessWatchdogStatus {
        guard !mediaReady, let startedAt = mediaReadinessWatchdogStartedAt else {
            return .inactive
        }

        let elapsed: TimeInterval
        if let now, let startedDate = mediaReadinessWatchdogStartedDate {
            elapsed = now.timeIntervalSince(startedDate)
        } else {
            elapsed = Self.seconds(ContinuousClock.now - startedAt)
        }

        let remaining = mediaReadinessWatchdogTimeout - elapsed
        guard remaining <= 0 else {
            return .pending(secondsRemaining: remaining)
        }

        return .timedOut(
            reason: mediaReadinessWatchdogReason ?? "DAVE media readiness",
            recoveryHint: .recreateSession
        )
    }

    /// Encrypts an audio frame specifically for Discord Voice.
    /// - Parameters:
    ///   - frame: Raw audio plaintext bytes.
    ///   - ssrc: Synchronization Source (SSRC) identifier.
    /// - Returns: Encrypted ciphertext frame bytes.
    public func encryptDiscordAudioFrame(_ frame: Data, ssrc: UInt32) throws -> Data {
        guard frame.count <= limits.maximumMediaFrameBytes else {
            throw DaveError.invalidMediaFrameSize(actual: frame.count, maximum: limits.maximumMediaFrameBytes)
        }
        guard mediaReady else {
            throw DaveError.mediaNotReady
        }
        guard let encryptor = encryptor else {
            throw DaveError.invalidState(message: "Encryptor is not initialized or ratchet is not set.")
        }

        // Zero-configuration: automatically map new SSRCs to the Opus codec.
        // Assign once per SSRC; this runs per 20ms audio frame, so the native
        // call is skipped for SSRCs already assigned on this encryptor.
        if assignedSsrcs.insert(ssrc).inserted {
            encryptor.assignSsrcToCodec(ssrc: ssrc, codec: .opus)
        }

        return try encryptor.encrypt(mediaType: .audio, ssrc: ssrc, frame: frame)
    }

    /// Decrypts an audio frame received from a remote Discord user.
    ///
    /// Decryptors are created lazily per remote user and are kept in step with
    /// the MLS roster: after each applied welcome/commit they transition to the
    /// user's ratchet for the new epoch, and users who left the roster have
    /// their decryptors dropped.
    ///
    /// If the user's ratchet is not yet available (e.g. the frame raced an MLS
    /// transition), the native decrypt fails and this throws
    /// `DaveError.decryptionFailed(reason: .missingKeyRatchet)`, whose
    /// `recoveryHint` is `.retryLater`.
    /// - Parameters:
    ///   - encryptedFrame: The encrypted frame bytes from the RTP payload.
    ///   - userId: Discord user ID of the sender.
    /// - Returns: Decrypted plaintext frame bytes.
    public func decryptDiscordAudioFrame(_ encryptedFrame: Data, from userId: String) throws -> Data {
        guard encryptedFrame.count <= limits.maximumMediaFrameBytes else {
            throw DaveError.invalidMediaFrameSize(actual: encryptedFrame.count, maximum: limits.maximumMediaFrameBytes)
        }
        guard session != nil else {
            throw DaveError.notConfigured
        }
        guard mediaReady else {
            throw DaveError.mediaNotReady
        }
        try validateDiscordUserId(userId)
        let decryptor = try decryptorForUser(userId)
        return try decryptor.decrypt(mediaType: .audio, encryptedFrame: encryptedFrame)
    }

    /// MLS roster after the most recently applied transition, as decimal
    /// Discord Snowflakes. Empty until a Welcome or Commit has been applied.
    public func currentRoster() -> [String] {
        rosterUserIds
    }

    /// Roster members the host never listed as recognized.
    ///
    /// A non-empty result means the MLS group contains an identity the voice
    /// session did not announce. Treat it as a verification failure worth
    /// surfacing to the user, regardless of the configured policy.
    public func unrecognizedRosterMembers() -> [String] {
        unrecognizedRosterUserIds
    }

    /// Signature of a roster member captured from the transition that admitted
    /// them, for hosts that display or pin identity verification data.
    public func rosterMemberSignature(for userId: String) -> Data? {
        rosterMemberSignatures[userId]
    }

    /// Authenticator for the last MLS epoch.
    ///
    /// Discord clients compare this value out of band to confirm that every
    /// participant reached the same group state. It changes on every epoch.
    public func epochAuthenticator() throws -> Data? {
        guard let session else {
            throw DaveError.notConfigured
        }
        return session.lastEpochAuthenticator
    }

    /// Gets decryption statistics for a remote user's audio decryptor, if one exists.
    public func decryptorStats(for userId: String) -> DaveDecryptorStats? {
        decryptors[userId]?.stats(mediaType: .audio)
    }

    /// Computes a pairwise fingerprint for identity verification with another user.
    ///
    /// Returns `nil` when the native library produced no fingerprint (e.g. the
    /// remote user is not in the current MLS group).
    /// - Parameters:
    ///   - version: Fingerprint format version to use.
    ///   - userId: Discord user ID of the remote user.
    /// - Parameter timeout: How long to wait for the native callback before
    ///   returning `nil`. The bundled implementation calls back synchronously,
    ///   so this never fires in practice; it exists so a wedged or changed
    ///   native implementation cannot suspend the caller forever.
    public func pairwiseFingerprint(
        version: UInt16,
        userId: String,
        timeout: Duration = .seconds(5)
    ) async throws -> Data? {
        guard let session else {
            throw DaveError.notConfigured
        }
        try validateDiscordUserId(userId)

        // The request is issued synchronously, so the non-`Sendable` session
        // never crosses an isolation boundary. Only the single-shot bridge and
        // resume box — both safe to share — are touched by the timeout task.
        let resume = DaveSingleShotResume<Data?>()
        let bridge = session.requestPairwiseFingerprint(version: version, userId: userId) { fingerprint in
            resume.deliver(fingerprint)
        }

        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            bridge.deliver(nil)
        }
        defer { timeoutTask.cancel() }

        return await withCheckedContinuation { continuation in
            resume.attach(continuation)
        }
    }

    /// Submits external-sender credentials to the native session.
    ///
    /// The bundled C API returns no parse status. Synchronously reported native
    /// failures are detected before any key package can be issued; a late
    /// native failure still fails the coordinator closed through its callback.
    public func setExternalSender(_ externalSender: Data) throws {
        try ensureAcceptingGatewayEvents()
        guard let session = session else {
            throw DaveError.notConfigured
        }
        guard !externalSender.isEmpty else {
            throw DaveError.invalidExternalSender
        }
        try validateMlsPayload(externalSender, kind: "external sender")

        if let current = externalSenderData {
            guard current == externalSender else {
                failClosed(reason: "Conflicting external sender payload")
                throw DaveError.externalSenderConflict
            }
            // Replayed external-sender events are already represented in the
            // coordinator's action ledger. Avoid passing duplicate bytes to
            // native MLS when callers use this low-level helper directly.
            return
        }
        session.setExternalSender(externalSender)
        if let failure = session.takeLastMLSFailure() {
            let reason = "\(failure.source): \(failure.reason)"
            failClosed(reason: "External sender rejected by native MLS: \(reason)")
            throw DaveError.externalSenderRejected(reason: reason)
        }
        isExternalSenderRegistered = true
        externalSenderState = .registered
        externalSenderData = externalSender
        lastRecoveryAction = .registerExternalSender
        lastTransitionTimestamp = Date()
    }

    /// Gets the marshalled MLS key package.
    public func getMarshalledKeyPackage() throws -> Data {
        try ensureAcceptingGatewayEvents()
        guard let session = session else {
            throw DaveError.notConfigured
        }
        guard let keyPackage = session.marshalledKeyPackage else {
            throw DaveError.invalidState(message: "Failed to generate marshalled key package")
        }
        try validateMlsPayload(keyPackage, kind: "key package")
        return keyPackage
    }

    /// Processes MLS proposals and generates commit/welcome messages.
    public func processProposals(_ proposals: Data, recognizedUserIds: [String]) throws -> Data {
        try ensureAcceptingGatewayEvents()
        guard let session = session else {
            throw DaveError.notConfigured
        }
        guard !proposals.isEmpty else {
            throw DaveError.invalidTransition(message: "Proposals payload was empty")
        }
        try validateMlsPayload(proposals, kind: "proposals")
        try validateDiscordUserIds(recognizedUserIds)
        // Discord supplies the expected participants here as well as with a
        // Welcome; keep the verification baseline current either way.
        recognizedRosterUserIds = Set(recognizedUserIds)
        guard let result = session.processProposals(proposals, recognizedUserIds: recognizedUserIds) else {
            throw DaveError.invalidState(message: "Proposals processing failed\(nativeFailureSuffix(session))")
        }
        try validateMlsPayload(result, kind: "commit/welcome")
        lastRecoveryAction = .processProposals
        lastTransitionTimestamp = Date()
        return result
    }

    /// Sets passthrough mode for outbound and inbound media alike: the
    /// encryptor, every existing per-user decryptor, and any decryptor created
    /// later all follow this setting.
    public func setPassthroughMode(_ enabled: Bool) throws {
        guard let encryptor = encryptor else {
            throw DaveError.invalidState(message: "Encryptor is not initialized.")
        }
        passthroughMode = enabled
        encryptor.setPassthroughMode(enabled)
        for decryptor in decryptors.values {
            decryptor.transitionToPassthroughMode(enabled)
        }
    }

    /// Retrieves a snapshot of the current session diagnostics.
    public func getDiagnostics() -> DaveDiagnostics {
        let stats = encryptor?.stats(mediaType: .audio)
        return DaveDiagnostics(
            sessionGeneration: sessionGeneration,
            protocolVersion: protocolVersion,
            appliedTransitionCount: appliedTransitionCount,
            handshakeState: handshakeState,
            encryptionStats: stats,
            lastMlsError: lastMlsError,
            lastTransitionTimestamp: lastTransitionTimestamp,
            isExternalSenderRegistered: isExternalSenderRegistered,
            mediaReady: mediaReady,
            pendingEpoch: pendingEpoch,
            pendingTransitionId: pendingTransitionId,
            activeTransitionId: activeTransitionId,
            pendingTransitionIds: stagedTransitionOrder,
            externalSenderState: externalSenderState,
            lastRecoveryAction: lastRecoveryAction,
            hasIssuedInitialKeyPackage: hasIssuedInitialKeyPackage,
            hasSentInitialKeyPackage: hasSentInitialKeyPackage,
            pendingOutboundActionCount: pendingOutboundActionOrder.count,
            rosterMemberCount: rosterUserIds.count,
            unrecognizedRosterMemberCount: unrecognizedRosterUserIds.count,
            evictedTransitionCount: evictedTransitionCount
        )
    }

    /// Consumes a DAVE/MLS gateway event through the coordinator-owned,
    /// replay-safe state machine. Use this API in new voice clients instead of
    /// independently calling the per-message helpers.
    ///
    /// Returned actions stay in the bounded outbox until each WebSocket write
    /// succeeds and the host calls ``acknowledgeDiscordGatewayAction(_:)``.
    @discardableResult
    public func consumeDiscordGatewayEvent(_ event: DiscordDaveGatewayEvent) throws -> DiscordDaveGatewayResult {
        let result: DiscordDaveTransitionResult
        let key: String

        switch event {
        case .externalSender(let sender):
            key = ledgerKey(kind: .externalSender, transitionId: nil, payload: sender)
            if let cached = cachedLedgerResult(for: key, kind: .externalSender, transitionId: nil, payload: sender) {
                return makeGatewayResult(for: key, fallback: cached)
            }
            try ensureTransitionLedgerCapacity(for: key)
            result = try registerDiscordExternalSender(sender)
            storeLedgerResult(
                key: key,
                kind: .externalSender,
                transitionId: nil,
                payload: sender,
                actions: result.outboundActions,
                recoveryHint: result.recoveryHint
            )

        case .proposals(let proposals, let recognizedUserIds):
            key = ledgerKey(kind: .proposals, transitionId: nil, payload: proposals)
            if let cached = cachedLedgerResult(for: key, kind: .proposals, transitionId: nil, payload: proposals) {
                return makeGatewayResult(for: key, fallback: cached)
            }
            try ensureTransitionLedgerCapacity(for: key)
            result = try processDiscordProposalsForOutbound(proposals, recognizedUserIds: recognizedUserIds)
            storeLedgerResult(
                key: key,
                kind: .proposals,
                transitionId: nil,
                payload: proposals,
                actions: result.outboundActions,
                recoveryHint: result.recoveryHint
            )

        case .welcome(let welcome, let transitionId, let recognizedUserIds):
            key = ledgerKey(kind: .welcome, transitionId: transitionId, payload: welcome)
            result = try processDiscordWelcomeForOutbound(
                welcome,
                transitionId: transitionId,
                recognizedUserIds: recognizedUserIds
            )
            // Invalid-transition recovery recreates the session and therefore
            // clears its normal high-level ledger entry. Reinsert the emitted
            // recovery action here so a gateway replay reuses the same outbox
            // envelope instead of re-running native MLS recovery.
            if transitionLedger[key] == nil {
                storeLedgerResult(
                    key: key,
                    kind: .welcome,
                    transitionId: transitionId,
                    payload: welcome,
                    actions: result.outboundActions,
                    recoveryHint: result.recoveryHint
                )
            }

        case .commit(let commit, let transitionId):
            key = ledgerKey(kind: .commit, transitionId: transitionId, payload: commit)
            result = try processDiscordCommitForOutbound(commit, transitionId: transitionId)
            if transitionLedger[key] == nil {
                storeLedgerResult(
                    key: key,
                    kind: .commit,
                    transitionId: transitionId,
                    payload: commit,
                    actions: result.outboundActions,
                    recoveryHint: result.recoveryHint
                )
            }

        case .executeTransition(let transitionId):
            key = ledgerKey(kind: .execute, transitionId: transitionId, payload: nil)
            result = executeDiscordTransition(transitionId)

        case .prepareEpoch(let protocolVersion, let epoch, let transitionId):
            key = ledgerKey(
                kind: .prepareEpoch,
                transitionId: transitionId,
                payload: Data("\(protocolVersion):\(epoch)".utf8)
            )
            if let cached = cachedLedgerResult(
                for: key,
                kind: .prepareEpoch,
                transitionId: transitionId,
                payload: Data("\(protocolVersion):\(epoch)".utf8)
            ) {
                return makeGatewayResult(for: key, fallback: cached)
            }
            try ensureTransitionLedgerCapacity(for: key)
            result = try prepareDiscordEpoch(
                protocolVersion: protocolVersion,
                epoch: epoch,
                transitionId: transitionId
            )
            storeLedgerResult(
                key: key,
                kind: .prepareEpoch,
                transitionId: transitionId,
                payload: Data("\(protocolVersion):\(epoch)".utf8),
                actions: result.outboundActions,
                recoveryHint: result.recoveryHint
            )
        }

        return makeGatewayResult(for: key, fallback: result)
    }

    /// Returns undelivered gateway actions in deterministic send order.
    public func pendingDiscordGatewayActions() -> [DiscordDaveOutboundActionEnvelope] {
        pendingOutboundActionOrder.compactMap { id in
            pendingOutboundActions[id].map { DiscordDaveOutboundActionEnvelope(id: id, action: $0) }
        }
    }

    /// Acknowledges that one outbox action was successfully written to the
    /// voice gateway. Unknown/previously acknowledged IDs are harmless no-ops.
    public func acknowledgeDiscordGatewayAction(_ id: UUID) {
        guard let action = pendingOutboundActions.removeValue(forKey: id) else { return }
        pendingOutboundActionOrder.removeAll { $0 == id }
        if case .mlsKeyPackage = action {
            hasSentInitialKeyPackage = true
        }
        lastRecoveryAction = .acknowledgeOutboundAction
        lastTransitionTimestamp = Date()
    }

    /// Internal snapshot of the invariants the state machine must never break,
    /// so tests can assert them without reaching into individual fields.
    internal struct InvariantSnapshot {
        let mediaReady: Bool
        let hasEncryptor: Bool
        let hasActiveOutboundRatchet: Bool
        let handshakeState: DaveHandshakeState
        let ledgerEntryCount: Int
        let stagedTransitionCount: Int
        let stagedTransitionOrderCount: Int
        let pendingOutboundActionCount: Int
        let decryptorCount: Int
    }

    internal var invariantSnapshot: InvariantSnapshot {
        InvariantSnapshot(
            mediaReady: mediaReady,
            hasEncryptor: encryptor != nil,
            hasActiveOutboundRatchet: activeOutboundRatchet != nil,
            handshakeState: handshakeState,
            ledgerEntryCount: transitionLedger.count,
            stagedTransitionCount: stagedTransitions.count,
            stagedTransitionOrderCount: stagedTransitionOrder.count,
            pendingOutboundActionCount: pendingOutboundActions.count,
            decryptorCount: decryptors.count
        )
    }

    /// Test-only accessor for the recognized-participant baseline that roster
    /// verification compares against.
    internal func setRecognizedRosterForTesting(_ userIds: [String]) {
        recognizedRosterUserIds = Set(userIds)
    }

    /// Evidence for the serialization guarantee this type advertises.
    ///
    /// The dedicated serial executor is what keeps a blocking native MLS call
    /// from starving the host's shared thread pool, and what serializes access
    /// to native state that is not thread-safe. `ExecutorSerializationTests`
    /// drives this concurrently and checks that the work never overlapped and
    /// that no non-atomic update was lost.
    internal struct ExecutorSerializationProbe {
        var maxConcurrentEntries = 0
        var nonAtomicCounter = 0
        var ranOffDedicatedQueue = false
        fileprivate var entriesInFlight = 0
    }

    private var executorProbe = ExecutorSerializationProbe()

    internal func recordExecutorSerializationProbe(increments: Int) {
        executorProbe.entriesInFlight += 1
        executorProbe.maxConcurrentEntries = max(
            executorProbe.maxConcurrentEntries,
            executorProbe.entriesInFlight
        )
#if !DAVE_DEFAULT_ACTOR_EXECUTOR
        if !executorQueue.label.isEmpty {
            dispatchPrecondition(condition: .onQueue(executorQueue))
        }
#else
        executorProbe.ranOffDedicatedQueue = true
#endif
        for _ in 0..<increments {
            executorProbe.nonAtomicCounter += 1
        }
        executorProbe.entriesInFlight -= 1
    }

    internal func executorSerializationProbe() -> ExecutorSerializationProbe {
        executorProbe
    }

    // MARK: - Private Helpers

    private func processMlsTransition(_ transition: DiscordTransition) throws -> ProcessedMlsTransition {
        try ensureAcceptingGatewayEvents()
        guard let session, let selfUserId else {
            throw DaveError.notConfigured
        }

        handshakeState = .handshaking
        lastTransitionTimestamp = Date()

        switch transition {
        case .welcome(let welcomeData, let recognizedUserIds):
            guard !welcomeData.isEmpty else {
                throw DaveError.invalidTransition(message: "Welcome payload was empty")
            }
            try validateMlsPayload(welcomeData, kind: "welcome")
            try validateDiscordUserIds(recognizedUserIds)
            guard let welcomeResult = session.processWelcome(welcomeData, recognizedUserIds: recognizedUserIds) else {
                throw DaveError.handshakeFailed(reason: "Welcome processing failed\(nativeFailureSuffix(session))")
            }
            guard let ratchet = session.getKeyRatchet(userId: selfUserId) else {
                throw DaveError.ratchetFailed(userId: selfUserId, reason: "Could not retrieve key ratchet after welcome")
            }

            if encryptor == nil {
                try rebuildEncryptor()
            }
            // Receivers prepare the new ratchets before Execute; the native
            // transition API retains prior receive context for in-flight media.
            try validateRosterCount(welcomeResult.rosterMemberIds.count)
            recognizedRosterUserIds = Set(recognizedUserIds)
            try applyRoster(welcomeResult.rosterMemberIds) {
                welcomeResult.getRosterMemberSignature(rosterId: $0)
            }
            synchronizeDecryptors(rosterMemberIds: welcomeResult.rosterMemberIds)
            appliedTransitionCount &+= 1
            handshakeState = .ready
            lastMlsError = nil
            lastRecoveryAction = .processWelcome
            return ProcessedMlsTransition(kind: .welcome, didApply: true, outboundRatchet: ratchet)

        case .commit(let commitData):
            guard !commitData.isEmpty else {
                throw DaveError.invalidTransition(message: "Commit payload was empty")
            }
            try validateMlsPayload(commitData, kind: "commit")
            let commitResult = session.processCommit(commitData)
            if commitResult.isFailed {
                throw DaveError.handshakeFailed(reason: "Commit processing failed\(nativeFailureSuffix(session))")
            }

            guard !commitResult.isIgnored else {
                handshakeState = .ready
                lastMlsError = nil
                lastRecoveryAction = .processCommit
                return ProcessedMlsTransition(kind: .commit, didApply: false, outboundRatchet: nil)
            }
            guard let ratchet = session.getKeyRatchet(userId: selfUserId) else {
                throw DaveError.ratchetFailed(userId: selfUserId, reason: "Could not retrieve key ratchet after commit")
            }

            if encryptor == nil {
                try rebuildEncryptor()
            }
            try validateRosterCount(commitResult.rosterMemberIds.count)
            try applyRoster(commitResult.rosterMemberIds) {
                commitResult.getRosterMemberSignature(rosterId: $0)
            }
            synchronizeDecryptors(rosterMemberIds: commitResult.rosterMemberIds)
            appliedTransitionCount &+= 1
            handshakeState = .ready
            lastMlsError = nil
            lastRecoveryAction = .processCommit
            return ProcessedMlsTransition(kind: .commit, didApply: true, outboundRatchet: ratchet)
        }
    }

    /// Stages a future outbound ratchet while preserving the currently active
    /// one. Returns whether Execute was already received for this transition.
    private func stageOutboundTransition(
        id: UInt64,
        ratchet: DaveKeyRatchet,
        source: TransitionKind,
        protocolVersion: UInt16
    ) throws -> Bool {
        let executeSeen = stagedTransitions[id]?.executeSeen ?? false
        if let existing = stagedTransitions[id], existing.outboundRatchet != nil {
            guard existing.source == source, existing.protocolVersion == protocolVersion else {
                failClosed(reason: "Conflicting staged transition \(id)")
                throw DaveError.transitionConflict(transitionId: id)
            }
            return existing.executeSeen
        }

        if !stagedTransitionOrder.contains(id) {
            // Staged transitions are a *window* on to what Discord may execute
            // next, not a permanent record. A long call legitimately produces
            // more transitions than the window holds, so age the oldest out
            // rather than killing a healthy session at an arbitrary count.
            evictStagedTransitions(reserving: 1)
        }

        stagedTransitions[id] = StagedTransition(
            transitionId: id,
            outboundRatchet: ratchet,
            protocolVersion: protocolVersion,
            source: source,
            executeSeen: executeSeen
        )
        if !stagedTransitionOrder.contains(id) {
            stagedTransitionOrder.append(id)
            trimStagedTransitionsIfNeeded()
        }
        refreshPendingTransitionID()
        lastRecoveryAction = .stageTransition
        lastTransitionTimestamp = Date()
        return executeSeen
    }

    /// Records a premature Execute without inventing a ratchet. The matching
    /// commit/welcome replaces this placeholder and activates immediately.
    private func stageExecuteBeforeMls(_ transitionId: UInt64) {
        if var existing = stagedTransitions[transitionId] {
            existing.executeSeen = true
            stagedTransitions[transitionId] = existing
        } else {
            evictStagedTransitions(reserving: 1)
            stagedTransitions[transitionId] = StagedTransition(
                transitionId: transitionId,
                outboundRatchet: nil,
                protocolVersion: pendingProtocolVersion ?? protocolVersion,
                source: .execute,
                executeSeen: true
            )
            stagedTransitionOrder.append(transitionId)
            trimStagedTransitionsIfNeeded()
        }
        refreshPendingTransitionID()
        lastTransitionTimestamp = Date()
    }

    @discardableResult
    private func activateStagedTransition(_ transitionId: UInt64, reason: String) -> Bool {
        guard let staged = stagedTransitions[transitionId], let ratchet = staged.outboundRatchet else {
            return false
        }
        guard let encryptor else {
            failClosed(reason: "No encryptor available to activate transition \(transitionId)")
            return false
        }

        encryptor.setKeyRatchet(ratchet)
        activeOutboundRatchet = ratchet
        activeTransitionId = transitionId
        // A later MLS Commit/Welcome with initialization ID zero consumes the
        // sole-member-reset authorization immediately. Once it has installed
        // a ratchet, a future replay must be handled by the ordinary active
        // transition/ledger checks rather than revoking this live context.
        if transitionId == 0 {
            soleMemberResetExecuteSeen = false
        }
        protocolVersion = staged.protocolVersion
        if pendingProtocolVersion == staged.protocolVersion {
            pendingProtocolVersion = nil
        }
        pendingEpoch = nil
        stagedTransitions[transitionId] = nil
        stagedTransitionOrder.removeAll { $0 == transitionId }
        refreshPendingTransitionID()
        mediaReady = true
        clearMediaReadinessWatchdog()
        markExecuteTransitionActivated(transitionId)
        lastRecoveryAction = .activateTransition
        lastTransitionTimestamp = Date()
        return true
    }

    /// Legacy activation path for integrations which have not supplied Discord
    /// transition IDs. It intentionally leaves media paused; only the caller's
    /// explicit readiness signal can resume it. New integrations must use the
    /// staged `Execute Transition` path above.
    private func activateOutboundRatchet(
        _ ratchet: DaveKeyRatchet,
        transitionId: UInt64?,
        reason: String
    ) {
        guard let encryptor else {
            failClosed(reason: "No encryptor available to activate legacy transition")
            return
        }
        encryptor.setKeyRatchet(ratchet)
        activeOutboundRatchet = ratchet
        activeTransitionId = transitionId
        mediaReady = false
        lastRecoveryAction = .activateTransition
        lastTransitionTimestamp = Date()
    }

    private func refreshPendingTransitionID() {
        pendingTransitionId = stagedTransitionOrder.first
    }

    private func trimStagedTransitionsIfNeeded() {
        evictStagedTransitions(reserving: 0)
        refreshPendingTransitionID()
    }

    /// Drops the oldest staged transitions so that `reserving` more can be
    /// added inside `maximumTrackedTransitions`.
    ///
    /// Discord executes transitions in order, so the oldest staged entry is the
    /// one least likely to still be executed. Dropping it degrades gracefully:
    /// if its Execute does arrive later it is treated as an Execute-before-MLS
    /// signal, media stays paused, and the readiness watchdog still guards the
    /// session. That is strictly better than the previous behavior, which
    /// failed the whole voice session closed once the window filled up.
    private func evictStagedTransitions(reserving additional: Int) {
        var overflow = stagedTransitionOrder.count + additional - limits.maximumTrackedTransitions
        guard overflow > 0 else { return }

        var survivors: [UInt64] = []
        survivors.reserveCapacity(stagedTransitionOrder.count)
        for id in stagedTransitionOrder {
            guard stagedTransitions[id] != nil else { continue }
            if overflow > 0 {
                stagedTransitions[id] = nil
                overflow -= 1
                evictedTransitionCount &+= 1
                continue
            }
            survivors.append(id)
        }
        stagedTransitionOrder = survivors
        refreshPendingTransitionID()
    }

    private func payloadDigest(_ payload: Data?) -> Data? {
        payload.map { Data(SHA256.hash(data: $0)) }
    }

    private func ledgerKey(
        kind: TransitionKind,
        transitionId: UInt64?,
        payload: Data?,
        discriminator: String? = nil
    ) -> String {
        let id = transitionId.map(String.init) ?? "-"
        let digest = payloadDigest(payload)?.base64EncodedString() ?? "-"
        // Transition IDs identify a single MLS state change. Keep their ledger
        // key independent of bytes so same-ID/different-payload is detected as
        // a fail-closed conflict rather than treated as a second transition.
        if transitionId != nil {
            return "\(discriminator ?? kind.rawValue):\(id)"
        }
        return "\(discriminator ?? kind.rawValue):\(digest)"
    }

    private func cachedTransitionResult(
        kind: TransitionKind,
        transitionId: UInt64,
        payload: Data?
    ) -> DiscordDaveTransitionResult? {
        let key = ledgerKey(kind: kind, transitionId: transitionId, payload: payload)
        guard let entry = transitionLedger[key] else { return nil }
        guard entry.payloadDigest == payloadDigest(payload) else {
            failClosed(reason: "Conflicting payload for transition \(transitionId)")
            return makeDiscordResult(recoveryHint: .recreateSession)
        }
        return makeDiscordResult(actions: entry.actions, recoveryHint: entry.recoveryHint)
    }

    private func cachedLedgerResult(
        for key: String,
        kind: TransitionKind,
        transitionId: UInt64?,
        payload: Data?
    ) -> DiscordDaveTransitionResult? {
        guard let entry = transitionLedger[key] else { return nil }
        guard entry.kind == kind,
              entry.transitionId == transitionId,
              entry.payloadDigest == payloadDigest(payload) else {
            failClosed(reason: "Conflicting replay ledger entry for \(kind.rawValue)")
            return makeDiscordResult(recoveryHint: .recreateSession)
        }
        return makeDiscordResult(actions: entry.actions, recoveryHint: entry.recoveryHint)
    }

    /// A transition ID represents one MLS update. Welcome and Commit are
    /// mutually exclusive payload types for that update; accepting both under
    /// the same ID would let a replay advance native state twice.
    private func validateMlsTransitionIdentity(
        kind: TransitionKind,
        transitionId: UInt64,
        payload: Data
    ) throws {
        guard let existing = transitionLedger.values.first(where: {
            $0.transitionId == transitionId && ($0.kind == .welcome || $0.kind == .commit)
        }) else {
            return
        }

        guard existing.kind == kind, existing.payloadDigest == payloadDigest(payload) else {
            failClosed(reason: "Conflicting MLS transition identity \(transitionId)")
            throw DaveError.transitionConflict(transitionId: transitionId)
        }
    }

    private func ensureTransitionLedgerCapacity(for key: String) throws {
        guard transitionLedger[key] == nil else { return }
        evictTransitionLedgerEntries(reserving: 1)
        guard transitionLedger.count < limits.maximumTrackedTransitions else {
            // Every entry is still pinned (unacknowledged outbound actions, or
            // the live transition). That is a stalled host, not a long call.
            failClosed(reason: "Exceeded the configured transition replay-ledger limit")
            throw DaveError.payloadTooLarge(
                kind: "transition replay ledger",
                maximum: limits.maximumTrackedTransitions,
                actual: transitionLedger.count + 1
            )
        }
    }

    /// Drops the oldest evictable replay-ledger entries so that `reserving`
    /// more can be stored inside `maximumTrackedTransitions`.
    ///
    /// The ledger exists to make a gateway resume idempotent, which only
    /// matters for recent events: a replay of something dozens of transitions
    /// old is not something Discord does. Entries are therefore aged out
    /// oldest-first, except for those that must not be forgotten yet:
    ///
    /// - entries whose outbound actions the host has not acknowledged, because
    ///   it may still retry those exact bytes; and
    /// - entries for the transition currently encrypting media, or for one
    ///   still staged, because those are live state rather than history.
    ///
    /// Without this, a call simply accumulated entries until it hit the bound
    /// and failed closed — roughly thirty membership changes, since each
    /// transition stores both its commit/welcome and its execute.
    private func evictTransitionLedgerEntries(reserving additional: Int) {
        var overflow = transitionLedger.count + additional - limits.maximumTrackedTransitions
        guard overflow > 0 else { return }

        var survivors: [String] = []
        survivors.reserveCapacity(transitionLedgerOrder.count)
        for key in transitionLedgerOrder {
            guard let entry = transitionLedger[key] else { continue }
            if overflow > 0, !isLedgerEntryPinned(entry) {
                transitionLedger[key] = nil
                overflow -= 1
                evictedTransitionCount &+= 1
                continue
            }
            survivors.append(key)
        }
        transitionLedgerOrder = survivors
    }

    /// Whether a ledger entry is still live state rather than replay history.
    private func isLedgerEntryPinned(_ entry: TransitionLedgerEntry) -> Bool {
        if entry.outboundActionIDs.contains(where: { pendingOutboundActions[$0] != nil }) {
            return true
        }
        guard let transitionId = entry.transitionId else { return false }
        return transitionId == activeTransitionId || stagedTransitions[transitionId] != nil
    }

    private func markExecuteTransitionActivated(_ transitionId: UInt64) {
        let key = ledgerKey(kind: .execute, transitionId: transitionId, payload: nil)
        guard let entry = transitionLedger[key] else { return }
        transitionLedger[key] = TransitionLedgerEntry(
            kind: entry.kind,
            transitionId: entry.transitionId,
            payloadDigest: entry.payloadDigest,
            actions: entry.actions,
            recoveryHint: .none,
            outboundActionIDs: entry.outboundActionIDs
        )
    }

    private func storeTransitionResult(
        kind: TransitionKind,
        transitionId: UInt64,
        payload: Data?,
        actions: [DiscordDaveOutboundAction],
        recoveryHint: DaveRecoveryHint
    ) {
        let key = ledgerKey(kind: kind, transitionId: transitionId, payload: payload)
        storeLedgerResult(
            key: key,
            kind: kind,
            transitionId: transitionId,
            payload: payload,
            actions: actions,
            recoveryHint: recoveryHint
        )
    }

    private func storeLedgerResult(
        key: String,
        kind: TransitionKind,
        transitionId: UInt64?,
        payload: Data?,
        actions: [DiscordDaveOutboundAction],
        recoveryHint: DaveRecoveryHint
    ) {
        if transitionLedger[key] == nil {
            evictTransitionLedgerEntries(reserving: 1)
            guard transitionLedger.count < limits.maximumTrackedTransitions else {
                failClosed(reason: "Exceeded the configured transition replay-ledger limit")
                return
            }
            transitionLedgerOrder.append(key)
        }
        let existingActionIDs = transitionLedger[key]?.outboundActionIDs ?? []
        transitionLedger[key] = TransitionLedgerEntry(
            kind: kind,
            transitionId: transitionId,
            payloadDigest: payloadDigest(payload),
            actions: actions,
            recoveryHint: recoveryHint,
            outboundActionIDs: existingActionIDs
        )
    }

    private func makeGatewayResult(
        for key: String,
        fallback: DiscordDaveTransitionResult
    ) -> DiscordDaveGatewayResult {
        var actionIDs = transitionLedger[key]?.outboundActionIDs ?? []
        if actionIDs.isEmpty, !fallback.outboundActions.isEmpty {
            for action in fallback.outboundActions {
                guard pendingOutboundActionOrder.count < limits.maximumPendingOutboundActions else {
                    failClosed(reason: "Exceeded the configured outbound-action limit")
                    break
                }
                let id = UUID()
                pendingOutboundActions[id] = action
                pendingOutboundActionOrder.append(id)
                actionIDs.append(id)
            }
            if var entry = transitionLedger[key] {
                entry.outboundActionIDs = actionIDs
                transitionLedger[key] = entry
            }
            if !actionIDs.isEmpty {
                lastRecoveryAction = .queueOutboundAction
                lastTransitionTimestamp = Date()
            }
        }

        let envelopes = actionIDs.compactMap { id in
            pendingOutboundActions[id].map { DiscordDaveOutboundActionEnvelope(id: id, action: $0) }
        }
        return DiscordDaveGatewayResult(
            pendingActions: envelopes,
            mediaReady: mediaReady,
            recoveryHint: fallback.recoveryHint,
            diagnostics: getDiagnostics(),
            rosterUserIds: rosterUserIds,
            unrecognizedRosterUserIds: unrecognizedRosterUserIds
        )
    }

    private func initializeSession(groupId: UInt64, selfUserId: String) throws {
        sessionGeneration &+= 1
        let generation = sessionGeneration
        session = try DaveSession(authSessionId: authSessionId) { [weak self] source, reason in
            Task { [weak self] in
                await self?.handleMLSFailure(source: source, reason: reason, generation: generation)
            }
        }

        session?.initialize(version: protocolVersion, groupId: groupId, selfUserId: selfUserId)

        if encryptor == nil {
            try rebuildEncryptor()
        }
        handshakeState = .initialized
        lastTransitionTimestamp = Date()
    }

    /// Returns the decryptor for a remote user, creating one on first use with
    /// the current passthrough mode and the user's ratchet when available.
    private func decryptorForUser(_ userId: String) throws -> DaveDecryptor {
        if let existing = decryptors[userId] {
            return existing
        }

        guard decryptors.count < limits.maximumRosterMembers else {
            throw DaveError.payloadTooLarge(
                kind: "remote decryptor roster",
                maximum: limits.maximumRosterMembers,
                actual: decryptors.count + 1
            )
        }

        let decryptor = try DaveDecryptor()
        decryptor.transitionToPassthroughMode(passthroughMode)
        if let session, let ratchet = session.getKeyRatchet(userId: userId) {
            decryptor.transitionToKeyRatchet(ratchet)
        }
        decryptors[userId] = decryptor
        return decryptor
    }

    /// Records the roster an applied transition produced and checks it against
    /// what the host said to expect.
    ///
    /// The roster is the group the client is actually encrypting to. A member
    /// in it that the voice session never announced is the case end-to-end
    /// encryption exists to surface, so it is always recorded and reported;
    /// ``DaveRosterVerificationPolicy`` decides whether it also stops media.
    ///
    /// A roster is only checked once the host has supplied a recognized list
    /// (Discord sends one with a Welcome). Before that — most importantly when
    /// this client created the group itself — there is nothing to compare
    /// against, and treating every member as unrecognized would be noise.
    internal func applyRoster(
        _ rosterMemberIds: [UInt64],
        signature: @Sendable (UInt64) -> Data?
    ) throws {
        rosterUserIds = rosterMemberIds.map(String.init)

        var signatures: [String: Data] = [:]
        signatures.reserveCapacity(rosterMemberIds.count)
        for memberId in rosterMemberIds {
            if let signature = signature(memberId) {
                signatures[String(memberId)] = signature
            }
        }
        rosterMemberSignatures = signatures

        guard !recognizedRosterUserIds.isEmpty else {
            unrecognizedRosterUserIds = []
            return
        }

        // The local client is always a legitimate member of its own group,
        // whether or not it appears in the list Discord supplied.
        var expected = recognizedRosterUserIds
        if let selfUserId {
            expected.insert(selfUserId)
        }
        unrecognizedRosterUserIds = rosterUserIds.filter { !expected.contains($0) }

        guard !unrecognizedRosterUserIds.isEmpty else { return }
        if limits.unrecognizedRosterMemberPolicy == .failClosed {
            throw DaveError.unrecognizedRosterMembers(userIds: unrecognizedRosterUserIds)
        }
    }

    /// Brings per-user decryptors in step with the roster after an applied
    /// welcome/commit: users who left are dropped, remaining users transition
    /// to their ratchet for the new epoch. Users who joined get a decryptor
    /// lazily on their first decrypted frame.
    private func synchronizeDecryptors(rosterMemberIds: [UInt64]) {
        guard let session else { return }

        let rosterUserIds = Set(rosterMemberIds.map(String.init))
        for userId in Array(decryptors.keys) {
            guard let decryptor = decryptors[userId] else { continue }
            guard rosterUserIds.contains(userId) else {
                decryptors[userId] = nil
                continue
            }
            if let ratchet = session.getKeyRatchet(userId: userId) {
                decryptor.transitionToKeyRatchet(ratchet)
            } else {
                // No ratchet for a user still in the roster: drop the stale
                // decryptor; it is recreated (and re-keyed) on the next frame.
                decryptors[userId] = nil
            }
        }
    }

    /// Prepares receive-side transforms for a retained MLS group whose DAVE
    /// protocol version is changing. Native decryptors retain the prior
    /// ratchet briefly, so in-flight frames remain decryptable while outgoing
    /// media continues on `activeOutboundRatchet` until Execute arrives.
    private func prepareExistingDecryptorsForCurrentSession() throws {
        guard let session else { throw DaveError.notConfigured }

        for userId in Array(decryptors.keys) {
            guard let decryptor = decryptors[userId] else { continue }
            guard let ratchet = session.getKeyRatchet(userId: userId) else {
                decryptors[userId] = nil
                continue
            }
            decryptor.transitionToKeyRatchet(ratchet)
        }
    }

    private func handleMLSFailure(source: String, reason: String, generation: UInt64) {
        guard generation == sessionGeneration else { return }
        failClosed(reason: "Source: \(source), Reason: \(reason)")
    }

    /// Native MLS failures must revoke media capability immediately. Leaving an
    /// existing encryptor live after an asynchronous failure risks sending on a
    /// stale ratchet even though diagnostics say the handshake failed.
    private func failClosed(reason: String) {
        encryptorGeneration &+= 1
        encryptor = nil
        activeOutboundRatchet = nil
        activeTransitionId = nil
        decryptors.removeAll()
        assignedSsrcs.removeAll()
        stagedTransitions.removeAll()
        stagedTransitionOrder.removeAll()
        // These actions and replay entries are bound to the failed native
        // session generation. Keeping them would let a reconnect send a key
        // package, commit, or transition-ready signal for invalidated state.
        transitionLedger.removeAll()
        transitionLedgerOrder.removeAll()
        pendingOutboundActions.removeAll()
        pendingOutboundActionOrder.removeAll()
        hasIssuedInitialKeyPackage = false
        hasSentInitialKeyPackage = false
        mediaReady = false
        pendingEpoch = nil
        pendingTransitionId = nil
        pendingProtocolVersion = nil
        rosterUserIds.removeAll()
        rosterMemberSignatures.removeAll()
        unrecognizedRosterUserIds.removeAll()
        clearMediaReadinessWatchdog()
        handshakeState = .failed
        lastMlsError = reason
        lastRecoveryAction = .failClosed
        lastTransitionTimestamp = Date()
    }

    /// Drains the most recent native MLS failure (reported via the failure
    /// callback during the preceding native call) for inclusion in a thrown
    /// error, and records it for diagnostics. Returns "" when none was reported.
    private func nativeFailureSuffix(_ session: DaveSession) -> String {
        guard let failure = session.takeLastMLSFailure() else { return "" }
        lastMlsError = "Source: \(failure.source), Reason: \(failure.reason)"
        return " — \(failure.source): \(failure.reason)"
    }

    private func makeInitialKeyPackageActionIfNeeded(requireExternalSender: Bool) throws -> DiscordDaveOutboundAction? {
        // Generating an action and delivering it are separate operations.  The
        // outbox may need to retry after a failed WebSocket write, and asking
        // native MLS for a second package here would create different bytes for
        // what Discord considers the same initial state.
        guard !hasIssuedInitialKeyPackage else {
            return nil
        }
        if requireExternalSender, externalSenderState != .registered {
            throw DaveError.externalSenderRequired
        }

        let keyPackage = try getMarshalledKeyPackage()
        hasIssuedInitialKeyPackage = true
        lastRecoveryAction = .sendInitialKeyPackage
        lastTransitionTimestamp = Date()
        return .mlsKeyPackage(keyPackage)
    }

    private func appendInitialKeyPackageActionIfAvailable(
        to actions: inout [DiscordDaveOutboundAction],
        requireExternalSender: Bool
    ) throws {
        if let keyPackageAction = try makeInitialKeyPackageActionIfNeeded(requireExternalSender: requireExternalSender) {
            actions.append(keyPackageAction)
        }
    }

    private func makeDiscordResult(
        actions: [DiscordDaveOutboundAction] = [],
        recoveryHint: DaveRecoveryHint = .none
    ) -> DiscordDaveTransitionResult {
        DiscordDaveTransitionResult(
            outboundActions: actions,
            mediaReady: mediaReady,
            recoveryHint: recoveryHint,
            diagnostics: getDiagnostics(),
            rosterUserIds: rosterUserIds,
            unrecognizedRosterUserIds: unrecognizedRosterUserIds
        )
    }

    private func clearMediaReadinessWatchdog() {
        mediaReadinessWatchdogTask?.cancel()
        mediaReadinessWatchdogTask = nil
        mediaReadinessWatchdogStartedAt = nil
        mediaReadinessWatchdogStartedDate = nil
        mediaReadinessWatchdogTimeout = limits.mediaReadinessTimeout
        mediaReadinessWatchdogReason = nil
    }

    /// Keeps media paused after installing a new ratchet until Discord confirms
    /// the matching Execute Transition. Preserve an existing watchdog (which
    /// carries the transition ID supplied by the high-level gateway helper).
    private func beginMediaReadinessWait(reason: String, timeout: TimeInterval? = nil) {
        mediaReady = false
        if mediaReadinessWatchdogStartedAt == nil {
            mediaReadinessWatchdogStartedAt = .now
            mediaReadinessWatchdogStartedDate = Date()
            mediaReadinessWatchdogTimeout = max(0, timeout ?? limits.mediaReadinessTimeout)
            mediaReadinessWatchdogReason = reason
            scheduleMediaReadinessWatchdog()
        }
    }

    /// Turns the pull-style watchdog state into an actual safety boundary. A
    /// stalled gateway transition must revoke media rather than leaving the
    /// application silently transmitting on an indeterminate MLS state.
    private func scheduleMediaReadinessWatchdog() {
        mediaReadinessWatchdogTask?.cancel()
        mediaReadinessWatchdogTask = nil

        guard let startedAt = mediaReadinessWatchdogStartedAt else { return }
        let timeout = mediaReadinessWatchdogTimeout
        let generation = sessionGeneration

        if timeout <= 0 {
            mediaReadinessWatchdogTask = Task { [weak self] in
                await self?.expireMediaReadinessWatchdog(
                    sessionGeneration: generation,
                    startedAt: startedAt
                )
            }
            return
        }

        mediaReadinessWatchdogTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(timeout))
            } catch {
                return
            }
            await self?.expireMediaReadinessWatchdog(
                sessionGeneration: generation,
                startedAt: startedAt
            )
        }
    }

    /// Converts a `Duration` to seconds without losing sub-second precision.
    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) * 1e-18
    }

    private func expireMediaReadinessWatchdog(sessionGeneration: UInt64, startedAt: ContinuousClock.Instant) {
        guard sessionGeneration == self.sessionGeneration,
              mediaReadinessWatchdogStartedAt == startedAt,
              case .timedOut(let reason, _) = evaluateMediaReadinessWatchdog() else {
            return
        }
        failClosed(reason: "DAVE media readiness watchdog expired: \(reason)")
    }

    /// Discord's DAVE implementation parses user IDs as unsigned integer
    /// Snowflakes. Reject malformed input before it reaches the native layer,
    /// where it would otherwise surface only as an opaque parsing failure.
    private func validateDiscordUserId(_ userId: String) throws {
        guard !userId.isEmpty,
              userId.utf8.count <= 20,
              userId.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
              let value = UInt64(userId),
              value > 0 else {
            throw DaveError.invalidDiscordUserId(userId)
        }
    }

    private func ensureAcceptingGatewayEvents() throws {
        guard handshakeState != .failed else {
            throw DaveError.sessionFailed
        }
    }

    private func validateDiscordUserIds(_ userIds: [String]) throws {
        try validateRosterCount(userIds.count)
        for userId in userIds {
            try validateDiscordUserId(userId)
        }
    }

    private func validateDiscordGroupId(_ groupId: UInt64) throws {
        guard groupId > 0 else {
            throw DaveError.invalidDiscordGroupId(groupId)
        }
    }

    private func validateProtocolVersion(_ version: UInt16) throws {
        let maximumSupported = daveMaxSupportedProtocolVersion()
        guard version > 0, version <= maximumSupported else {
            throw DaveError.unsupportedProtocolVersion(
                requested: version,
                maximumSupported: maximumSupported
            )
        }
    }

    private func validateMlsPayload(_ payload: Data, kind: String) throws {
        guard payload.count <= limits.maximumMlsPayloadBytes else {
            throw DaveError.payloadTooLarge(
                kind: kind,
                maximum: limits.maximumMlsPayloadBytes,
                actual: payload.count
            )
        }
    }

    private func validateRosterCount(_ count: Int) throws {
        guard count <= limits.maximumRosterMembers else {
            throw DaveError.payloadTooLarge(
                kind: "roster member count",
                maximum: limits.maximumRosterMembers,
                actual: count
            )
        }
    }

    private func handleProtocolVersionChanged(from generation: UInt64) {
        guard generation == encryptorGeneration else { return }
        guard let encryptor, encryptor.protocolVersion > 0 else { return }

        // The version callback is a notification, not permission for native
        // state to silently override the gateway-negotiated version. A stale
        // encryptor callback or an unexpected downgrade must stop media.
        let reported = encryptor.protocolVersion
        let expected = pendingProtocolVersion ?? protocolVersion
        guard reported == expected else {
            failClosed(
                reason: "Encryptor reported protocol version \(reported), expected \(expected)"
            )
            return
        }
        lastTransitionTimestamp = Date()
    }
}
