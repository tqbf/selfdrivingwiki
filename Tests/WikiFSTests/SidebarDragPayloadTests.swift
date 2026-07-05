import Foundation
import Testing
@testable import WikiFSCore

@Test func sidebarDragPayloadRoundTripsThroughJSON_page() throws {
    let payload = SidebarDragPayload(kind: .page, id: "01JKKK PAGE")
    let encoded = try JSONEncoder().encode(payload)
    let decoded = try JSONDecoder().decode(SidebarDragPayload.self, from: encoded)

    #expect(decoded == payload)
    #expect(decoded.kind == .page)
    #expect(decoded.id == "01JKKK PAGE")
}

@Test func sidebarDragPayloadRoundTripsThroughJSON_source() throws {
    let payload = SidebarDragPayload(kind: .source, id: "01HK SOURCE")
    let encoded = try JSONEncoder().encode(payload)
    let decoded = try JSONDecoder().decode(SidebarDragPayload.self, from: encoded)

    #expect(decoded.kind == .source)
    #expect(decoded.id == "01HK SOURCE")
}

@Test func sidebarDragPayloadSelection_page() {
    let payload = SidebarDragPayload(kind: .page, id: "abc123")
    #expect(payload.selection == .page(PageID(rawValue: "abc123")))
}

@Test func sidebarDragPayloadSelection_source() {
    let payload = SidebarDragPayload(kind: .source, id: "xyz789")
    #expect(payload.selection == .source(PageID(rawValue: "xyz789")))
}

/// The pasteboard JSON carries a stable, human-readable shape: the enum cases
/// encode as their raw string ("page"/"source"), not numeric indices, so a drag
/// started by one build can be decoded by another without index drift.
@Test func sidebarDragPayloadKindEncodesAsRawString() throws {
    let payload = SidebarDragPayload(kind: .source, id: "x")
    let encoded = try JSONEncoder().encode(payload)

    guard let json = try JSONSerialization.jsonObject(with: encoded) as? [String: String] else {
        Issue.record("expected a flat string-keyed JSON object")
        return
    }
    #expect(json["kind"] == "source")
    #expect(json["id"] == "x")
}
