import Foundation

/// Internal drag payload for a sidebar row dragged onto the welcome screen
/// (issue #133). Carries just enough to resolve the drop to a `WikiSelection`:
/// a kind (page or source) and the target's stable id.
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
    }

    /// Whether the target is a page or a source.
    public let kind: Kind
    /// `PageID.rawValue` of the target page/source.
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
        }
    }
}
