import Foundation
import CDave

/// Opaque wrapper for a DAVE Key Ratchet.
public final class DaveKeyRatchet: @unchecked Sendable {
    internal let handle: DAVEKeyRatchetHandle

    internal init(handle: DAVEKeyRatchetHandle) {
        self.handle = handle
    }

    deinit {
        daveKeyRatchetDestroy(handle)
    }
}

/// Opaque wrapper for the result of an MLS commit process.
public final class DaveCommitResult: @unchecked Sendable {
    internal let handle: DAVECommitResultHandle?

    internal init(handle: DAVECommitResultHandle?) {
        self.handle = handle
    }

    deinit {
        if let handle = handle {
            daveCommitResultDestroy(handle)
        }
    }

    /// Returns whether the commit processing failed.
    public var isFailed: Bool {
        guard let handle = handle else { return true }
        return daveCommitResultIsFailed(handle)
    }

    /// Returns whether the commit should be ignored.
    public var isIgnored: Bool {
        guard let handle = handle else { return false }
        return daveCommitResultIsIgnored(handle)
    }

    /// Lists the member IDs in the roster after this commit.
    public var rosterMemberIds: [UInt64] {
        guard let handle = handle else { return [] }
        var rosterIdsPtr: UnsafeMutablePointer<UInt64>? = nil
        var length: Int = 0
        daveCommitResultGetRosterMemberIds(handle, &rosterIdsPtr, &length)
        guard let ptr = rosterIdsPtr, length > 0 else { return [] }
        let ids = Array(UnsafeBufferPointer(start: ptr, count: length))
        daveFree(ptr)
        return ids
    }

    /// Retrieves the signature of a roster member.
    public func getRosterMemberSignature(rosterId: UInt64) -> Data? {
        guard let handle = handle else { return nil }
        var signaturePtr: UnsafeMutablePointer<UInt8>? = nil
        var length: Int = 0
        daveCommitResultGetRosterMemberSignature(handle, rosterId, &signaturePtr, &length)
        guard let ptr = signaturePtr, length > 0 else { return nil }
        let data = Data(bytes: ptr, count: length)
        daveFree(ptr)
        return data
    }
}

/// Opaque wrapper for the result of processing an MLS welcome message.
public final class DaveWelcomeResult: @unchecked Sendable {
    internal let handle: DAVEWelcomeResultHandle

    internal init(handle: DAVEWelcomeResultHandle) {
        self.handle = handle
    }

    deinit {
        daveWelcomeResultDestroy(handle)
    }

    /// Lists the member IDs in the roster from this welcome message.
    public var rosterMemberIds: [UInt64] {
        var rosterIdsPtr: UnsafeMutablePointer<UInt64>? = nil
        var length: Int = 0
        daveWelcomeResultGetRosterMemberIds(handle, &rosterIdsPtr, &length)
        guard let ptr = rosterIdsPtr, length > 0 else { return [] }
        let ids = Array(UnsafeBufferPointer(start: ptr, count: length))
        daveFree(ptr)
        return ids
    }

    /// Retrieves the signature of a roster member from this welcome message.
    public func getRosterMemberSignature(rosterId: UInt64) -> Data? {
        var signaturePtr: UnsafeMutablePointer<UInt8>? = nil
        var length: Int = 0
        daveWelcomeResultGetRosterMemberSignature(handle, rosterId, &signaturePtr, &length)
        guard let ptr = signaturePtr, length > 0 else { return nil }
        let data = Data(bytes: ptr, count: length)
        daveFree(ptr)
        return data
    }
}

/// A DAVE session handle managing group encryption state and MLS protocol integration.
public final class DaveSession: @unchecked Sendable {
    internal let handle: DAVESessionHandle
    private let bridgePointer: UnsafeMutableRawPointer

    /// Returns the maximum protocol version supported by this library.
    public static var maxSupportedProtocolVersion: UInt16 {
        return daveMaxSupportedProtocolVersion()
    }

    /// Creates a new DAVE session.
    /// - Parameters:
    ///   - authSessionId: Identifier used to manage persistent key lifetimes.
    ///   - onMLSFailure: Callback invoked when an MLS failure occurs.
    public init(authSessionId: String? = nil, onMLSFailure: @escaping @Sendable (String, String) -> Void) throws {
        let bridge = DaveSessionCallbackBridge()
        bridge.onMLSFailure = onMLSFailure
        let bridgePtr = Unmanaged.passRetained(bridge).toOpaque()

        let authIdCString = authSessionId?.cString(using: .utf8)
        let handleOpt = daveSessionCreate(nil, authIdCString, daveMLSFailureCallbackBridge, bridgePtr)

        guard let handle = handleOpt else {
            Unmanaged<DaveSessionCallbackBridge>.fromOpaque(bridgePtr).release()
            throw DaveError.sessionCreationFailed
        }

        self.handle = handle
        self.bridgePointer = bridgePtr
    }

    deinit {
        daveSessionDestroy(handle)
        Unmanaged<DaveSessionCallbackBridge>.fromOpaque(bridgePointer).release()
    }

    /// Initializes a session with protocol version and group information.
    public func initialize(version: UInt16, groupId: UInt64, selfUserId: String) {
        daveSessionInit(handle, version, groupId, selfUserId.cString(using: .utf8))
    }

    /// Resets the session state.
    public func reset() {
        daveSessionReset(handle)
    }

    /// Sets the protocol version for the session.
    public func setProtocolVersion(version: UInt16) {
        daveSessionSetProtocolVersion(handle, version)
    }

    /// Gets the current protocol version of the session.
    public var protocolVersion: UInt16 {
        return daveSessionGetProtocolVersion(handle)
    }

    /// Retrieves the authenticator from the last MLS epoch.
    public var lastEpochAuthenticator: Data? {
        var authPtr: UnsafeMutablePointer<UInt8>? = nil
        var length: Int = 0
        daveSessionGetLastEpochAuthenticator(handle, &authPtr, &length)
        guard let ptr = authPtr, length > 0 else { return nil }
        let data = Data(bytes: ptr, count: length)
        daveFree(ptr)
        return data
    }

    /// Sets the external sender credentials.
    public func setExternalSender(_ externalSender: Data) {
        externalSender.withUnsafeBytes { rawBuffer in
            if let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                daveSessionSetExternalSender(handle, baseAddress, externalSender.count)
            }
        }
    }

    /// Processes MLS proposals and generates commit/welcome messages.
    public func processProposals(_ proposals: Data, recognizedUserIds: [String]) -> Data? {
        var outputPtr: UnsafeMutablePointer<UInt8>? = nil
        var outputLength: Int = 0

        let cStrings = recognizedUserIds.map { strdup($0) }
        defer {
            for ptr in cStrings {
                free(ptr)
            }
        }
        var cStringsPtr = cStrings.map { UnsafePointer<CChar>($0) }

        proposals.withUnsafeBytes { proposalsBuffer in
            let proposalsPtr = proposalsBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
            cStringsPtr.withUnsafeMutableBufferPointer { recognizedBuffer in
                daveSessionProcessProposals(
                    handle,
                    proposalsPtr,
                    proposals.count,
                    recognizedBuffer.baseAddress,
                    recognizedUserIds.count,
                    &outputPtr,
                    &outputLength
                )
            }
        }

        guard let ptr = outputPtr, outputLength > 0 else { return nil }
        let data = Data(bytes: ptr, count: outputLength)
        daveFree(ptr)
        return data
    }

    /// Processes an incoming MLS commit message.
    public func processCommit(_ commit: Data) -> DaveCommitResult {
        let resultHandle = commit.withUnsafeBytes { commitBuffer -> DAVECommitResultHandle? in
            let commitPtr = commitBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return daveSessionProcessCommit(handle, commitPtr, commit.count)
        }
        return DaveCommitResult(handle: resultHandle)
    }

    /// Processes an incoming MLS welcome message to join a group.
    public func processWelcome(_ welcome: Data, recognizedUserIds: [String]) -> DaveWelcomeResult? {
        let cStrings = recognizedUserIds.map { strdup($0) }
        defer {
            for ptr in cStrings {
                free(ptr)
            }
        }
        var cStringsPtr = cStrings.map { UnsafePointer<CChar>($0) }

        let resultHandle = welcome.withUnsafeBytes { welcomeBuffer -> DAVEWelcomeResultHandle? in
            let welcomePtr = welcomeBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return cStringsPtr.withUnsafeMutableBufferPointer { recognizedBuffer in
                return daveSessionProcessWelcome(
                    handle,
                    welcomePtr,
                    welcome.count,
                    recognizedBuffer.baseAddress,
                    recognizedUserIds.count
                )
            }
        }

        guard let resHandle = resultHandle else { return nil }
        return DaveWelcomeResult(handle: resHandle)
    }

    /// Gets the marshalled MLS key package.
    public var marshalledKeyPackage: Data? {
        var outputPtr: UnsafeMutablePointer<UInt8>? = nil
        var outputLength: Int = 0
        daveSessionGetMarshalledKeyPackage(handle, &outputPtr, &outputLength)
        guard let ptr = outputPtr, outputLength > 0 else { return nil }
        let data = Data(bytes: ptr, count: outputLength)
        daveFree(ptr)
        return data
    }

    /// Gets a key ratchet for a specific user.
    public func getKeyRatchet(userId: String) -> DaveKeyRatchet? {
        guard let rHandle = daveSessionGetKeyRatchet(handle, userId.cString(using: .utf8)) else { return nil }
        return DaveKeyRatchet(handle: rHandle)
    }

    /// Computes a pairwise fingerprint for identity verification with another user.
    public func getPairwiseFingerprint(
        version: UInt16,
        userId: String,
        callback: @escaping @Sendable (Data) -> Void
    ) {
        let bridge = Unmanaged<DaveSessionCallbackBridge>.fromOpaque(bridgePointer).takeUnretainedValue()
        bridge.onPairwiseFingerprint = callback
        daveSessionGetPairwiseFingerprint(
            handle,
            version,
            userId.cString(using: .utf8),
            davePairwiseFingerprintCallbackBridge,
            bridgePointer
        )
    }
}
