import Foundation
import XCTest
@testable import libdave_swift

final class RosterDeltaTests: XCTestCase {
    func testCommitRosterDeltaPreservesUnchangedMembersAndRemovesEmptySignatures() async throws {
        let coordinator = DaveSessionCoordinator()

        try await coordinator.applyRoster([11, 22]) { memberId in
            Data([UInt8(memberId)])
        }
        try await coordinator.applyRosterDelta([22, 33]) { memberId in
            memberId == 22 ? nil : Data([0x33])
        }

        let roster = await coordinator.currentRoster()
        let retainedSignature = await coordinator.rosterMemberSignature(for: "11")
        let removedSignature = await coordinator.rosterMemberSignature(for: "22")
        let addedSignature = await coordinator.rosterMemberSignature(for: "33")
        XCTAssertEqual(roster, ["11", "33"])
        XCTAssertEqual(retainedSignature, Data([11]))
        XCTAssertNil(removedSignature)
        XCTAssertEqual(addedSignature, Data([0x33]))
    }
}
