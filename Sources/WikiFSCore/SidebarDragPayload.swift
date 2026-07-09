import Foundation

/// Internal drag payload for a sidebar row dragged onto the welcome screen
/// (issue #133). Carries just enough to resolve the drop to a `WikiSelection`:
/// a kind (page, source, or chat) and the target's stable id.
///
/// This type lives in the model layer (no `Transferable` conformance here) so it
/// can be unit-tested directly; the app layer adds the `Transferable` conformance
/// plus the pasteboard wiring. It is `Codable` so the AppKit drag source and the
/// SwiftUI drop destination round-trip the value through JSON on the pasteboard.
///
/// Bookmarks are not a kind here: a bookmark row resolves to whatever it points at
/// (a page or a source) at drag-start time, then carries that resolved kind+id —
/// so the drop target doesn't need to know bookmarks exist.
public struct SidebarDragPayload: Codable, Sendable, Hashable {
    public enum Kind: String, Sendable, Codable {
        case page
        case source
        case chat
    }

    /// Whether the target is a page, a source, or a chat.
    public let kind: Kind
    /// `PageID.rawValue` of the target page/source/chat.
    public let id: String

    public init(kind: Kind, id: String) {
        self.kind = kind
        self.id = id
    }

    /// The selection the drop target should open.
    public var selection: WikiSelection {
        let pageID = PageID(rawValue: id)
        switch kind {
        case .page:   return .page(pageID)
        case .source: return .source(pageID)
        case .chat:   return .chat(pageID)
        }
    }
}

/// The full set of targets a single dragged sidebar row resolves to. Most rows
/// (a page/source, or a bookmark pointing at one) resolve to exactly one
/// target; a bookmark folder resolves to every page/source reachable
/// underneath it, so dropping a folder opens all of its contents as tabs.
///
/// Every dragged row — leaf or folder — is encoded as one of these (a
/// single-element list for leaves) so the drop targets only need to handle one
/// shape.
public struct SidebarDragPayloadList: Codable, Sendable, Hashable {
    public let items: [SidebarDragPayload]

    public init(_ items: [SidebarDragPayload]) {
        self.items = items
    }
}
