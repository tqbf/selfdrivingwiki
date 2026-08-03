# Bookmark relative-link rewriting (issue #216 follow-on)

**Status:** Ready to execute.

**Context.** The FileProvider projection rewrites `[[wikilinks]]` → relative
Markdown links in the `pages/by-title`, `sources/by-name` (markdown siblings),
and `chats/by-name` views (see `Sources/WikiFSCore/RelativeLinkRewriter.swift`
and `Sources/WikiFSFileProvider/Projection.swift`). The `bookmarks/` tree does
NOT — its `pageRef` / `chatRef` leaves still serve raw `[[…]]`. This plan closes
that gap.

**Confirmed decisions (from the parent conversation):**
- Vault root is the **mount root**, so cross-namespace `../…` links resolve.
- `sourceRef` bookmarks serve **verbatim binary bytes** (`store.sourceContent`)
  and must NOT be rewritten — only `pageRef` and `chatRef` render markdown.
- The size path (`bookmarkNodeItem`) and the content path (`bookmarkContent`)
  must produce **byte-identical** output — a mismatch truncates `cat` (#216).

**The one hard part — `baseDir` varies by depth.** A bookmark ref at
`bookmarks/Research/Papers/Note.md` needs `../../../pages/by-title/…`. The ref's
directory is `["bookmarks"] + <sanitized folder labels root→parent>`. Every
other view has a fixed depth-2 `baseDir`; bookmarks are arbitrary-depth.

All changes are in **`Sources/WikiFSFileProvider/Projection.swift`** plus tests
in **`Tests/WikiFSTests/ProjectionTreeTests.swift`**. No changes to
`RelativeLinkRewriter` (its `Resolver`/`baseDir` API already supports this).

---

## Task 1 — `baseDir` from a bookmark node's ancestor chain

Add a helper that returns the projection-relative directory components for the
folder CONTAINING a bookmark node, by walking `parentID` up through folders.

Add near the other bookmark helpers (after `sanitizeFilename`, ~line 899):

```swift
    /// The projection-relative directory components CONTAINING `node` —
    /// `["bookmarks"]` for a root-level ref, plus one sanitized label per
    /// ancestor folder (root → immediate parent). Used as the rewriter's
    /// `baseDir` so a nested ref's links climb the right number of `../`.
    /// The parent walk is capped (matches `BookmarkNode.displayPath`) so a
    /// corrupted parent cycle can't loop forever.
    private func bookmarkBaseDir(for node: BookmarkNode,
                                 in nodes: [BookmarkNode]) -> [String] {
        var byID: [String: BookmarkNode] = [:]
        byID.reserveCapacity(nodes.count)
        for n in nodes { byID[n.id] = n }

        var labels: [String] = []
        var current = node.parentID.flatMap { byID[$0] }
        var depth = 0
        let maxDepth = 64
        while let folder = current, depth < maxDepth {
            depth += 1
            labels.insert(Self.sanitizeFilename(folder.label ?? "Untitled"), at: 0)
            current = folder.parentID.flatMap { byID[$0] }
        }
        return ["bookmarks"] + labels
    }
```

**Notes:**
- `node` itself is the ref (or folder); we start from its `parentID`, so the
  returned dir is the ref's *containing* directory (excludes the ref filename).
- Folder labels use `sanitizeFilename` (same as the folder node names emitted by
  `bookmarkNodeItem`'s `.folder` case) so the path segments match on disk.
- Untitled folders fall back to `"Untitled"` — matching the `.folder` name.

**Verify:** compiles (`swift build`). Behavior is exercised by Task 4 tests.

---

## Task 2 — thread `LinkMaps` + rewrite into `bookmarkNodeItem` (size path)

`bookmarkNodeItem` currently renders `pageRef`/`chatRef` markdown raw. Rewrite
it, and size from the rewritten bytes. `sourceRef` and stale placeholders are
left untouched.

Change the signature to accept the maps and the full node list (needed for
`baseDir`):

```swift
    private func bookmarkNodeItem(
        for node: BookmarkNode, in store: SQLiteWikiStore,
        maps: LinkMaps, allNodes: [BookmarkNode]
    ) -> ProjectedNode {
```

Inside, in the `.pageRef` resolved branch, replace:

```swift
                let body = Data(PageMarkdownFormat.fileContent(for: page).utf8)
```
with:
```swift
                let baseDir = bookmarkBaseDir(for: node, in: allNodes)
                let body = rewriteLinks(PageMarkdownFormat.fileContent(for: page),
                                        maps: maps, baseDir: baseDir)
```

In the `.chatRef` resolved branch, replace:

```swift
                let body = Data(ChatTranscriptRenderer.render(summary: chat, messages: messages).utf8)
```
with:
```swift
                let baseDir = bookmarkBaseDir(for: node, in: allNodes)
                let raw = ChatTranscriptRenderer.render(summary: chat, messages: messages)
                let body = rewriteLinks(raw, maps: maps, baseDir: baseDir)
```

Leave `.sourceRef` (verbatim binary) and all `Stale reference` placeholders
exactly as they are.

**Verify:** compiles after Task 3 updates the callers.

---

## Task 3 — build maps + pass through at the three callers

`bookmarkNodeItem` is called from three sites, each of which already has the
node list from `listBookmarkNodes()`. Build `makeLinkMaps()` once per call and
thread both through.

### 3a. `bookmarkNode(for:)`
```swift
    private func bookmarkNode(for id: NSFileProviderItemIdentifier) -> ProjectedNode? {
        guard let ulid = Identity.bookmarkULID(from: id),
              let store = openReadStore(),
              let nodes = try? store.listBookmarkNodes(),
              let node = nodes.first(where: { $0.id == ulid }) else { return nil }
        return bookmarkNodeItem(for: node, in: store, maps: makeLinkMaps(), allNodes: nodes)
    }
```

### 3b. `bookmarkChildren(of:)` — the final `compactMap`
```swift
        let maps = makeLinkMaps()
        return nodes
            .filter { $0.parentID == parentID }
            .sorted { $0.position < $1.position }
            .compactMap { bookmarkNodeItem(for: $0, in: store, maps: maps, allNodes: nodes) }
```

### 3c. `allBookmarkNodes()`
```swift
    private func allBookmarkNodes() -> [ProjectedNode] {
        guard let store = openReadStore(),
              let nodes = try? store.listBookmarkNodes() else { return [] }
        let maps = makeLinkMaps()
        return nodes.compactMap { bookmarkNodeItem(for: $0, in: store, maps: maps, allNodes: nodes) }
    }
```

**Verify:** `swift build` clean (ignore the pre-existing `FileProviderSpike`
`no-usage` warning).

---

## Task 4 — rewrite `bookmarkContent` (content path — MUST match Task 2)

`bookmarkContent` serves the bytes. Apply the SAME rewrite for `pageRef` and
`chatRef` so `size == bytes`. It already has `store`, `nodes`, and `node`.

In `.pageRef`, replace:
```swift
            return Data(PageMarkdownFormat.fileContent(for: page).utf8)
```
with:
```swift
            return rewriteLinks(PageMarkdownFormat.fileContent(for: page),
                                maps: makeLinkMaps(),
                                baseDir: bookmarkBaseDir(for: node, in: nodes))
```

In `.chatRef`, replace:
```swift
            let messages = (try? store.chatMessages(chatID: chat.id)) ?? []
            return Data(ChatTranscriptRenderer.render(summary: chat, messages: messages).utf8)
```
with:
```swift
            let messages = (try? store.chatMessages(chatID: chat.id)) ?? []
            let raw = ChatTranscriptRenderer.render(summary: chat, messages: messages)
            return rewriteLinks(raw, maps: makeLinkMaps(),
                                baseDir: bookmarkBaseDir(for: node, in: nodes))
```

Leave `.folder` (nil), `.sourceRef` (verbatim), and stale placeholders as-is.

**Verify:** `swift build` clean.

---

## Task 5 — tests

Add to `Tests/WikiFSTests/ProjectionTreeTests.swift`. Check the store API for
creating bookmark nodes first (search `SQLiteWikiStore` for
`createBookmark`/`addBookmark`/`insertBookmarkNode`); use whatever the existing
bookmark tests use. Use `Projection.Identity.bookmarkPageRef(node.id)` for the
leaf id.

1. **Root-level pageRef rewrites with single `../` and size matches bytes.**
   Seed a page `Target`, a page `Home` whose body links `[[page:<TargetID>|t]]`,
   a root bookmark pageRef → `Home`. Assert:
   - `node.size == contents(for: id)!.count`
   - content contains `[t](../pages/by-title/Target Page--<short>.md)` (one `../`)
   - no `[[page:` remains.

2. **Nested pageRef climbs the right depth.** Put the pageRef inside a folder
   `Research` (one level). Assert content contains `../../pages/by-title/`.

3. **sourceRef is left verbatim.** A bookmark sourceRef → the pdf source still
   serves `store.sourceContent(id:)` bytes unchanged, `size == bytes`.

4. **`bookmarkBaseDir` unit** (if practical without a store): a root ref →
   `["bookmarks"]`; a ref under folder "A" → `["bookmarks", "A"]`; under "A/B"
   → `["bookmarks", "A", "B"]`. Sanitizes a label containing `/`.

**Verify:** `swift test --filter "ProjectionTreeTests"` green; then the broader
`swift test --filter "RelativeLinkRewriter|Projection"` still green.

---

## Out of scope / notes
- The 4 pre-existing `SQLiteWikiStoreTests` failures (`refs` table / change
  token / v29 migration) are unrelated — do not try to fix them here.
- No `RelativeLinkRewriter` changes: its `Resolver.baseDir` already accepts an
  arbitrary-depth directory.
- The live mount stays stale until the extension is rebuilt/reinstalled — a
  deployment step, not part of this plan.
