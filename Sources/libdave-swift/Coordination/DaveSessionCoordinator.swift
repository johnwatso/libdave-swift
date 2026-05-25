import Foundation
import CDave

/// High-level actor orchestrating the DAVE/MLS session, key ratchets, and media encryption.
public actor DaveSessionCoordinator {
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

    /// Resets the MLS session state using the native library's reset capabilities.
    public func reset() {
        session?.reset()

        // Clear tracking state
        currentEpoch = 0
        handshakeState = .uninitialized
        lastMlsError = nil
        lastTransitionTimestamp = Date()
        isExternalSenderRegistered = false
    }

    /// Recreates the MLS session state and reinitializes with current settings.
    public func recreateSessionState() throws {
        reset()

        if let groupId = groupId, let selfUserId = selfUserId {
            try initializeSession(groupId: groupId, selfUserId: selfUserId)
        }
    }

    /// Rebuilds only the encryptor, preserving session state but invalidating existing ratchets.
    public func rebuildEncryptor() throws {
        encryptor = try DaveEncryptor()

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
            guard session.processWelcome(welcomeData, recognizedUserIds: recognizedUserIds) != nil else {
                handshakeState = .failed
                throw DaveError.handshakeFailed(reason: "Welcome processing returned nil")
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

        case .commit(let commitData):
            let commitResult = session.processCommit(commitData)
            if commitResult.isFailed {
                handshakeState = .failed
                throw DaveError.handshakeFailed(reason: "Commit processing failed")
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
        }
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
        guard let result = session.processProposals(proposals, recognizedUserIds: recognizedUserIds) else {
            throw DaveError.invalidState(message: "Proposals processing returned nil")
        }
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
            isExternalSenderRegistered: isExternalSenderRegistered
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

    private func handleProtocolVersionChanged() {
        if let encryptor = encryptor {
            self.protocolVersion = encryptor.protocolVersion
        }
        lastTransitionTimestamp = Date()
    }
}
