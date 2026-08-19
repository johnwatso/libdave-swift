import XCTest
@testable import libdave_swift

/// Locks in the native callback delivery guarantee that the wrapper's teardown
/// design depends on.
///
/// `dave.h` documents no callback timing and offers no unregister-and-drain
/// operation, so the wrapper cannot *know* that a callback will not begin after
/// its owner is destroyed — that is why callback contexts are retained as inert
/// tombstones for a grace window instead of being freed immediately.
///
/// The bundled framework's actual behaviour is stronger than its contract:
/// every callback is delivered synchronously, inside a native call, on the
/// calling thread. These tests assert that, so a future framework rebuild that
/// starts delivering callbacks asynchronously or from another thread fails here
/// — loudly, and next to this explanation — rather than silently invalidating
/// the teardown reasoning.
///
/// See `Docs/NATIVE_CALLBACK_CONTRACT.md`.
final class NativeCallbackContractTests: XCTestCase {

    /// Records where a callback was delivered relative to native calls.
    private final class DeliveryRecorder: @unchecked Sendable {
        let callingThread = Thread.current
        var insideNativeCall = false
        var ownerAlive = false

        private(set) var deliveries = 0
        private(set) var outsideNativeCall = 0
        private(set) var offCallingThread = 0
        private(set) var afterOwnerDestroyed = 0

        func record() {
            deliveries += 1
            if !insideNativeCall { outsideNativeCall += 1 }
            if Thread.current != callingThread { offCallingThread += 1 }
            if !ownerAlive { afterOwnerDestroyed += 1 }
        }

        /// Brackets a native call, so "outside a native call" means exactly
        /// that rather than merely "not during registration".
        func native<T>(_ body: () throws -> T) rethrows -> T {
            insideNativeCall = true
            defer { insideNativeCall = false }
            return try body()
        }

        func assertDeliveredSynchronously(
            _ label: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            XCTAssertGreaterThan(deliveries, 0, "\(label): no callbacks observed, so this proves nothing", file: file, line: line)
            XCTAssertEqual(outsideNativeCall, 0, "\(label): a callback was delivered outside any native call", file: file, line: line)
            XCTAssertEqual(offCallingThread, 0, "\(label): a callback was delivered on another thread", file: file, line: line)
            XCTAssertEqual(afterOwnerDestroyed, 0, "\(label): a callback was delivered after its owner was destroyed", file: file, line: line)
        }
    }

    func testMlsFailureCallbackIsDeliveredSynchronouslyOnTheCallingThread() throws {
        let recorder = DeliveryRecorder()

        for _ in 0..<150 {
            recorder.ownerAlive = true
            let session = try DaveSession(authSessionId: nil) { _, _ in recorder.record() }
            recorder.native { session.initialize(version: 1, groupId: 42, selfUserId: "424242424242424242") }
            // Malformed external-sender bytes reliably trigger the failure path.
            recorder.native { session.setExternalSender(Data([0x01, 0x02, 0x03, 0x04, 0x05])) }
            recorder.ownerAlive = false
        }

        recorder.assertDeliveredSynchronously("MLS failure callback")
    }

    func testEncryptorVersionCallbackIsDeliveredSynchronouslyOnTheCallingThread() throws {
        let recorder = DeliveryRecorder()

        for _ in 0..<150 {
            recorder.ownerAlive = true
            let encryptor = try DaveEncryptor()
            recorder.native { encryptor.setProtocolVersionChangedCallback { recorder.record() } }
            recorder.native { encryptor.setPassthroughMode(true) }
            recorder.native { encryptor.assignSsrcToCodec(ssrc: 1, codec: .opus) }
            _ = recorder.native { try? encryptor.encrypt(mediaType: .audio, ssrc: 1, frame: Data([0x01])) }
            _ = recorder.native { encryptor.protocolVersion }
            recorder.ownerAlive = false
        }

        recorder.assertDeliveredSynchronously("encryptor protocol-version callback")
    }

    func testFingerprintCallbackIsDeliveredSynchronouslyOnTheCallingThread() throws {
        let recorder = DeliveryRecorder()
        let session = try DaveSession(authSessionId: nil) { _, _ in }
        session.initialize(version: 1, groupId: 42, selfUserId: "424242424242424242")

        recorder.ownerAlive = true
        for _ in 0..<150 {
            recorder.native {
                session.getPairwiseFingerprint(version: 1, userId: "515151515151515151") { _ in
                    recorder.record()
                }
            }
        }
        recorder.ownerAlive = false

        recorder.assertDeliveredSynchronously("pairwise fingerprint callback")
    }

    /// The tombstone table must stay bounded no matter how the guarantee above
    /// evolves: this is the property that makes the current design safe to keep
    /// until the C API offers unregister-and-drain.
    func testCallbackContextsRemainBoundedAcrossOwnerChurn() throws {
        for _ in 0..<400 {
            let session = try DaveSession(authSessionId: nil) { _, _ in }
            session.initialize(version: 1, groupId: 42, selfUserId: "424242424242424242")
        }
        XCTAssertLessThanOrEqual(DaveNativeCallbackContextRetainer.shared.retainedContextCount, 512)
    }
}
