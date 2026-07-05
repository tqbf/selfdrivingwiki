import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import WikiFSCore
@testable import WikiFS

/// Verifies the AppKit→SwiftUI drag bridge at the pasteboard level: an
/// `NSPasteboardWriting` produced by the sidebar lists must put valid JSON under
/// the sidebar-item type identifier (so SwiftUI's `.dropDestination(for:)` can
/// decode it), and the bookmark writer must keep the `.string` node id for
/// intra-tree reorder alongside the payload.
@MainActor
struct SidebarDragPasteboardBridgeTests {

    private func write(_ writer: NSPasteboardWriting) -> NSPasteboard {
        let pb = NSPasteboard(name: .init("sidebar-drag-test"))
        pb.clearContents()
        pb.writeObjects([writer])
        return pb
    }

    private var sidebarType: NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType(UTType.wikiSidebarItem.identifier)
    }

    @Test func pageWriterRoundTripsThroughPasteboard() throws {
        let payload = SidebarDragPayload(kind: .page, id: "page-1")
        let pb = write(payload.makePasteboardWriter())

        let data = try #require(pb.data(forType: sidebarType))
        let decoded = try JSONDecoder().decode(SidebarDragPayloadList.self, from: data)
        #expect(decoded.items == [payload])
        // A page row must not advertise a reorder id (no bookmark node).
        #expect(pb.string(forType: .string) == nil)
    }

    @Test func sourceWriterRoundTripsThroughPasteboard() throws {
        let payload = SidebarDragPayload(kind: .source, id: "src-9")
        let pb = write(payload.makePasteboardWriter())

        let decoded = try JSONDecoder().decode(
            SidebarDragPayloadList.self,
            from: try #require(pb.data(forType: sidebarType))
        )
        #expect(decoded.items == [payload])
    }

    @Test func bookmarkRefCarriesBothNodeIDAndPayload() throws {
        let payload = SidebarDragPayload(kind: .page, id: "page-7")
        let pb = write(SidebarDragPasteboardItem(payloads: [payload], bookmarkNodeID: "node-42"))

        // Intra-tree reorder reads this (BookmarksOutlineView.acceptDrop).
        #expect(pb.string(forType: .string) == "node-42")
        // The welcome-screen drop reads this.
        let decoded = try JSONDecoder().decode(
            SidebarDragPayloadList.self,
            from: try #require(pb.data(forType: sidebarType))
        )
        #expect(decoded.items == [payload])
    }

    @Test func bookmarkFolderCarriesNodeIDOnly() {
        // An empty folder has nothing to open, so it carries only the reorder id.
        let pb = write(SidebarDragPasteboardItem(payloads: [], bookmarkNodeID: "folder-1"))

        #expect(pb.string(forType: .string) == "folder-1")
        #expect(pb.data(forType: sidebarType) == nil)
    }

    @Test func bookmarkFolderCarriesAllDescendantPayloads() throws {
        // A non-empty folder carries every descendant's resolved target.
        let page = SidebarDragPayload(kind: .page, id: "page-in-folder")
        let source = SidebarDragPayload(kind: .source, id: "src-in-folder")
        let pb = write(SidebarDragPasteboardItem(payloads: [page, source], bookmarkNodeID: "folder-2"))

        let decoded = try JSONDecoder().decode(
            SidebarDragPayloadList.self,
            from: try #require(pb.data(forType: sidebarType))
        )
        #expect(decoded.items == [page, source])
    }

    @Test func bookmarkRefResolvesToSourceTarget() throws {
        // A sourceRef bookmark must resolve to kind=.source in the payload.
        let payload = SidebarDragPayload(kind: .source, id: "src-3")
        let pb = write(SidebarDragPasteboardItem(payloads: [payload], bookmarkNodeID: "node-99"))

        let decoded = try JSONDecoder().decode(
            SidebarDragPayloadList.self,
            from: try #require(pb.data(forType: sidebarType))
        )
        #expect(decoded.items.first?.kind == .source)
    }
}
