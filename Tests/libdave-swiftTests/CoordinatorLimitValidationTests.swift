import Foundation
import XCTest
@testable import libdave_swift

final class CoordinatorLimitValidationTests: XCTestCase {
    func testMutatingLimitsCannotBypassResourceBounds() {
        var limits = DaveCoordinatorLimits.default

        limits.maximumMlsPayloadBytes = 0
        limits.maximumRosterMembers = -1
        limits.maximumMediaFrameBytes = Int.min
        limits.maximumTrackedTransitions = 0
        limits.maximumPendingOutboundActions = -100
        limits.mediaReadinessTimeout = .infinity
        limits.traceEventCapacity = Int.max
        limits.diagnosticEventBufferSize = Int.max

        XCTAssertEqual(limits.maximumMlsPayloadBytes, 1)
        XCTAssertEqual(limits.maximumRosterMembers, 1)
        XCTAssertEqual(limits.maximumMediaFrameBytes, 1)
        XCTAssertEqual(limits.maximumTrackedTransitions, 1)
        XCTAssertEqual(limits.maximumPendingOutboundActions, 1)
        XCTAssertEqual(limits.mediaReadinessTimeout, 0)
        XCTAssertEqual(limits.traceEventCapacity, DaveCoordinatorLimits.maximumTraceEventCapacity)
        XCTAssertEqual(
            limits.diagnosticEventBufferSize,
            DaveCoordinatorLimits.maximumDiagnosticEventBufferSize
        )
    }

    func testDecodedLimitsPassThroughValidatedInitializer() throws {
        let encoded = Data(
            """
            {
              "maximumMlsPayloadBytes": 0,
              "maximumRosterMembers": -2,
              "maximumMediaFrameBytes": -3,
              "maximumTrackedTransitions": 0,
              "maximumPendingOutboundActions": -5,
              "mediaReadinessTimeout": -10,
              "unrecognizedRosterMemberPolicy": "report",
              "traceEventCapacity": 999999,
              "diagnosticEventBufferSize": 999999
            }
            """.utf8
        )

        let limits = try JSONDecoder().decode(DaveCoordinatorLimits.self, from: encoded)

        XCTAssertEqual(limits.maximumMlsPayloadBytes, 1)
        XCTAssertEqual(limits.maximumRosterMembers, 1)
        XCTAssertEqual(limits.maximumMediaFrameBytes, 1)
        XCTAssertEqual(limits.maximumTrackedTransitions, 1)
        XCTAssertEqual(limits.maximumPendingOutboundActions, 1)
        XCTAssertEqual(limits.mediaReadinessTimeout, 0)
        XCTAssertEqual(limits.traceEventCapacity, DaveCoordinatorLimits.maximumTraceEventCapacity)
        XCTAssertEqual(
            limits.diagnosticEventBufferSize,
            DaveCoordinatorLimits.maximumDiagnosticEventBufferSize
        )
    }

    func testExplicitInfiniteWatchdogTimeoutFailsClosedWithoutDurationTrap() async throws {
        let coordinator = DaveSessionCoordinator()
        try await coordinator.configureForDiscordVoice(
            groupId: 7_701,
            selfUserId: "424242424242424242",
            protocolVersion: 1
        )

        let status = await coordinator.markDiscordMediaNotReady(
            reason: "invalid timeout regression",
            timeout: .infinity
        )

        guard case .timedOut = status else {
            return XCTFail("a non-finite timeout must become an immediate fail-closed deadline")
        }
    }
}
