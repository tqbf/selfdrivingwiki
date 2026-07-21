import Foundation
import WikiFSCore
import WikiFSLinks
import WikiFSSearch

/// `@MainActor` factory that builds the editor drop-insertion `String` for a
/// sidebar drag-drop from the live `WikiStoreModel`. Handed to
/// `ScrollableTextEditor.sidebarDropBuilder`; kept separate from the
/// `DropLinkTextView` AppKit subclass (which does only pasteboard decoding +
/// insertion) so the pure `DroppedLinkFormatter` (linkPrefix / link / markdownList)
/// and the store-touching builder are each independently testable.
///
/// The builder resolves every payload's display name via
/// `store.resolveAttachmentName(for:)`, then routes:
///   - a single payload → one `[[kind:<ULID>|<alias>]]` line;
///   - 2+ payloads (a multi-row sidebar selection OR a bookmark folder's leaf
///     list, both of which arrive as multiple pasteboard items that the editor
///     flattens) → a flat depth-0 markdown list, one
///     `- [[kind:<ULID>|<alias>]]` per line, joined with `\n`.
///
/// v1 ships Option B (flat list for folders — no nested indentation). See
/// `plans/drag-wikilinks.md` Step 3: the bookmark drag source already flattens
/// a folder into a leaf-payload list (`BookmarksOutlineView.leafPayloads(under:)`);
/// the builder treats any multi-payload drop uniformly. Nested indentation
/// (Step 3 Option A — depth-aware payloads) is a documented follow-up; the
/// `DroppedLinkFormatter.markdownList(for:)` `Item.depth` field is already
/// forward-compatible with it.
@MainActor
enum SidebarDropBuilder {

    /// Build the insertion text for a flattened payload list, or return `nil`
    /// to reject the drop. The drop is rejected when:
    ///   - an agent is mid-generation into this wiki (`store.agentRunCount > 0`)
    ///     — never silently insert into a buffer an agent is about to overwrite;
    ///   - the payload list is empty (an empty bookmark folder, or a stale drag).
    /// Each rejected case is logged via `DebugLog.editor` (os_log → Console.app)
    /// so a missing drop is debuggable; the user sees nothing — silent rejection
    /// beats a partial-insert / clobbered by agent UX.
    ///
    /// Stale targets (the payload resolved to `nil` display name) are NOT
    /// rejected: the formatter falls back to the raw ULID as the alias so the
    /// link still resolves by id at render (and renders dimmed as a missing
    /// target). Dropping a link to a just-deleted page is correct behavior.
    static func insertionText(for payloads: [SidebarDragPayload],
                              store: WikiStoreModel) -> String? {
        guard !payloads.isEmpty else {
            DebugLog.editor("[drop] sidebar drop rejected: no payloads (empty folder / stale drag)")
            return nil
        }
        guard store.agentRunCount == 0 else {
            DebugLog.editor("[drop] sidebar drop rejected: agent run in progress (agentRunCount=\(store.agentRunCount))")
            return nil
        }

        // One payload → a single inline `[[kind:ULID|alias]]`.
        if payloads.count == 1, let payload = payloads.first {
            let displayName = store.resolveAttachmentName(for: payload)
            let type = Self.linkType(for: payload.kind)
            return DroppedLinkFormatter.link(for: type,
                                             id: payload.id,
                                             displayName: displayName)
        }

        // 2+ payloads → a flat depth-0 markdown list, one line per target.
        // v1 Option B: the folder's leaf list is already flat (no depth info
        // survives the pasteboard), so every item is at depth 0. Nested
        // indentation is a documented follow-up; the formatter signature is
        // forward-compatible.
        let items: [DroppedLinkFormatter.Item] = payloads.map { payload in
            DroppedLinkFormatter.Item(
                depth: 0,
                linkType: Self.linkType(for: payload.kind),
                id: payload.id,
                displayName: store.resolveAttachmentName(for: payload))
        }
        return DroppedLinkFormatter.markdownList(for: items)
    }

    /// 1:1 map between the sidebar payload kind and the link cluster's
    /// `ParsedLink.LinkType`. There is already a `dragKind(for:)` going the
    /// other way at `BookmarksOutlineView.swift:362-369`; this is its inverse.
    /// Both enum cases share their rawValue ("page"/"source"/"chat") so
    /// `ParsedLink.LinkType(rawValue:)` would also work, but the explicit switch
    /// fails closed at compile time if a new kind is added to either side.
    static func linkType(for kind: SidebarDragPayload.Kind) -> ParsedLink.LinkType {
        switch kind {
        case .page:   return .page
        case .source: return .source
        case .chat:   return .chat
        }
    }

    // MARK: - Wiki-link autocomplete hooks (issue #680)

    /// Build the chat-composer-style autocomplete hooks (`fetch` + `format`)
    /// for the page/source **markdown editor** from the live Tantivy search
    /// service. Returns `nil` when no Tantivy service is attached (no wiki
    /// open) — the editor then behaves exactly as before autocomplete was
    /// added.
    ///
    /// Reuses the same Tantivy fuzzy `search.autocomplete(partial:kinds:...)`
    /// path the chat composer uses (`ChatDetailView.chatAutocompleteHooks` at
    /// `Sources/WikiFS/Chats/ChatDetailView.swift:736`), and the same canonical-form
    /// `DroppedLinkFormatter.link(...)` builder the sidebar-drop insertion
    /// uses (#616). The two pure kind-mapping helpers
    /// (`WikiLinkAutocompleteController.tantivyKind(for:)` /
    /// `.parsedLinkType(from:)`) live on the controller so they're next to
    /// their only non-ChatDetailView caller — kept as `nonisolated static` to be
    /// test-reachable.
    static func wikiLinkAutocompleteHooks(
        store: WikiStoreModel
    ) -> WikiLinkAutocompleteHooks? {
        guard let search = store.tantivySearch else { return nil }
        return WikiLinkAutocompleteHooks(
            fetch: { partial, kind in
                let tantivyKind = WikiLinkAutocompleteController.tantivyKind(for: kind)
                return await search.autocomplete(
                    partial: partial,
                    kinds: [tantivyKind],
                    distance: 2,
                    limit: 8)
            },
            format: { hit in
                // Map the search hit back to a ParsedLink.LinkType for the
                // formatter (single source of truth for the `[[kind:ULID|…]]`
                // prefix string).
                let linkType = WikiLinkAutocompleteController.parsedLinkType(from: hit.kind)
                return DroppedLinkFormatter.link(
                    for: linkType,
                    id: hit.ulid,
                    displayName: hit.title)
            }
        )
    }
}
