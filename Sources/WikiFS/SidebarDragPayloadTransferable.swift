import AppKit
import CoreTransferable
import UniformTypeIdentifiers
import WikiFSCore

/// App-layer `Transferable` conformance for `SidebarDragPayload`, plus the
/// pasteboard wiring. Kept out of `WikiFSCore` so the model layer stays
/// UI-framework-agnostic; the AppKit drag sources and the SwiftUI drop target
/// (both in this target) share these definitions.
extension SidebarDragPayload: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .wikiSidebarItem)
    }

    /// An `NSPasteboardWriting` carrying this payload as JSON, suitable for
    /// returning from an `NSTableView`/`NSOutlineView` pasteboard-writer
    /// callback. (`NSItemProvider` is not `NSPasteboardWriting` on this SDK, so
    /// the AppKit drag source needs a real writer object; the SwiftUI
    /// `.dropDestination(for: SidebarDragPayload.self)` reads the JSON back via
    /// the matching `CodableRepresentation`.)
    func makePasteboardWriter() -> NSPasteboardWriting {
        SidebarDragPasteboardItem(payload: self)
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

/// `NSPasteboardWriting` for a sidebar drag. Carries the resolved-target payload
/// (page/source) and, for bookmark rows, the node id as `.string` so the existing
/// intra-tree reorder (`BookmarksOutlineView.acceptDrop` reads
/// `pb.string(forType: .string)`) keeps working alongside the welcome-screen
/// drop. Bookmark folders pass a nil payload (no target to open).
final class SidebarDragPasteboardItem: NSObject {
    let payload: SidebarDragPayload?
    let bookmarkNodeID: String?

    init(payload: SidebarDragPayload? = nil, bookmarkNodeID: String? = nil) {
        self.payload = payload
        self.bookmarkNodeID = bookmarkNodeID
    }

    private var sidebarType: NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType(UTType.wikiSidebarItem.identifier)
    }
}

extension SidebarDragPasteboardItem: NSPasteboardWriting {
    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types: [NSPasteboard.PasteboardType] = []
        if bookmarkNodeID != nil { types.append(.string) }
        if payload != nil { types.append(sidebarType) }
        return types
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .string { return bookmarkNodeID }
        if type == sidebarType, let payload,
           let data = try? JSONEncoder().encode(payload) {
            return data as NSData
        }
        return nil
    }

    func writingOptions(forType type: NSPasteboard.PasteboardType,
                        pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        []
    }
}
