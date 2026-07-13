import AppKit
import CoreTransferable
import UniformTypeIdentifiers
import WikiFSCore

/// App-layer `Transferable` conformance for `SidebarDragPayloadList`, plus the
/// pasteboard wiring. Kept out of `WikiFSCore` so the model layer stays
/// UI-framework-agnostic; the AppKit drag sources and the SwiftUI drop target
/// (both in this target) share these definitions.
extension SidebarDragPayloadList: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .wikiSidebarItem)
    }
}

extension SidebarDragPayload {
    /// An `NSPasteboardWriting` carrying this single payload (wrapped in a
    /// one-element `SidebarDragPayloadList`) as JSON, suitable for returning
    /// from an `NSTableView` pasteboard-writer callback. (`NSItemProvider` is
    /// not `NSPasteboardWriting` on this SDK, so the AppKit drag source needs a
    /// real writer object; the SwiftUI
    /// `.dropDestination(for: SidebarDragPayloadList.self)` reads the JSON back
    /// via the matching `CodableRepresentation`.)
    func makePasteboardWriter() -> NSPasteboardWriting {
        SidebarDragPasteboardItem(payloads: [self])
    }
}

extension UTType {
    /// Internal pasteboard identifier for a sidebar drag payload. The AppKit
    /// drag source writes JSON under this identifier; the SwiftUI
    /// `.dropDestination(for: SidebarDragPayload.self)` reads it back via the
    /// matching `CodableRepresentation`.
    ///
    /// Conforms to `public.item` (the root), NOT `public.data`: WKWebView and its
    /// private internal subviews auto-register broad types like `public.data` and
    /// re-register them asynchronously after load. Since AppKit routes a drag to
    /// the deepest descendant whose registered types the drag conforms to, a
    /// `public.data`-conforming payload gets intercepted by the WKWebView
    /// rendering the markdown body. A sibling under `public.item` doesn't conform
    /// to any of those broad types, so the drag bubbles past the WKWebView to the
    /// SwiftUI drop target (#133).
    static let wikiSidebarItem = UTType(
        exportedAs: "com.selfdrivingwiki.sidebar-item",
        conformingTo: .item
    )
}

/// `NSPasteboardWriting` for a sidebar drag. Carries the resolved-target
/// payloads (page/source — one per leaf, all descendants for a folder) and,
/// for bookmark rows, the node id as `.string` so the existing intra-tree
/// reorder (`BookmarksOutlineView.acceptDrop` reads
/// `pb.string(forType: .string)`) keeps working alongside the welcome-screen
/// drop. An empty bookmark folder carries no payloads (nothing to open).
final class SidebarDragPasteboardItem: NSObject {
    let payloads: [SidebarDragPayload]
    let bookmarkNodeID: String?

    init(payloads: [SidebarDragPayload] = [], bookmarkNodeID: String? = nil) {
        self.payloads = payloads
        self.bookmarkNodeID = bookmarkNodeID
    }

    private var sidebarType: NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType(UTType.wikiSidebarItem.identifier)
    }

    /// Private type for the bookmark node ID (intra-tree reorder only). Must
    /// NOT be `.string` — `.string` conforms to `public.data`, and the chat
    /// transcript's WKWebView auto-registers for `public.data`, so a bookmark
    /// drag carrying `.string` gets intercepted by the WKWebView before it can
    /// reach the composer's SwiftUI `.dropDestination`. A private type under
    /// `public.item` doesn't conform to `public.data`, so the drag bubbles past
    /// the WKWebView to the composer (issue #385).
    private var bookmarkNodeType: NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType("com.selfdrivingwiki.bookmark-node-id")
    }
}

extension SidebarDragPasteboardItem: NSPasteboardWriting {
    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types: [NSPasteboard.PasteboardType] = []
        if bookmarkNodeID != nil { types.append(bookmarkNodeType) }
        if !payloads.isEmpty { types.append(sidebarType) }
        return types
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == bookmarkNodeType { return bookmarkNodeID }
        if type == sidebarType, !payloads.isEmpty,
           let data = try? JSONEncoder().encode(SidebarDragPayloadList(payloads)) {
            return data as NSData
        }
        return nil
    }

    func writingOptions(forType type: NSPasteboard.PasteboardType,
                        pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        []
    }
}
