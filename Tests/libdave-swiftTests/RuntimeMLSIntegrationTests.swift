import Foundation
import XCTest
@testable import libdave_swift

/// Runs a genuine two-member MLS establishment and encrypted media round trip.
///
/// Captured Welcome bytes cannot be replayed against a newly generated key
/// package, so the pinned native build produces a test-only external-sender
/// helper. The helper keeps its signing key alive while this test exchanges the
/// live key package, proposal, combined commit/welcome, commit, and Welcome.
final class RuntimeMLSIntegrationTests: XCTestCase {
    func testTwoMemberMlsEstablishmentAndEncryptedAudioRoundTrip() async throws {
        let helperURL = Self.integrationHelperURL
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: helperURL.path),
            "Build the pinned integration helper with Scripts/build-native-framework.sh"
        )

        let groupId: UInt64 = 1_234_567_890
        let userA = "1234123412341234"
        let userB = "5678567856785678"
        let userC = "9012901290129012"
        let initialUsers = [userA, userB]
        let rekeyedUsers = [userA, userB, userC]
        let helper = try ExternalSenderHelper(executableURL: helperURL, groupId: groupId)
        defer { helper.stop() }

        let externalSender = try helper.readPayload(named: "EXTERNAL_SENDER")

        let sessionA = DaveSessionCoordinator()
        let sessionB = DaveSessionCoordinator()
        let sessionC = DaveSessionCoordinator()
        try await sessionA.configureForDiscordVoice(groupId: groupId, selfUserId: userA, protocolVersion: 1)
        try await sessionB.configureForDiscordVoice(groupId: groupId, selfUserId: userB, protocolVersion: 1)
        try await sessionC.configureForDiscordVoice(groupId: groupId, selfUserId: userC, protocolVersion: 1)
        _ = try await sessionA.registerDiscordExternalSender(externalSender, publishInitialKeyPackage: false)
        _ = try await sessionB.registerDiscordExternalSender(externalSender, publishInitialKeyPackage: false)
        _ = try await sessionC.registerDiscordExternalSender(externalSender, publishInitialKeyPackage: false)

        let keyPackageB = try await sessionB.getMarshalledKeyPackage()
        let proposal = try helper.exchange(command: "KEY_PACKAGE", payload: keyPackageB, response: "PROPOSAL")
        let proposalResult = try await sessionA.processDiscordProposalsForOutbound(
            proposal,
            recognizedUserIds: initialUsers
        )
        guard case .mlsCommitWelcome(let commitWelcome) = proposalResult.outboundActions.first else {
            return XCTFail("proposal processing did not produce a combined commit/welcome")
        }

        try helper.write(command: "COMMIT_WELCOME", payload: commitWelcome)
        let commit = try helper.readPayload(named: "COMMIT")
        let welcome = try helper.readPayload(named: "WELCOME")

        // Transition zero is Discord's initialization transition. Both sides
        // activate their newly established ratchets immediately.
        let committed = try await sessionA.processDiscordCommitForOutbound(commit, transitionId: 0)
        let welcomed = try await sessionB.processDiscordWelcomeForOutbound(
            welcome,
            transitionId: 0,
            recognizedUserIds: initialUsers
        )
        XCTAssertTrue(committed.mediaReady)
        XCTAssertTrue(welcomed.mediaReady)
        XCTAssertEqual(committed.rosterUserIds, initialUsers)
        XCTAssertEqual(welcomed.rosterUserIds, initialUsers)
        XCTAssertTrue(committed.unrecognizedRosterUserIds.isEmpty)
        XCTAssertTrue(welcomed.unrecognizedRosterUserIds.isEmpty)

        let authenticatorA = try await sessionA.epochAuthenticator()
        let authenticatorB = try await sessionB.epochAuthenticator()
        XCTAssertNotNil(authenticatorA)
        XCTAssertEqual(authenticatorA, authenticatorB)

        let fingerprintA = try await sessionA.pairwiseFingerprint(version: 1, userId: userB)
        let fingerprintB = try await sessionB.pairwiseFingerprint(version: 1, userId: userA)
        XCTAssertNotNil(fingerprintA)
        XCTAssertEqual(fingerprintA, fingerprintB)

        let plaintext = Data([0x0d, 0xc5, 0xae, 0xdd, 0x5b, 0xdc, 0x3f, 0x20,
                              0xbe, 0x56, 0x97, 0xe5, 0x4d, 0xd1, 0xf4, 0x37])
        let ciphertext = try await sessionA.encryptDiscordAudioFrame(plaintext, ssrc: 42)
        XCTAssertNotEqual(ciphertext, plaintext)
        XCTAssertGreaterThan(ciphertext.count, plaintext.count)
        let decrypted = try await sessionB.decryptDiscordAudioFrame(ciphertext, from: userA)
        XCTAssertEqual(decrypted, plaintext)

        // Add a third member at epoch one. Existing members apply the same
        // commit, the joiner applies its live Welcome, and nonzero transition
        // ID 1 keeps all new ratchets staged until Execute arrives.
        let keyPackageC = try await sessionC.getMarshalledKeyPackage()
        let rekeyProposal = try helper.exchange(
            command: "REKEY_PACKAGE",
            payload: keyPackageC,
            response: "REKEY_PROPOSAL"
        )
        let rekeyProposalResult = try await sessionA.processDiscordProposalsForOutbound(
            rekeyProposal,
            recognizedUserIds: rekeyedUsers
        )
        // Every existing member receives the proposal before the sender's
        // commit, even though only the designated sender publishes artifacts.
        _ = try await sessionB.processDiscordProposalsForOutbound(
            rekeyProposal,
            recognizedUserIds: rekeyedUsers
        )
        guard case .mlsCommitWelcome(let rekeyCommitWelcome) = rekeyProposalResult.outboundActions.first else {
            return XCTFail("re-key proposal did not produce a combined commit/welcome")
        }

        try helper.write(command: "REKEY_COMMIT_WELCOME", payload: rekeyCommitWelcome)
        let rekeyCommit = try helper.readPayload(named: "REKEY_COMMIT")
        let rekeyWelcome = try helper.readPayload(named: "REKEY_WELCOME")

        let stagedA = try await sessionA.processDiscordCommitForOutbound(rekeyCommit, transitionId: 1)
        let stagedB = try await sessionB.processDiscordCommitForOutbound(rekeyCommit, transitionId: 1)
        let stagedC = try await sessionC.processDiscordWelcomeForOutbound(
            rekeyWelcome,
            transitionId: 1,
            recognizedUserIds: rekeyedUsers
        )
        // Existing members retain the prior epoch's active media ratchets
        // during a staged re-key. The joining member has no prior epoch and
        // therefore remains blocked until Execute.
        XCTAssertTrue(stagedA.mediaReady)
        XCTAssertTrue(stagedB.mediaReady)
        XCTAssertFalse(stagedC.mediaReady)

        let executedA = await sessionA.executeDiscordTransition(1)
        let executedB = await sessionB.executeDiscordTransition(1)
        let executedC = await sessionC.executeDiscordTransition(1)
        XCTAssertTrue(executedA.mediaReady)
        XCTAssertTrue(executedB.mediaReady)
        XCTAssertTrue(executedC.mediaReady)
        XCTAssertEqual(executedA.rosterUserIds, rekeyedUsers)
        XCTAssertEqual(executedB.rosterUserIds, rekeyedUsers)
        XCTAssertEqual(executedC.rosterUserIds, rekeyedUsers)

        let rekeyedAuthenticatorA = try await sessionA.epochAuthenticator()
        let rekeyedAuthenticatorB = try await sessionB.epochAuthenticator()
        let rekeyedAuthenticatorC = try await sessionC.epochAuthenticator()
        XCTAssertNotEqual(rekeyedAuthenticatorA, authenticatorA)
        XCTAssertEqual(rekeyedAuthenticatorA, rekeyedAuthenticatorB)
        XCTAssertEqual(rekeyedAuthenticatorA, rekeyedAuthenticatorC)

        let rekeyedCiphertext = try await sessionA.encryptDiscordAudioFrame(plaintext, ssrc: 42)
        XCTAssertNotEqual(rekeyedCiphertext, ciphertext)
        let rekeyedPlaintextB = try await sessionB.decryptDiscordAudioFrame(rekeyedCiphertext, from: userA)
        let rekeyedPlaintextC = try await sessionC.decryptDiscordAudioFrame(rekeyedCiphertext, from: userA)
        XCTAssertEqual(rekeyedPlaintextB, plaintext)
        XCTAssertEqual(rekeyedPlaintextC, plaintext)
    }

    private static var integrationHelperURL: URL {
        if let override = ProcessInfo.processInfo.environment["DAVE_EXTERNAL_SENDER_HELPER"] {
            return URL(fileURLWithPath: override)
        }
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repositoryRoot
            .appendingPathComponent(".build/native-rebuild/build/integration/dave_external_sender_helper")
    }
}

private final class ExternalSenderHelper {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let errors: FileHandle

    init(executableURL: URL, groupId: UInt64) throws {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = [String(groupId)]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()

        self.process = process
        self.input = inputPipe.fileHandleForWriting
        self.output = outputPipe.fileHandleForReading
        self.errors = errorPipe.fileHandleForReading
    }

    func exchange(command: String, payload: Data, response: String) throws -> Data {
        try write(command: command, payload: payload)
        return try readPayload(named: response)
    }

    func write(command: String, payload: Data) throws {
        let line = "\(command) \(payload.hexadecimal)\n"
        try input.write(contentsOf: Data(line.utf8))
    }

    func readPayload(named expectedName: String) throws -> Data {
        let line = try readLine()
        let prefix = "\(expectedName) "
        guard line.hasPrefix(prefix) else {
            throw IntegrationHelperError.unexpectedResponse(expected: expectedName, actual: line)
        }
        return try Data(hexadecimal: String(line.dropFirst(prefix.count)))
    }

    func stop() {
        try? input.close()
        if process.isRunning {
            process.terminate()
        }
    }

    private func readLine() throws -> String {
        var bytes = Data()
        while true {
            let byte = output.readData(ofLength: 1)
            if byte.isEmpty {
                process.waitUntilExit()
                let errorText = String(data: errors.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw IntegrationHelperError.terminated(status: process.terminationStatus, stderr: errorText)
            }
            if byte.first == 0x0a {
                guard let line = String(data: bytes, encoding: .utf8) else {
                    throw IntegrationHelperError.invalidUTF8
                }
                return line
            }
            bytes.append(byte)
        }
    }
}

private enum IntegrationHelperError: Error, CustomStringConvertible {
    case invalidHexadecimal
    case invalidUTF8
    case unexpectedResponse(expected: String, actual: String)
    case terminated(status: Int32, stderr: String)

    var description: String {
        switch self {
        case .invalidHexadecimal:
            return "integration helper returned invalid hexadecimal bytes"
        case .invalidUTF8:
            return "integration helper returned invalid UTF-8"
        case .unexpectedResponse(let expected, let actual):
            return "integration helper returned \(actual), expected \(expected)"
        case .terminated(let status, let stderr):
            return "integration helper exited with status \(status): \(stderr)"
        }
    }
}

private extension Data {
    var hexadecimal: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init(hexadecimal: String) throws {
        guard hexadecimal.count.isMultiple(of: 2) else {
            throw IntegrationHelperError.invalidHexadecimal
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexadecimal.count / 2)
        var index = hexadecimal.startIndex
        while index < hexadecimal.endIndex {
            let next = hexadecimal.index(index, offsetBy: 2)
            guard let byte = UInt8(hexadecimal[index..<next], radix: 16) else {
                throw IntegrationHelperError.invalidHexadecimal
            }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
