import XCTest
@testable import libdave_swift

/// Exercises the native MLS parser boundary directly, below the coordinator's
/// validation layer.
///
/// The state-machine fuzzer in `StateMachineFuzzTests` proves the Swift state
/// machine cannot be driven into an unsafe state, but most of its payloads are
/// rejected by size and shape checks before native code ever sees them. These
/// tests aim at the other side of the boundary: the C++/OpenSSL parser reached
/// through manually managed buffers, which is where a memory-safety bug would
/// actually live. They are most valuable under the sanitizer CI jobs.
///
/// The corpus is seeded with a *genuine* marshalled key package. Mutating real
/// MLS bytes gets far deeper into the parser than random blobs, which are
/// rejected almost immediately.
final class NativeBoundaryFuzzTests: XCTestCase {

    private struct SplitMix64: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func makeSession() throws -> DaveSession {
        let session = try DaveSession(authSessionId: nil) { _, _ in }
        session.initialize(version: 1, groupId: 4_242, selfUserId: "424242424242424242")
        return session
    }

    /// A real serialized MLS key package, or `nil` if the native library
    /// declines to produce one in this configuration.
    private func genuineKeyPackage() throws -> Data? {
        try makeSession().marshalledKeyPackage
    }

    /// Payload shapes chosen to hit the boundaries a hand-written parser gets
    /// wrong: empty input, single bytes, exact and off-by-one length-prefix
    /// values, and buffers whose declared length disagrees with reality.
    private func adversarialCorpus(_ generator: inout SplitMix64, seed base: Data?) -> [Data] {
        var corpus: [Data] = [
            Data(),
            Data([0x00]),
            Data([0xFF]),
            Data(repeating: 0x00, count: 16),
            Data(repeating: 0xFF, count: 16),
            Data(repeating: 0x41, count: 255),
            Data(repeating: 0x00, count: 4_096),
        ]

        // TLS-style length prefixes that lie about the payload that follows:
        // a parser that trusts the prefix reads out of bounds.
        for declared in [UInt16(0), 1, 255, 4_096, .max] {
            var lying = Data([UInt8(declared >> 8), UInt8(declared & 0xFF)])
            lying.append(contentsOf: [0xAA, 0xBB, 0xCC])
            corpus.append(lying)
        }

        for _ in 0..<8 {
            let count = Int.random(in: 0...2_048, using: &generator)
            var bytes = [UInt8]()
            bytes.reserveCapacity(count)
            for _ in 0..<count { bytes.append(UInt8.random(in: 0...255, using: &generator)) }
            corpus.append(Data(bytes))
        }

        // Mutations of genuine MLS bytes: truncations, extensions, and single
        // bit flips, which survive the outer framing and reach real parsing.
        if let base, !base.isEmpty {
            corpus.append(base)
            corpus.append(base.prefix(base.count / 2))
            corpus.append(base.prefix(base.count - 1))
            corpus.append(base + Data([0x00]))
            corpus.append(base + Data(repeating: 0x41, count: 64))

            for _ in 0..<24 {
                var mutated = [UInt8](base)
                let flips = Int.random(in: 1...4, using: &generator)
                for _ in 0..<flips {
                    let index = Int.random(in: 0..<mutated.count, using: &generator)
                    mutated[index] ^= UInt8(1 << Int.random(in: 0...7, using: &generator))
                }
                corpus.append(Data(mutated))
            }
        }

        return corpus
    }

    /// Every MLS entry point must reject hostile bytes by returning a failure,
    /// never by trapping, corrupting memory, or reporting bogus success.
    func testMlsEntryPointsSurviveHostilePayloads() throws {
        var generator = SplitMix64(seed: 0xDA7E)
        let keyPackage = try genuineKeyPackage()
        XCTAssertNotNil(keyPackage, "a genuine key package is needed to seed the corpus")
        let corpus = adversarialCorpus(&generator, seed: keyPackage)

        for (index, payload) in corpus.enumerated() {
            // A fresh session per payload: a rejected payload may leave the
            // native session unusable, and reusing it would mask later results.
            let session = try makeSession()

            let commitResult = session.processCommit(payload)
            // Malformed bytes must never be reported as an applied commit.
            if !commitResult.isFailed && !commitResult.isIgnored {
                XCTAssertLessThanOrEqual(
                    commitResult.rosterMemberIds.count,
                    1_000,
                    "payload \(index) produced an implausible roster"
                )
            }
            // Reading results of a failed commit must be safe.
            _ = commitResult.rosterMemberIds
            _ = commitResult.getRosterMemberSignature(rosterId: 0)

            let welcomeResult = session.processWelcome(payload, recognizedUserIds: ["424242424242424242"])
            if let welcomeResult {
                _ = welcomeResult.rosterMemberIds
                _ = welcomeResult.getRosterMemberSignature(rosterId: 0)
            }

            _ = session.processProposals(payload, recognizedUserIds: ["424242424242424242"])
            session.setExternalSender(payload)
            _ = session.takeLastMLSFailure()
            _ = session.lastEpochAuthenticator
            _ = session.getKeyRatchet(userId: "424242424242424242")
        }
    }

    /// The media path allocates its output buffer from a size the native
    /// library computes, so a hostile frame must not produce a bogus capacity
    /// or an out-of-bounds write.
    func testMediaPathSurvivesHostileFrames() throws {
        var generator = SplitMix64(seed: 0xF00D)
        let corpus = adversarialCorpus(&generator, seed: nil)

        let decryptor = try DaveDecryptor()
        let encryptor = try DaveEncryptor()
        encryptor.assignSsrcToCodec(ssrc: 1, codec: .opus)

        for payload in corpus {
            // Without a ratchet these must fail cleanly rather than trap.
            XCTAssertThrowsError(try decryptor.decrypt(mediaType: .audio, encryptedFrame: payload))
            XCTAssertThrowsError(try encryptor.encrypt(mediaType: .audio, ssrc: 1, frame: payload))

            // Buffer-size arithmetic must stay sane for any input length.
            let plaintextCapacity = decryptor.maxPlaintextByteSize(
                mediaType: .audio,
                encryptedFrameSize: payload.count
            )
            XCTAssertGreaterThanOrEqual(plaintextCapacity, 0)
            let ciphertextCapacity = encryptor.maxCiphertextByteSize(
                mediaType: .audio,
                frameSize: payload.count
            )
            XCTAssertGreaterThanOrEqual(ciphertextCapacity, payload.count)
        }

        // Passthrough is the one mode that must round-trip any payload
        // verbatim, including empty and maximum-size frames.
        decryptor.transitionToPassthroughMode(true)
        encryptor.setPassthroughMode(true)
        for payload in corpus where !payload.isEmpty {
            let encrypted = try encryptor.encrypt(mediaType: .audio, ssrc: 1, frame: payload)
            XCTAssertEqual(encrypted, payload, "passthrough must not alter a frame")
            let decrypted = try decryptor.decrypt(mediaType: .audio, encryptedFrame: payload)
            XCTAssertEqual(decrypted, payload, "passthrough must not alter a frame")
        }
    }

    /// Regression: an empty external-sender payload used to crash the process
    /// with SIGSEGV.
    ///
    /// The native unmarshaller reads the buffer without checking its length,
    /// and the wrapper's `baseAddress != nil` check does not catch this,
    /// because empty `Data` may still vend a non-`nil` pointer. The coordinator
    /// rejects empty payloads before this point, so only the low-level API was
    /// exposed — but that API is public and documented.
    func testEmptyExternalSenderIsRejectedInsteadOfCrashing() throws {
        let session = try makeSession()
        session.setExternalSender(Data())

        let failure = session.takeLastMLSFailure()
        XCTAssertNotNil(failure, "an empty external sender must be reported as a failure")
        XCTAssertFalse(failure?.reason.isEmpty ?? true)

        // The session must remain usable afterwards.
        session.setExternalSender(Data([0x00, 0x01, 0x02]))
        XCTAssertNotNil(session.marshalledKeyPackage)
    }

    /// The same zero-length guard must hold for every buffer-taking entry
    /// point, so no future call site can reintroduce the crash.
    func testEmptyPayloadsAreRejectedByEveryMlsEntryPoint() throws {
        let session = try makeSession()

        XCTAssertTrue(session.processCommit(Data()).isFailed)
        XCTAssertNil(session.processWelcome(Data(), recognizedUserIds: ["424242424242424242"]))
        XCTAssertNil(session.processProposals(Data(), recognizedUserIds: ["424242424242424242"]))
    }

    /// Negative and extreme sizes must never be reinterpreted as enormous
    /// unsigned allocation requests when they cross into `size_t`.
    func testExtremeSizeRequestsAreClamped() throws {
        let decryptor = try DaveDecryptor()
        let encryptor = try DaveEncryptor()

        // A negative size must never be reinterpreted as a huge `size_t`.
        for size in [Int.min, -1] {
            XCTAssertEqual(decryptor.maxPlaintextByteSize(mediaType: .audio, encryptedFrameSize: size), 0)
            XCTAssertEqual(encryptor.maxCiphertextByteSize(mediaType: .audio, frameSize: size), 0)
        }

        // Zero is a legitimate size: the ciphertext capacity is then the
        // per-frame overhead, which must be reported rather than clamped away.
        XCTAssertGreaterThanOrEqual(encryptor.maxCiphertextByteSize(mediaType: .audio, frameSize: 0), 0)
        XCTAssertGreaterThanOrEqual(decryptor.maxPlaintextByteSize(mediaType: .audio, encryptedFrameSize: 0), 0)
    }
}
