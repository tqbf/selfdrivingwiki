import Foundation

/// The vocabulary of resource kinds — the single declaration point a new kind
/// adds. Shared by the event bus (the `kind` on a `ResourceChangeEvent`), the
/// `changeToken` contributor registry, and (Phase B+) the projection descriptor
/// registry. Extensible: `chat` (#119) and others are added as cases here.
///
/// Re-homed here from `WikiEventBus.swift` in slice 2b so the kind vocabulary
/// has a single home that both the contributor registry and the bus reference
/// (the bus is one *consumer* of kinds, not their home).
///
/// Lives in `WikiFSTypes` (the shared leaf target) so both the link cluster
/// (`ParsedLink.LinkType.resourceKind`) and the store/event-bus can reference it
/// without a circular dependency (module restructuring Phase 1, #532).
public enum ResourceKind: String, Codable, Sendable, CaseIterable {
    case page, source, systemPrompt, wikiIndex, log, bookmark, chat

    /// The SF Symbol name used for this resource kind across every UI surface:
    /// sidebar sections, detail-view headers, the omnibox icon, bookmark row
    /// icons, source list rows, and the picker sheet. Centralized here so a
    /// kind's icon can't drift between surfaces.
    public var systemImageName: String {
        switch self {
        case .page:        "doc.text"
        case .source:      "tray.full"
        case .bookmark:    "bookmark"
        case .chat:        "bubble.left.and.bubble.right"
        case .systemPrompt: "doc.text"
        case .wikiIndex:   "book.closed"
        case .log:         "clock.arrow.circlepath"
        }
    }

    /// The `[[kind:Target]]` wiki-link prefix for linkable kinds:
    /// `"page:"`, `"source:"`, `"chat:"`, `"bookmark:"`.
    ///
    /// Returns `nil` for non-linkable kinds (`systemPrompt`, `wikiIndex`,
    /// `log`) that have no wiki-link syntax. This is the single source of
    /// truth for link-kind prefix strings — inline literals should never be
    /// re-derived at call sites (#489).
    public var linkPrefix: String? {
        switch self {
        case .page, .source, .chat, .bookmark: return "\(rawValue):"
        case .systemPrompt, .wikiIndex, .log: return nil
        }
    }
}

/// How a resource changed.
public enum ChangeKind: String, Codable, Sendable {
    case created, updated, deleted
}

/// A thin, serializable description of one resource change. Store-owned
/// producers emit it locally through `WikiEventBus`; persisted renderer journals
/// use the same value in `WikiStoreChangeEvent.resource` when they need to carry
/// a resource-shaped payload without depending on WikiFSCore.
public struct ResourceChangeEvent: Codable, Sendable, Equatable, Hashable {
    public let wikiID: WikiID
    public let kind: ResourceKind?
    public let id: String
    public let change: ChangeKind
    public let seq: UInt64

    public init(
        wikiID: WikiID,
        kind: ResourceKind?,
        id: String,
        change: ChangeKind,
        seq: UInt64 = 0
    ) {
        self.wikiID = wikiID
        self.kind = kind
        self.id = id
        self.change = change
        self.seq = seq
    }
}
