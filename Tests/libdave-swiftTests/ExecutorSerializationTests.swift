import XCTest
import Dispatch
@testable import libdave_swift

/// The coordinator promises that all native MLS work is serialized onto one
/// dedicated queue: that promise is what makes the (not thread-safe) native
/// session safe to use, and what keeps a wedged native call from starving the
/// host's shared cooperative thread pool.
///
/// This verifies the promise directly, which also documents why the thread
/// sanitizer job builds against the default actor executor: the sanitizer
/// cannot see the happens-before edges of the custom-executor enqueue path,
/// but the serialization it reports as unsafe is demonstrably real here.
final class ExecutorSerializationTests: XCTestCase {
    func testConcurrentActorWorkIsSerializedOnTheDedicatedQueue() async throws {
        let coordinator = DaveSessionCoordinator()
        try await coordinator.configureForDiscordVoice(
            groupId: 1234,
            selfUserId: "424242424242424242",
            protocolVersion: 1
        )

        let callers = 200
        let incrementsPerCaller = 1_000

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<callers {
                group.addTask {
                    await coordinator.recordExecutorSerializationProbe(increments: incrementsPerCaller)
                }
            }
        }

        let probe = await coordinator.executorSerializationProbe()
        XCTAssertEqual(probe.maxConcurrentEntries, 1, "actor work overlapped: the executor is not serializing")
        XCTAssertEqual(
            probe.nonAtomicCounter,
            callers * incrementsPerCaller,
            "lost updates: non-atomic actor state was mutated concurrently"
        )

#if !DAVE_DEFAULT_ACTOR_EXECUTOR
        // `recordExecutorSerializationProbe` asserts `dispatchPrecondition`
        // internally; reaching here at all means every call ran on the
        // dedicated queue rather than the shared cooperative pool.
        XCTAssertFalse(probe.ranOffDedicatedQueue)
#endif
    }
}
