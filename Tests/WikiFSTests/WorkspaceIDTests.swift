import Foundation
import Testing
@testable import WikiFSTypes

struct WorkspaceIDTests {
    @Test func codableShapeMatchesRawString() throws {
        let workspaceID = WorkspaceID(rawValue: "01J-WORKSPACE")
        let encoded = try JSONEncoder().encode(workspaceID)
        let rawValue = try JSONDecoder().decode(String.self, from: encoded)
        let decoded = try JSONDecoder().decode(WorkspaceID.self, from: encoded)

        #expect(rawValue == workspaceID.rawValue)
        #expect(decoded == workspaceID)
    }

    @Test func rawValueAndIdentityArePreserved() {
        let workspaceID = WorkspaceID(rawValue: "01J-WORKSPACE")

        #expect(workspaceID.rawValue == "01J-WORKSPACE")
        #expect(workspaceID.id == "01J-WORKSPACE")
    }

    @Test func hashAndEqualityFollowRawValue() {
        let ids: Set<WorkspaceID> = [
            WorkspaceID(rawValue: "same-workspace"),
            WorkspaceID(rawValue: "same-workspace"),
            WorkspaceID(rawValue: "other-workspace"),
        ]

        #expect(ids.count == 2)
        #expect(WorkspaceID(rawValue: "same-workspace") == WorkspaceID(rawValue: "same-workspace"))
        #expect(WorkspaceID(rawValue: "same-workspace") != WorkspaceID(rawValue: "other-workspace"))
    }
}
