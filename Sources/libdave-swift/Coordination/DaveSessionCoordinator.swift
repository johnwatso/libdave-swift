import Foundation
import CDave

/// High-level actor orchestrating the DAVE/MLS session, key ratchets, and media encryption.
public actor DaveSessionCoordinator {
    /// Dedicated serial executor backing this actor.
    ///
    /// The DAVE/MLS calls underneath are synchronous, blocking C++/OpenSSL
    /// operations. Running them on Swift's shared cooperative thread pool means
    /// a single slow or wedged native call can starve unrelated async work in
    /// the host process. By pinning the actor to its own serial queue, any such
    /// stall is contained to this one thread — the rest of the host keeps
    /// running — while still serializing access to the (non-thread-safe) native
    /// session state.
    private let executorQueue = DispatchSerialQueue(label: "com.libdave.session.coordinator")
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executorQueue.asUnownedSerialExecutor()
    }

    // Lifecycles owned by actor
    private var session: DaveSession?
    private var encryptor: DaveEncryptor?

    // Internal configurations
    private let authSessionId: String?
    private var groupId: UInt64?
    private var selfUserId: String?
    
    // Internal state tracking
    private var protocolVersion: UInt16 = 0
    private var currentEpoch: UInt64 = 0
    private var handshakeState: DaveHandshakeState = .uninitialized
    private var lastMlsError: String?
    private var lastTransitionTimestamp: Date?
    private var isExternalSenderRegistered: Bool = false
    private var externalSenderState: DaveExternalSenderState = .missing
    private var externalSenderData: Data?
    private var mediaReady: Bool = false
    private var pendingEpoch: UInt64?
    private var pendingTransitionId: UInt64?
    private var lastRecoveryAction: DaveRecoveryAction?
    private var hasSentInitialKeyPackage: Bool = false
    private var mediaReadinessWatchdogStartedAt: Date?
    private var mediaReadinessWatchdogTimeout: TimeInterval = 10
    private var mediaReadinessWatchdogReason: String?

    /// Creates a new coordinator.
    /// - Parameter authSessionId: Optional identifier for managing persistent key lifetimes.
    public init(authSessionId: String? = nil) {
        self.authSessionId = authSessionId
    }

    /// Configures the coordinator specifically for Discord Voice usage.
    /// - Parameters:
    ///   - groupId: The target group identifier.
    ///   - selfUserId: The local client user ID.
    ///   - protocolVersion: The target protocol version (e.g. 1).
    public func configureForDiscordVoice(groupId: UInt64, selfUserId: String, protocolVersion: UInt16) throws {
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
        session?.reset()

        // Clear tracking state
        currentEpoch = 0
        handshakeState = .uninitialized
        lastMlsError = nil
        lastTransitionTimestamp = Date()
        isExternalSenderRegistered = false
        externalSenderState = .missing
        externalSenderData = nil
        mediaReady = false
        pendingEpoch = nil
        pendingTransitionId = nil
        lastRecoveryAction = .reset
        hasSentInitialKeyPackage = false
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
        encryptor = try DaveEncryptor()
        lastRecoveryAction = .rebuildEncryptor

        // Wire version changes to the actor safely
        encryptor?.setProtocolVersionChangedCallback { [weak self] in
            guard let self = self else { return }
            Task {
                await self.handleProtocolVersionChanged()
            }
        }

        // Reapply ratchet if we have one in the session
        if let session = session, let selfUserId = selfUserId {
            if let ratchet = session.getKeyRatchet(userId: selfUserId) {
                encryptor?.setKeyRatchet(ratchet)
            }
        }

        lastTransitionTimestamp = Date()
    }

    /// Processes an MLS transition for Discord Voice (e.g., Welcome or Commit).
    /// Automatically performs ratchet transitions.
    /// - Parameter transition: The welcome or commit transition data.
    public func processDiscordTransition(_ transition: DiscordTransition) throws {
        guard let session = session, let selfUserId = selfUserId else {
            throw DaveError.notConfigured
        }

        handshakeState = .handshaking
        lastTransitionTimestamp = Date()

        switch transition {
        case .welcome(let welcomeData, let recognizedUserIds):
            guard !welcomeData.isEmpty else {
                handshakeState = .failed
                throw DaveError.invalidTransition(message: "Welcome payload was empty")
            }
            guard session.processWelcome(welcomeData, recognizedUserIds: recognizedUserIds) != nil else {
                handshakeState = .failed
                throw DaveError.handshakeFailed(reason: "Welcome processing failed\(nativeFailureSuffix(session))")
            }

            // Manage ratchet transition for our user
            guard let ratchet = session.getKeyRatchet(userId: selfUserId) else {
                handshakeState = .failed
                throw DaveError.ratchetFailed(userId: selfUserId, reason: "Could not retrieve key ratchet after welcome")
            }

            if encryptor == nil {
                try rebuildEncryptor()
            }
            encryptor?.setKeyRatchet(ratchet)

            currentEpoch += 1
            handshakeState = .ready
            mediaReady = true
            pendingEpoch = nil
            pendingTransitionId = nil
            lastMlsError = nil
            lastRecoveryAction = .processWelcome
            clearMediaReadinessWatchdog()

        case .commit(let commitData):
            guard !commitData.isEmpty else {
                handshakeState = .failed
                throw DaveError.invalidTransition(message: "Commit payload was empty")
            }
            let commitResult = session.processCommit(commitData)
            if commitResult.isFailed {
                handshakeState = .failed
                throw DaveError.handshakeFailed(reason: "Commit processing failed\(nativeFailureSuffix(session))")
            }

            if !commitResult.isIgnored {
                // Manage ratchet transition for our user
                guard let ratchet = session.getKeyRatchet(userId: selfUserId) else {
                    handshakeState = .failed
                    throw DaveError.ratchetFailed(userId: selfUserId, reason: "Could not retrieve key ratchet after commit")
                }

                if encryptor == nil {
                    try rebuildEncryptor()
                }
                encryptor?.setKeyRatchet(ratchet)

                currentEpoch += 1
            }
            handshakeState = .ready
            mediaReady = true
            pendingEpoch = nil
            pendingTransitionId = nil
            lastMlsError = nil
            lastRecoveryAction = .processCommit
            clearMediaReadinessWatchdog()
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
    /// generation. Prefer `registerDiscordExternalSender(_:publishInitialKeyPackage:)`;
    /// this method exists for clients that intentionally use a delayed fallback.
    @discardableResult
    public func publishDiscordInitialKeyPackage() throws -> DiscordDaveTransitionResult {
        var actions: [DiscordDaveOutboundAction] = []
        if let keyPackageAction = try makeInitialKeyPackageActionIfNeeded(requireExternalSender: false) {
            actions.append(keyPackageAction)
        }
        return makeDiscordResult(actions: actions)
    }

    /// Marks the current generation's initial key package as already published
    /// for callers that still send `getMarshalledKeyPackage()` manually.
    public func markInitialKeyPackageSent() {
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
        recoveryTimeout: TimeInterval = 10
    ) throws -> DiscordDaveTransitionResult {
        do {
            try processDiscordTransition(.welcome(welcome, recognizedUserIds: recognizedUserIds))
            return makeDiscordResult(actions: [.transitionReady(transitionId)])
        } catch let error as DaveError where error.recoveryHint == .sendInvalidCommitWelcome {
            return try recoverDiscordInvalidTransition(transitionId: transitionId, timeout: recoveryTimeout)
        }
    }

    /// Processes a Discord Commit transition and returns either transition-ready
    /// or a complete invalid-transition recovery action set.
    @discardableResult
    public func processDiscordCommitForOutbound(
        _ commit: Data,
        transitionId: UInt64,
        recoveryTimeout: TimeInterval = 10
    ) throws -> DiscordDaveTransitionResult {
        do {
            try processDiscordTransition(.commit(commit))
            return makeDiscordResult(actions: [.transitionReady(transitionId)])
        } catch let error as DaveError where error.recoveryHint == .sendInvalidCommitWelcome {
            return try recoverDiscordInvalidTransition(transitionId: transitionId, timeout: recoveryTimeout)
        }
    }

    /// Handles Discord's execute-transition signal. Media is marked ready only
    /// once MLS processing has installed a ratchet and the coordinator is ready.
    @discardableResult
    public func executeDiscordTransition(_ transitionId: UInt64) -> DiscordDaveTransitionResult {
        guard handshakeState == .ready else {
            mediaReady = false
            pendingTransitionId = transitionId
            lastTransitionTimestamp = Date()
            return makeDiscordResult(recoveryHint: .retryLater)
        }

        _ = markDiscordMediaReady(reason: "execute transition \(transitionId)")
        return makeDiscordResult()
    }

    /// Prepares a fresh Discord DAVE epoch, preserving a cached external sender
    /// when available and emitting a new key package action for the recreated
    /// MLS session.
    @discardableResult
    public func prepareDiscordEpoch(
        protocolVersion: UInt16,
        epoch: UInt64,
        timeout: TimeInterval = 10
    ) throws -> DiscordDaveTransitionResult {
        guard groupId != nil, selfUserId != nil else {
            throw DaveError.notConfigured
        }

        let cachedExternalSender = externalSenderData
        self.protocolVersion = protocolVersion
        try recreateSessionState()

        var actions: [DiscordDaveOutboundAction] = []
        if let cachedExternalSender {
            try setExternalSender(cachedExternalSender)
            appendInitialKeyPackageActionIfAvailable(to: &actions, requireExternalSender: true)
        }

        _ = markDiscordMediaNotReady(
            reason: "prepare epoch \(epoch)",
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
        timeout: TimeInterval = 10
    ) throws -> DiscordDaveTransitionResult {
        let cachedExternalSender = externalSenderData
        try recreateSessionState()

        var actions: [DiscordDaveOutboundAction] = [.invalidCommitWelcome(transitionId)]
        if let cachedExternalSender {
            try setExternalSender(cachedExternalSender)
            appendInitialKeyPackageActionIfAvailable(to: &actions, requireExternalSender: true)
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
        timeout: TimeInterval = 10
    ) -> DaveMediaReadinessWatchdogStatus {
        mediaReady = false
        if let pendingTransitionId {
            self.pendingTransitionId = pendingTransitionId
        }
        if let pendingEpoch {
            self.pendingEpoch = pendingEpoch
        }
        mediaReadinessWatchdogStartedAt = Date()
        mediaReadinessWatchdogTimeout = max(0, timeout)
        mediaReadinessWatchdogReason = reason
        lastRecoveryAction = .pauseMedia
        lastTransitionTimestamp = Date()
        return evaluateMediaReadinessWatchdog()
    }

    /// Marks DAVE media as ready and clears any pending readiness watchdog.
    @discardableResult
    public func markDiscordMediaReady(reason: String? = nil) -> DaveMediaReadinessWatchdogStatus {
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
    public func evaluateMediaReadinessWatchdog(now: Date = Date()) -> DaveMediaReadinessWatchdogStatus {
        guard !mediaReady, let startedAt = mediaReadinessWatchdogStartedAt else {
            return .inactive
        }

        let remaining = mediaReadinessWatchdogTimeout - now.timeIntervalSince(startedAt)
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
        guard let encryptor = encryptor else {
            throw DaveError.invalidState(message: "Encryptor is not initialized or ratchet is not set.")
        }

        // Zero-configuration: automatically map new SSRCs to the Opus codec
        encryptor.assignSsrcToCodec(ssrc: ssrc, codec: .opus)

        do {
            return try encryptor.encrypt(mediaType: .audio, ssrc: ssrc, frame: frame)
        } catch let error as DaveError {
            throw error
        } catch {
            throw DaveError.encryptionFailed(reason: .encryptionFailure)
        }
    }

    /// Sets the external sender credentials.
    public func setExternalSender(_ externalSender: Data) throws {
        guard let session = session else {
            throw DaveError.notConfigured
        }
        session.setExternalSender(externalSender)
        isExternalSenderRegistered = true
        externalSenderState = .registered
        externalSenderData = externalSender
        lastRecoveryAction = .registerExternalSender
        lastTransitionTimestamp = Date()
    }

    /// Gets the marshalled MLS key package.
    public func getMarshalledKeyPackage() throws -> Data {
        guard let session = session else {
            throw DaveError.notConfigured
        }
        guard let keyPackage = session.marshalledKeyPackage else {
            throw DaveError.invalidState(message: "Failed to generate marshalled key package")
        }
        return keyPackage
    }

    /// Processes MLS proposals and generates commit/welcome messages.
    public func processProposals(_ proposals: Data, recognizedUserIds: [String]) throws -> Data {
        guard let session = session else {
            throw DaveError.notConfigured
        }
        guard !proposals.isEmpty else {
            throw DaveError.invalidTransition(message: "Proposals payload was empty")
        }
        guard let result = session.processProposals(proposals, recognizedUserIds: recognizedUserIds) else {
            throw DaveError.invalidState(message: "Proposals processing failed\(nativeFailureSuffix(session))")
        }
        lastRecoveryAction = .processProposals
        lastTransitionTimestamp = Date()
        return result
    }

    /// Sets the encryptor's passthrough mode.
    public func setPassthroughMode(_ enabled: Bool) throws {
        guard let encryptor = encryptor else {
            throw DaveError.invalidState(message: "Encryptor is not initialized.")
        }
        encryptor.setPassthroughMode(enabled)
    }

    /// Retrieves a snapshot of the current session diagnostics.
    public func getDiagnostics() -> DaveDiagnostics {
        let stats = encryptor?.stats(mediaType: .audio)
        return DaveDiagnostics(
            protocolVersion: protocolVersion,
            currentEpoch: currentEpoch,
            handshakeState: handshakeState,
            encryptionStats: stats,
            lastMlsError: lastMlsError,
            lastTransitionTimestamp: lastTransitionTimestamp,
            isExternalSenderRegistered: isExternalSenderRegistered,
            mediaReady: mediaReady,
            pendingEpoch: pendingEpoch,
            pendingTransitionId: pendingTransitionId,
            externalSenderState: externalSenderState,
            lastRecoveryAction: lastRecoveryAction,
            hasSentInitialKeyPackage: hasSentInitialKeyPackage
        )
    }

    // MARK: - Private Helpers

    private func initializeSession(groupId: UInt64, selfUserId: String) throws {
        session = try DaveSession(authSessionId: authSessionId) { [weak self] source, reason in
            guard let self = self else { return }
            Task {
                await self.handleMLSFailure(source: source, reason: reason)
            }
        }

        session?.initialize(version: protocolVersion, groupId: groupId, selfUserId: selfUserId)

        if encryptor == nil {
            try rebuildEncryptor()
        }
        handshakeState = .initialized
        lastTransitionTimestamp = Date()
    }

    private func handleMLSFailure(source: String, reason: String) {
        lastMlsError = "Source: \(source), Reason: \(reason)"
        handshakeState = .failed
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
        guard !hasSentInitialKeyPackage else {
            return nil
        }
        if requireExternalSender, externalSenderState != .registered {
            return nil
        }

        let keyPackage = try getMarshalledKeyPackage()
        hasSentInitialKeyPackage = true
        lastRecoveryAction = .sendInitialKeyPackage
        lastTransitionTimestamp = Date()
        return .mlsKeyPackage(keyPackage)
    }

    private func appendInitialKeyPackageActionIfAvailable(
        to actions: inout [DiscordDaveOutboundAction],
        requireExternalSender: Bool
    ) {
        do {
            if let keyPackageAction = try makeInitialKeyPackageActionIfNeeded(requireExternalSender: requireExternalSender) {
                actions.append(keyPackageAction)
            }
        } catch {
            lastMlsError = "Failed to generate initial key package: \(error.localizedDescription)"
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
            diagnostics: getDiagnostics()
        )
    }

    private func clearMediaReadinessWatchdog() {
        mediaReadinessWatchdogStartedAt = nil
        mediaReadinessWatchdogTimeout = 10
        mediaReadinessWatchdogReason = nil
    }

    private func handleProtocolVersionChanged() {
        if let encryptor = encryptor {
            self.protocolVersion = encryptor.protocolVersion
        }
        lastTransitionTimestamp = Date()
    }
}
