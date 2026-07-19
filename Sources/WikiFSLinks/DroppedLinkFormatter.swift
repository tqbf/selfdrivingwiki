import Foundation
import WikiFSTypes

/// Pure, dependency-free formatter that turns a sidebar drag-drop payload into
/// a **canonical** wikilink (`[[page:<ULID>|<alias>]]` / `[[source:<ULID>|…]]` /
/// `[[chat:<ULID>|…]]`) for insertion into the page/source editor at the drop
/// point. The output is always ULID-canonical at rest, so the Phase 5
/// `WikiLinkRewriter.canonicalize` idempotency fast-path keeps it byte-identical
/// on save — the inserted link never gets rewritten or rewritten-again.
///
/// Lives in `WikiFSLinks` (Foundation-only; depends only on `WikiFSTypes` for
/// `ParsedLink.LinkType.linkPrefix`) so the unit tests can hit it directly
/// without AppKit or the SQLite store. The view layer maps
/// `SidebarDragPayload.Kind` → `ParsedLink.LinkType` (a 1:1 trivial switch) at
/// the only place they meet — the SwiftUI representable's builder closure.
///
/// **Alias semantics.** `displayName` is the human alias (current title/name);
/// it is cosmetic only — at render time the reader resolves the ULID to the
/// current title regardless of the alias text (Phase 5 display-at-render). A
/// `nil` displayName (stale/deleted target) falls back to the raw ULID so the
/// link still resolves by id and renders as a missing/dimmed target instead
/// of silently disappearing.
public enum DroppedLinkFormatter {

    /// One row of a possibly-indented markdown list emitted by a multi-payload
    /// drop (a bookmark folder or a multi-row sidebar selection).
    ///
    /// `depth` is the list indentation level (0 = top-level, no indent; 1 =
    /// 2-space indent under a `- ` parent; etc.). v1 of the drag-insert feature
    /// passes `depth: 0` for every leaf (a flat list) — see
    /// `plans/drag-wikilinks.md` Step 3 Option B; the data shape is
    /// forward-compatible with nested indentation.
    public struct Item: Sendable, Hashable {
        public let depth: Int
        public let linkType: ParsedLink.LinkType
        public let id: String
        public let displayName: String?

        public init(depth: Int,
                    linkType: ParsedLink.LinkType,
                    id: String,
                    displayName: String?) {
            self.depth = depth
            self.linkType = linkType
            self.id = id
            self.displayName = displayName
        }
    }

    /// The wikilink prefix for a kind: `"page:"` / `"source:"` / `"chat:"`.
    /// Delegates to `ParsedLink.LinkType.linkPrefix` so there is a single source
    /// of truth for prefix strings (no inline literals).
    public static func linkPrefix(for type: ParsedLink.LinkType) -> String {
        type.linkPrefix
    }

    /// A single canonical link: `[[<kind:ULID>|<alias>]]`.
    ///
    /// - Parameters:
    ///   - type: the link kind (page/source/chat).
    ///   - id: the target's ULID (`PageID.rawValue`). Always emitted verbatim as
    ///     the canonical target so the link resolves by id at render even if the
    ///     alias is stale.
    ///   - displayName: the alias (current title/name). If `nil` OR empty, the
    ///     alias falls back to the raw `id` so the link is always well-formed
    ///     (a `[[page:ULID|]]` empty-alias shape would parse as an alias-less
    ///     link and lose the alias-at-render behavior). A page/source with a
    ///     cleared-but-not-nil title passes through `""` here; treating it as
    ///     nil is the defensive choice.
    /// - Returns: the `[[…]]` string.
    public static func link(for type: ParsedLink.LinkType,
                            id: String,
                            displayName: String?) -> String {
        let alias = (displayName?.isEmpty ?? true) ? id : displayName!
        return "[[\(linkPrefix(for: type))\(id)|\(alias)]]"
    }

    /// An indented markdown list of canonical links, one per item, joined with
    /// `\n`. Each line is `<indent>- [[<kind:ULID>|<alias>]]` where `<indent>`
    /// is 2 spaces per `depth` level (depth 0 = no indent). An empty list
    /// returns the empty string (no crash).
    public static func markdownList(for items: [Item]) -> String {
        items.map { item -> String in
            let indent = String(repeating: "  ", count: max(0, item.depth))
            let link = Self.link(for: item.linkType,
                                 id: item.id,
                                 displayName: item.displayName)
            return "\(indent)- \(link)"
        }.joined(separator: "\n")
    }

    /// Convenience: build a list from a single `(depth, linkType, id, displayName)`
    /// tuple (kept as a parameter label `tuples:` so it doesn't collide with
    /// the `Item`-struct overload's `for:` label at the call site). Useful at
    /// test seams where constructing an `Item` for every entry is noisy.
    public static func markdownList(
        forTuples items: [(depth: Int,
                           linkType: ParsedLink.LinkType,
                           id: String,
                           displayName: String?)]) -> String {
        markdownList(for: items.map { Item(depth: $0.depth,
                                           linkType: $0.linkType,
                                           id: $0.id,
                                           displayName: $0.displayName) })
    }
}
