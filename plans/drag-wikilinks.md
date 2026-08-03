# Drag sidebar items into the page/source editor to auto-insert wikilinks

**Status:** Plan (implementation-ready). Scope: in-app drag only (v1).
**Repo file (committed by implementer):** copy this file to `plans/drag-wikilinks.md` on the feature branch's first commit.

## Problem statement

When editing a page or source in markdown edit mode, the user wants to **drag an
item from the sidebar** (a Page, Source, Chat, or a Bookmark folder) into the
editor textarea and have a **canonical wikilink inserted at the drop point**,
typed by what was dragged:

| Dropped type        | Inserts                                                                       |
|---------------------|-------------------------------------------------------------------------------|
| **Source**          | `[[source:<ULID>\|<displayName>]]` (canonical ULID-pinned form)               |
| **Page**            | `[[page:<ULID>\|<Title>]]` (canonical ULID-pinned form)                       |
| **Bookmark folder** | A **nested markdown list** of canonical links (one `- ` line per leaf target, indented 2 spaces per folder nesting level) |
| **Chat**            | `[[chat:<ULID>\|<Title>]]` (canonical ULID-pinned form)                       |

Single non-folder drops produce one link on the current line at the drop point.
A folder (or a multi-row sidebar selection) produces a multi-line indented list,
each line `- [[kind:<ULID>\|<name>]]`, with the tree depth of the folder
mirrored by list indentation.

### Why canonical ULID-pinned form (not `[[source:Name]]`)

Phase 5 link canonicalization (`plans/phase-5-link-canonicalization.md`,
`Sources/WikiFSLinks/WikiLinkRewriter.swift`) makes **every resolvable link
ULID-canonical at rest**: `[[page:<ULID>|alias]]` / `[[source:<ULID>|alias]]` /
`[[chat:<ULID>|alias]]`. The same write seam (`PageUpsert.upsert`,
`Sources/WikiFSCore/Core/PageUpsert.swift:67-70`) calls `WikiLinkRewriter.canonicalize`
with `resolvePage` / `resolveSource` / `resolveChat: store.resolveChatByTitle`.

If the drop inserts the **human form** `[[source:Name]]`, the rewriter rewrites it
to `[[source:<ULID>|Name]]` on the next explicit Save (correct, but a second
pass). If the drop inserts the **canonical form directly**
`[[source:<ULID>|Name]]`, the rewriter's idempotency fast-path
(`WikiLinkRewriter.swift:69`, `isCanonicalULID` → skip) leaves it untouched, and
the alias survives (self-heals to the current name at render per Phase 5 AC.5).
So **inserting the canonical form is both the most robust and the lowest-churn
choice**, and matches the operator's explicit "page → `[[page:ULID|Title]]`"
request. Standardize on `[[<kind:prefix><ULID>|<displayName>]]` for all three
single-target types (page/source/chat).

> The operator's table allowed `[[source:Name]]` as an alternative for sources.
> This plan recommends the canonical ULID form for consistency with pages/chats
> and rename-safety. If the implementer prefers the human form for sources, it is
> also valid (the rewriter will canonicalize on save) — but `[[source:ULID|name]]`
> is the recommended default.

---

## Key existing infrastructure (read these before implementing)

### Editor surface (the drop target)

Both editors use the **same** `NSViewRepresentable` wrapping an `NSTextView`:

- **Page edit mode:** `Sources/WikiFS/Pages/PageDetailView.swift:273-287`
  (`editorContent` → `ScrollableTextEditor(text: $store.draftBody, ...)`).
  Read-only mode (`readerContent`, :289) uses `WikiReaderView` (WKWebView) —
  **already** accepts sidebar drops and opens a tab (`WikiReaderView.swift:384-404`);
  do NOT touch read mode.
- **Source markdown edit mode:** `Sources/WikiFS/Sources/SourceDetailView.swift:870-883`
  (`markdownContent` → `ScrollableTextEditor(text: $editBuffer, ...)`).
  Confirmed there IS a source markdown editor (Phase C source markdown projection).
  Read mode (`WikiReaderView`, :884) is unaffected.

The control itself: `Sources/WikiFS/Editor/ScrollableTextEditor.swift`
- `makeConfiguredTextView(font:)` (:95) builds the `NSTextView`.
- `Coordinator` (:131) is the `NSTextViewDelegate`; `textDidChange` (:143)
  forwards `textView.string` → `parent.text` binding. **Any insertion we do on
  the NSTextView via `replaceCharacters(in:with:)` will fire `textDidChange` →
  the `@Binding` updates → the view's `store.draftBody` (page) / `editBuffer`
  (source) updates.** That is the same flow as typing — no extra plumbing to mark
  the buffer dirty. Explicit-save is preserved (page edits are explicit-save per
  `plans/dirty-editor-protection.md`; dropping a link just dirties the buffer).

> There is **no WKWebView-based editor**. The WKWebView-in-test gotchas
> (`docs/skills/reproducing-live-ui-bugs/SKILL.md`) do NOT apply to the editor
> drop — the editor is a vanilla `NSTextView` and can be hosted in an `NSWindow`
> test directly.

### Sidebar drag sources (already complete — do NOT re-vendor)

The sidebar already vends draggable items for all four kinds via a shared
pasteboard type. **No new `NSItemProvider` / `.onDrag` work is needed.** Sources:

| Sidebar list        | Vending site (file:line)                                                |
|---------------------|-------------------------------------------------------------------------|
| Pages               | `Sources/WikiFS/Pages/PagesListView.swift:226`                          |
| Sources             | `Sources/WikiFS/Sources/SourcesListView.swift:343`                      |
| Chats               | `Sources/WikiFS/Chats/ChatsListView.swift:202`                          |
| Bookmarks (leaf+folder) | `Sources/WikiFS/Bookmarks/BookmarksOutlineView.swift:332-347`       |
| Omnibox/address bar | `Sources/WikiFS/Editor/AddressBarView.swift:250-258` (also draggable)  |

Each returns `SidebarDragPayload(kind:id:).makePasteboardWriter()`. A bookmark
**folder** returns `leafPayloads(under:)` — a flat list of every leaf target
reachable underneath it (`BookmarksOutlineView.swift:343,351-358`).
A multi-row sidebar selection produces multiple pasteboard items (each a
`SidebarDragPayloadList`); the drop handler must flatten across all of them
(see the existing pattern at `WikiReaderView.swift:406-416`,
`sidebarPayloads(from:)`).

### The drag payload + pasteboard type (the shared contract)

- **Payload:** `SidebarDragPayload { kind: Kind (.page/.source/.chat);
  id: String }` — `id` IS the `PageID.rawValue` (the Crockford-base32 ULID).
  Defined `Sources/WikiFSCore/Core/SidebarDragPayload.swift:15-41`. A list of
  them is `SidebarDragPayloadList` (`:51`). Also has `.selection` → `WikiSelection`.
- **Pasteboard type:** `UTType.wikiSidebarItem`
  (`com.selfdrivingwiki.sidebar-item`, conforming to `.item` **not** `.data`).
  Defined `Sources/WikiFS/Window/SidebarDragPayloadTransferable.swift:43-46`.
  **Critical:** the `.item`-not-`.data` conformance is deliberate — WKWebView and
  `NSTextView` auto-register broad types like `public.data`; a `public.data`-
  conforming payload gets intercepted by subviews. A sibling under `public.item`
  does not conform to those, so the drag bubbles to the right target (`#133`,
  `#385`). The editor's `NSTextView` must register only `wikiSidebarItem`.
- **Writer:** `SidebarDragPasteboardItem` (`SidebarDragPayloadTransferable.swift:55`)
  also carries a private `bookmark-node-id` type for intra-tree reorder, which the
  editor must IGNORE (only read the `wikiSidebarItem` JSON).

### Display-name resolution (for the alias)

`Sources/WikiFSCore/Store/WikiStoreModel.swift:608-618` —
`resolveAttachmentName(for: SidebarDragPayload) -> String?`:
- `.page` → `summaries.first { $0.id == pageID }?.title`
- `.source` → `sources.first { $0.id == pageID }?.effectiveName`
- `.chat` → `chats.first { $0.id == pageID }?.title`

Returns `nil` for a stale/deleted target. Fallback to the raw ULID string (or
skip emitting) — see the pure-function contract below.

### Link-prefix source of truth

`ParsedLink.LinkType.linkPrefix` (`Sources/WikiFSTypes/ParsedLink.swift:29-32`)
exposes `"page:"` / `"source:"` / `"chat:"`, delegating to `ResourceKind.linkPrefix`.
The `SidebarDragPayload.Kind` cases are a 1:1 match for `ParsedLink.LinkType`
(.page/.source/.chat); map between them with a trivial switch (there is already a
`dragKind(for:)` going the other way at `BookmarksOutlineView.swift:362-369`).

### Bookmarks tree walk (for the nested folder list)

`BookmarksOutlineView` keeps the tree flat in `store.bookmarkNodes` and groups by
parent via a `childrenMap`:
- `children(of parentID:) -> [BookmarkNode]` (`BookmarksOutlineView.swift:241`)
- `title(for node:) -> String` (`:245`) — folder→label, leaf→resolved title via
  `store.summaries`/`sources`/`chats`

`BookmarkNode` is a model type with fields: `id`, `kind`
(`BookmarkNodeKind`: `.folder` / `.pageRef` / `.sourceRef` / `.chatRef`),
`targetID: PageID?`, `label: String?`, `parentID`. The existing
`leafPayloads(under:)` (`:351`) flattens a folder into `[SidebarDragPayload]`
**but discards depth** — for the nested-list feature we need a depth-aware walk
(see implementation step §3).

### Existing precedent that builds wikilinks from a payload (reference, NOT to copy directly)

`Sources/WikiFS/Chats/Chats/ChatView.swift:905-946` — `ChatAttachment.referenceText`
builds `[[page:\(displayName)]]` / `[[source:\(displayName)]]` / `[[chat:\(displayName)]]`
using the **human display name** as the target (the wire-message form for the
agent, intentionally human-readable). **Do NOT copy this form** — it produces the
non-canonical `[[page:Title]]` which the rewriter must fix on save. The drop-insert
feature should emit the canonical `[[kind:<ULID>|<displayName>]]` instead.

---

## Implementation steps

### Step 1 — Pure mapper (the load-bearing correctness piece)

Add a **pure, dependency-free** function (no SwiftUI, no store) in
`Sources/WikiFSLinks/` (so `WikiFSTests` can hit it without AppKit):

```swift
// e.g. Sources/WikiFSLinks/DroppedLinkFormatter.swift
public enum DroppedLinkFormatter {
    /// Map a sidebar kind to the wikilink prefix ("page:"/"source:"/"chat:").
    public static func linkPrefix(for kind: SidebarDragPayload.Kind) -> String {
        switch kind {
        case .page:   return ParsedLink.LinkType.page.linkPrefix
        case .source: return ParsedLink.LinkType.source.linkPrefix
        case .chat:   return ParsedLink.LinkType.chat.linkPrefix
        }
    }

    /// A single canonical link: `[[<kind:ULID>|<alias>]]`.
    /// `displayName` is the alias (current title/name); falls back to the raw
    /// ULID when the target is stale/unresolved so the link still resolves by id
    /// at render (the alias is only cosmetic — Phase 5 display-at-render resolves
    /// the ULID regardless of the alias text).
    public static func link(for kind: SidebarDragPayload.Kind,
                           id: String,
                           displayName: String?) -> String {
        let alias = displayName ?? id
        return "[[\(linkPrefix(for: kind))\(id)|\(alias)]]"
    }

    /// An indented markdown list of links, one per item, indented 2 spaces per
    /// `depth` level (depth 0 = top-level, no indent). Joins with "\n". Each
    /// item carries its own `(kind, id, displayName)`. A stale item (no
    /// displayName) still emits a link (alias falls back to id).
    public static func markdownList(
        for items: [(depth: Int, kind: SidebarDragPayload.Kind,
                     id: String, displayName: String?)]) -> String {
        items.map { item in
            let indent = String(repeating: "  ", count: max(0, item.depth))
            return "\(indent)- \(link(for: item.kind, id: item.id,
                                     displayName: item.displayName))"
        }.joined(separator: "\n")
    }
}
```

**Why this shape:** the alias is cosmetic + the link is ULID-pinned, so a deleted/
renamed target's dropped link still resolves (or renders dimmed as a missing
target), mirroring `WikiLinkMarkdown.linkified`'s `wiki://missing` behavior. The
mapper takes only plain values → trivially unit-testable.

> The implementer MAY choose to express `Items` as a small `struct` rather than a
> tuple if the test ergonomics are nicer; keep the public pure API stable.

### Step 2 — Editor drop-accept (NSTextView insertion at the drop point)

Extend `Sources/WikiFS/Editor/ScrollableTextEditor.swift` so the `NSTextView`
accepts `wikiSidebarItem` drops and inserts the generated text at the **visual
drop point**. Two new pieces:

**(a) A small `NSTextView` subclass** that mirrors `WikiReaderView`'s
drag-handling pattern (`WikiReaderView.swift:384-404`) — with ONE crucial
divergence noted below. Return `.copy` when payloads are present; on
`performDragOperation`, hand the payloads to an injected closure that
returns the `String` to insert, then insert at the drop character index.

> **Critical divergence from WikiReaderView:** `WikiReaderView.swfit:384-386`
> overrides `registerForDraggedTypes` to force ONLY `wikiSidebarItem`.
> That's correct for a WKWebView (WebKit manages web-content DnD
> internally, and competing-subview interception is the concern per
> #133/#385). It is WRONG for a plain `NSTextView` editor: an NSTextView's
> drag-destination acceptance is gated by its registered drag types, and
> by default it registers the text types (`string`/`RTF`/`filenames`) that
> power (a) drag-selected-text-to-move within the editor and (b) dropping
> text from another doc/app. Forcing only `wikiSidebarItem` removes those,
> so both are rejected — shipping a UX regression (drag-to-move-selected
> text stops working). The #133/#385 competing-subview concern does NOT
> apply here: the editor is a terminal `NSTextView` with no WKWebView child
> below it. **Register the sidebar type ALONGSIDE the inherited text types,
> NOT instead of them.**

**File location:** add `DropLinkTextView` as a new file at
`Sources/WikiFS/Editor/DropLinkTextView.swift` (NOT appended to
`ScrollableTextEditor.swift` — keep the subclass separate for testability and
single-responsibility). `ScrollableTextEditor.swift` will `import` or
forward-reference it when `makeConfiguredTextView` instantiates it.

```swift
final class DropLinkTextView: NSTextView {
    /// Injected by the SwiftUI representable. Returns the text to insert, or
    /// nil to reject the drop. Receives the flattened payloads across all
    /// dragged pasteboard items (handles multi-select + folders).
    var sidebarDropBuilder: (([SidebarDragPayload]) -> String?)?

    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {
        // DIVERGENCE FROM WikiReaderView: do NOT replace with only
        // wikiSidebarItem. The editor is a terminal NSTextView with no
        // WKWebView child below it, so the #133/#385 competing-subview
        // interception concern does NOT apply. Register the sidebar type
        // ALONGSIDE the inherited text types so drag-selected-text-to-move
        // within the editor and dropping text from another doc/app still work.
        super.registerForDraggedTypes(
            newTypes + [NSPasteboard.PasteboardType(UTType.wikiSidebarItem.identifier)])
    }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation {
        hasPayloads(s.draggingPasteboard) ? .copy : []
    }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation {
        hasPayloads(s.draggingPasteboard) ? .copy : []
    }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        guard let payloads = flattenedPayloads(from: s.draggingPasteboard),
              let text = sidebarDrop?(payloads) else { return false }
        // Insert at the visual drop point (not necessarily the caret).
        let dropChar = characterIndexForInsertion(at: convert(s.draggingLocation, from: nil))
        let r = NSRange(location: dropChar, length: 0)
        replaceCharacters(in: r, with: text)   // fires textDidChange → binding
        let caret = dropChar + (text as NSString).length
        setSelectedRange(NSRange(location: caret, length: 0))
        scrollRangeToVisible(NSRange(location: caret, length: 0))
        return true
    }
    // hasPayloads / flattenedPayloads — read the wikiSidebarItem JSON across all
    // pasteboardItems, mirroring WikiReaderView.sidebarPayloads(from:)(:409-416).
}
```

Reuse the EXACT payload-reading approach from `WikiReaderView.sidebarPayloads(from:)`
(`:409-416`): iterate `pb.pasteboardItems`, decode each `SidebarDragPayloadList`
from the `wikiSidebarItem` type, `flatMap(\.items)`.

Wire `ScrollableTextEditor.makeConfiguredTextView` to instantiate `DropLinkTextView`
instead of `NSTextView`, and store the builder closure on the representable:

```swift
struct ScrollableTextEditor: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    var scrollRequest: EditorScrollRequest?
    var onCaretChange: ((Int) -> Void)?
    /// NEW: builds the insertion text for a sidebar drop. nil = drops disabled.
    var sidebarDropBuilder: (([SidebarDragPayload]) -> String?)? = nil
    ...
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        ...
        if let tv = scrollView.documentView as? DropLinkTextView {
            tv.sidebarDropBuilder = parent.sidebarDropBuilder
        }
    }
}
```

**(b) PageDetailView + SourceDetailView** pass a builder that resolves display
names via the store and routes a single link vs a nested list. The builder runs
on the main actor (the store lookup touches `summaries`/`sources`/`chats`):

```swift
// in PageDetailView.editorContent / SourceDetailView.markdownContent
ScrollableTextEditor(
    text: $store.draftBody,           // (page)  / $editBuffer (source)
    font: ...,
    scrollRequest: editorScrollRequest,
    onCaretChange: { caretCharIndex = $0 },
    sidebarDropBuilder: { payloads -> String? in
        buildInsertionText(from: payloads, store: store)
    }
)
```

`buildInsertionText` (a `@MainActor` helper on the view, or a free function taking
the store as an argument): for each payload resolve the display name via
`store.resolveAttachmentName(for:)`; if exactly one payload →
`DroppedLinkFormatter.link(for:id:displayName:)`; if >1 →
`DroppedLinkFormatter.markdownList(for:)` with depth 0 for a flat multi-select.
(Bookmark-folder nesting depth is handled in step 3.)

> Keep the pure `DroppedLinkFormatter` free of the store; only the builder closure
> in the view touches the store. This is the seam that makes the formatter unit-testable.

### Step 3 — Bookmark folder nested-list walk (depth-aware)

A bookmark FOLDER drag already arrives as a flat `SidebarDragPayloadList`
(`leafPayloads(under:)`), having discarded depth. For the nested-list feature we
need the depth. **Two options (implementer picks one):**

**Option A (preferred):** extend the bookmark drag source to carry a depth-aware
list. Add a richer payload variant OR a parallel pasteboard type.
E.g. `BookmarksOutlineView.leafPayloads(under:)` → produce a new
`SidebarDragPayloadNode { depth: Int; payload: SidebarDragPayload }` list and
encode it under the same `wikiSidebarItem` type (backward-compatible: the
existing flat-`SidebarDragPayloadList` decoders ignore the extra field if you
version the JSON, OR you add a sibling type). The editor drop builder reads the
depth-aware list and calls `DroppedLinkFormatter.markdownList(for:)`.

**Option B (simpler, no payload change):** the editor drop builder re-derives
depth by walking the bookmark tree. When the dropped payload list came from a
folder, the builder re-walks `store.bookmarkNodes` (grouped by `parentID`,
mirroring `BookmarksOutlineView.children(of:)`) to recover depth, builds the
`(depth, kind, id, displayName)` tuples, and calls `markdownList(for:)`.
Downside: the drag payload carries only `kind`+`id` (no folder context), so the
builder can't know it came from "the X folder" — it would have to treat any
multi-payload drop as a flat list OR accept that nested folders flatten.
**v1 commits to Option B (flat depth-0 list).** The editor drop builder
re-derives the flat list of leaf payloads from `store.bookmarkNodes` for the
folder (children walked via the existing `children(of:)` API on the store),
produces one `- [[kind:<ULID>|<name>]]` line per leaf at depth 0
(no nested indentation), joined with `\n`. Nested indentation is a **follow-up
PR** (would require either Option A — depth-aware drag payloads — or a
depth-recovery walk on `store.bookmarkNodes` grouped by `parentID`). The pure
`DroppedLinkFormatter.markdownList(for:)` signature already accepts
`(depth, kind, id, displayName)` tuples so the data shape is forward-compatible;
v1 just passes `depth: 0` for every leaf. If you ship Option B, **do not**
present the flat list as the AC.3 "indented list" — adjust AC.3 to assert the
flat depth-0 list as the v1 acceptance, and document nested-indentation as a
follow-up in the PR description.

### Step 4 — Disable/deflect during agent mid-edit (risk mitigation)

Consult `plans/dirty-editor-protection.md`. The page editor is explicit-save; a
drop just dirties `store.draftBody`. The residual risk: an **agent streaming a
generation into the page body** while the user drops a link could overwrite the
dropped text (same class of hazard as any concurrent edit).

**Resolved:** `WikiStoreModel` HAS a page-is-mid-generation signal:
`store.agentRunCount` (`Sources/WikiFSCore/Store/WikiStoreModel.swift:225`) —
ref-counted via `agentRunStarted()` (`:1614`, called at spawn commit) +
`agentRunEnded()` (`:1624`, called from the process's `terminationHandler`).
When `agentRunCount > 0`, an agent is actively writing to THIS wiki (the model
even flushes pending drafts first at spawn so agent writes don't race the
user's in-flight edit). Use this:

```swift
// In the sidebarDropBuilder closure on PageDetailView:
guard store.agentRunCount == 0 else {
    DebugLog.editor("sidebar drop rejected: agent run in progress (agentRunCount=\(store.agentRunCount))")
    return nil   // drop is silently rejected; don't insert into a buffer an agent is about to overwrite
}
```

Do NOT silently insert into a buffer an agent is about to overwrite. The reject
is visible via `DebugLog.editor` (os_log, Console.app); optionally surface a
transient `.help` text on the editor ("Can't drop while agent is writing") if
the UX feels too quiet, but the load-bearing protection is the `agentRunCount`
guard in the builder.

**Note on `pendingCloseTabID` deferred-close alert window:** per
`plans/dirty-editor-protection.md`, close on an editing tab is deferred pending
a confirm/discard alert. Dropping during that window just dirties the buffer;
confirm-discard discards it — consistent with the explicit-discard model, no
special handling needed.

---

## Test plan

### Pure-function tests (load-bearing — `Sources/WikiFSLinks/...`)

Add `Tests/WikiFSTests/DroppedLinkFormatterTests.swift` (Swift Testing; see
`docs/skills/swift-testing-pro/SKILL.md` core-rules). Cover:

- `link(for:id:displayName:)` for each `.page` / `.source` / `.chat` produces
  exactly `[[page:<ULID>|<Title>]]`, `[[source:<ULID>|<Name>]]`,
  `[[chat:<ULID>|<Title>]]` (assert the prefix + ULID + alias + pipe + brackets).
- `displayName == nil` → alias falls back to the raw ULID
  (`[[page:<ULID>|<ULID>]]`) — link still resolvable by id.
- `markdownList(for:)` with mixed depths: a depth-0 item, a depth-1 item, a
  depth-2 item → assert the exact string with `  ` (2-space) indentation per
  level and `- ` prefix on every line, joined by `\n`.
- Empty list → empty string (no crash).
- ULID characters: assert the id substring is a 26-char Crockford-base32 string
  (mirrors `WikiLinkParser.isCanonicalULID`) so the inserted link is immediately
  canonical.

### Round-trip tests (the parser must accept what we insert)

Add cases to `Tests/WikiFSTests/WikiLinkParserTests.swift` (or a new
`DroppedLinkRoundTripTests.swift`): feed the formatter's output through
`WikiLinkParser.parse(_:)` and assert:
- It yields one `ParsedLink` with the right `linkType` (.page/.source/.chat),
  `target == <ULID>`, `linkText == <alias or ULID>`, and `isCanonicalULID(target)`.
- `WikiLinkRewriter.canonicalize(...)` on the inserted text is a **no-op**
  (returns `nil`) — proving the drop-inserted link is already canonical and save
  won't rewrite it (idempotency).
- A nested-list block (multi-line) round-trips: each line parses to one link,
  none are dropped, list structure is preserved verbatim in the body.

### Drop-wiring integration test (hosted NSTextView)

Per `docs/skills/reproducing-live-ui-bugs/SKILL.md`, host a `DropLinkTextView` in
an `NSWindow` and synthesize a drag. (No WKWebView here — the editor is a plain
`NSTextView`, so the WKWebView-in-test gotchas do not apply.) Verify:
- A `wikiSidebarItem` pasteboard carrying one `SidebarDragPayload` inserts the
  link at the `characterIndexForInsertion` point (assert `textView.string`
  contains the link at the expected offset).
- A folder/multi-payload pasteboard inserts a multi-line list.
- A `wikiSidebarItem` drop does NOT interfere with normal text dnd: a plain
  `public.utf8-plain-text` drop is still ACCEPTED by the subclass (NStextView's
  default text-drag behavior), because `registerForDraggedTypes` registers the
  sidebar type ALONGSIDE the inherited text types, not instead of them. Assert
  that dragging selected text within the editor still moves it (regression test
  for the load-bearing divergence from WikiReaderView — see Step 2 §(a)).
- The `@Binding` updates: after the drop, `text` (the binding) reflects the
  inserted text (proving the view's `store.draftBody` would dirty correctly).

### Smoke: existing drop targets still work

The WikiReaderView (read mode), ChatView composer, BookmarksOutlineView, and the
welcome screen already consume `wikiSidebarItem` drops. Adding the editor as a
new consumer must not change their behavior. Run:
`gh issue list`-free manual smoke OR add an assertion to
`Tests/WikiFSTests/WikiStoreModelDropRoutingTests.swift` that the existing drop
routing is unchanged for each payload kind.

### CI gate

Both Swift CI jobs must pass:
`swift test` (fast tier) and `swift test` (full, `swift-integration` job — see
repo AGENTS.md "Testing"). If any new test is slow (opens a real DB), tag it
`.integration` AND add its name to the fast-tier `--skip` regex in
`.github/workflows/ci.yml`.

---

## Cross-cutting concerns

- **SwiftUI view lifecycle / `@State`:** `.dropDestination` is NOT used here (the
  drop is on the `NSTextView` directly, mirroring `WikiReaderView`). The builder
  closure is stored on the representable and re-applied in `updateNSView` (see the
  existing pattern at `ScrollableTextEditor.swift:66,75-78` for `font`/`scrollRequest`).
  Capture `store` (an `@Observable`/`@StateObject` `WikiStoreModel`) by reference in
  the closure — it's `@MainActor`. Consult `docs/skills/swiftui-ui-patterns/SKILL.md`
  for the `.onDrag`/`.dropDestination`/`@State` guidance if `.dropDestination` is
  ever needed on SwiftUI chrome (it is not, for the editor body itself).
- **Main-actor isolation:** `replaceCharacters`/`setSelectedRange` run on the main
  thread (AppKit drag callbacks are main-thread). `store.resolveAttachmentName`
  is `@MainActor`. Keep the builder closure `@MainActor`-isolated; the
  `DroppedLinkFormatter` itself is plain/Sendable (no actor needs). Consult
  `docs/skills/swift-concurrency-pro/SKILL.md` `actors`/`bug-patterns` references
  if any `Sendable` warning arises from the closure capture.
- **Cursor vs drop-point:** We insert at the **visual drop point** (`characterIndexForInsertion`),
  not the text caret — this is more intuitive (where you drop is where it goes)
  and matches Finder drag-into-text behavior. If the implementer prefers
  caret-insertion, document the choice; drop-point is recommended.
- **IME / in-flight edit guard:** `ScrollableTextEditor.updateNSView` already
  guards `if textView.string != text` before syncing (:72) — do NOT remove this;
  a drop fires `textDidChange` which updates the binding, and the next
  `updateNSView` cycle will see `textView.string == text` and skip the clobber.
- **Agent editor protection:** see step 4 above; this is the one genuine unknown.
- **`turnFailedBannerHTML`/`turnFailed` style:** NOT relevant to this feature (no
  chat turn involved). Disregard.
- **Existing intra-tree bookmark reorder:** the bookmark `SidebarDragPasteboardItem`
  also carries a `bookmark-node-id` type for tree reordering
  (`SidebarDragPayloadTransferable.swift:55-78`). The editor drop must read ONLY
  the `wikiSidebarItem` JSON and ignore `bookmark-node-id` — do not let a
  bookmark-reorder drag accidentally insert text.
- **Cursor-feedback affordance (macos-design):** return `.copy` on `draggingEntered`
  so the drag cursor shows the "+ copy" glyph while over the editor. Consider a
  subtle `.onHover`-style drop-zone hint is NOT needed (AppKit handles the cursor).

---

## Acceptance criteria (the PR must satisfy all)

1. **Source drop → link.** Dragging a source from the sidebar into the page
   editor in edit mode inserts `[[source:<ULID>|<name>]]` at the drop point.
2. **Page drop → link.** Dragging a page inserts `[[page:<ULID>|<Title>]]`.
3. **Bookmark folder drop → indented list.** Dragging a bookmark folder inserts
   an indented markdown list of links (one `- [[kind:<ULID>|<name>]]` per leaf
   target; correct nesting per folder depth). *v1 may ship a flat (depth-0)
   list if nested-depth (step 3 Option A) is deferred — document in the PR.*
4. **Chat drop → canonical chat link.** Dragging a chat inserts
   `[[chat:<ULID>|<Title>]]`. (Chat links already canonicalize — verified via
   `PageUpsert.swift:67-70` passing `resolveChat: store.resolveChatByTitle`.)
5. **Source markdown editor parity.** The same four behaviors work when dropping
   into the source editor's edit mode (`SourceDetailView.markdownContent`).
6. **Pure-function tests** cover all 4 types + nil-displayName fallback +
   multi-depth list formatting + empty list.
7. **Round-trip tests** prove the inserted text is canonical (rewriter no-op) and
   parses to the expected `ParsedLink`.
8. **Both Swift CI jobs pass** (fast tier + `swift-integration`).
9. **No regression** to existing `wikiSidebarItem` consumers (WikiReaderView,
   ChatView composer, BookmarksOutlineView, welcome screen).

---

## NOT in scope (v1)

- **Cross-app drag** (dragging a file from Finder into the editor to create a
  source-link). In-app sidebar→editor drag only for v1. Finder drag is a
  follow-up (would require UTI handling for arbitrary file types + "is this
  already a source?" lookup).
- **Bookmark REORDERING via the editor** (the folder drag into the editor only
  produces links; it does NOT move bookmark nodes). Intra-tree reorder continues
  to live in `BookmarksOutlineView` only.
- **Multi-select drag** is supported only insofar as the sidebar lists already
  vended multi-row drags (the drop handler flattens). If a sidebar list does not
  yet support multi-select drag, adding it is out of scope; flag if observed.
- **Editor pretty-display over `[[page:ULID|Title]]`** — that's existing issue #255
  (render the canonical raw text nicely); unrelated to drag-insert.
- **Wiki-link autocomplete in the chat composer** — existing issue #436
  (typing-triggered autocomplete); unrelated to drag-insert.
- **Dropping onto the read-only `WikiReaderView`** — already implemented (opens a
  tab); unchanged.

---

## House rules (encoded for the implementer)

- **Branch:** `feature/drag-wikilinks`. Never commit to / merge to `main`; open a
  PR and let the operator merge.
- **Logging:** `DebugLog.editor(...)` / `DebugLog.tabs(...)` (os_log, subsystem
  `com.selfdrivingwiki.debug`) — NEVER bare `print` (except real CLI stdout, n/a here).
- **Errors:** never bare `try?` to swallow errors. If a decode fails in the drop
  handler, `do { try … } catch { DebugLog.editor("drop decode failed: \(error)") }`
  and reject the drop (return `false`/`nil`).
- **Tests:** Swift Testing (`@Test`), not XCTest, for new tests. Follow
  `docs/skills/swift-testing-pro/SKILL.md` (core-rules, async-tests).
- **SwiftUI:** consult `docs/skills/swiftui-pro/SKILL.md` + the UI-patterns skill
  for any `.onDrag`/`.dropDestination`/`@State` work (the editor uses an
  `NSViewRepresentable`, so most guidance is about the representable lifecycle).
- **AppKit drag/`NSViewRepresentable`:** mirror the EXISTING `WikiReaderView`
  drag pattern (`Reader/WikiReaderView.swift:384-416`) ONLY. Do NOT mirror
  `ComposerTextView` (`Editor/ComposerTextView.swift:125-129`): it does the
  OPPOSITE — `textView.unregisterDraggedTypes()` so sidebar drags bubble PAST
  the NSTextView to a SwiftUI `.dropDestination` on the composer container. The
  editor instead registers the sidebar type directly on the textview, and the
  #133/#385 competing-subview concern does NOT apply here (the editor is a
  terminal NSTextView with no WKWebView child below it).
- **macOS design:** `.copy` drag operation for the cursor affordance; no custom
  drop-zone chrome needed (keep it native). See `docs/skills/macos-design/SKILL.md`.
- **No tree pollution:** scratch/plan files go in `tmp/` until the feature branch
  is created; on the feature branch, commit the plan as `plans/drag-wikilinks.md`
  (copy from `tmp/sdw-plans/drag-wikilinks.md`).
