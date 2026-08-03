# Phase B — Source Wiki Links (implemented correctly)

**Status:** Ready to implement **after**
[`fix-phase-a-source-bugs.md`](fix-phase-a-source-bugs.md) lands.
**Parent design:** [`sources-redesign.md`](sources-redesign.md) Feature 1 (lines 26-158)
and the Phase B bullet (lines 397-403).
**Why a separate plan:** the parent design's Phase B has one architectural contradiction
(the render contract), three false "same as today" claims, and two shipped bugs it
inherits. This plan re-states Phase B so it is internally consistent and grounded in the
real code. It supersedes the Phase B portion of `sources-redesign.md` wherever they
conflict (conflicts are called out below).

This plan resolves all 23 findings from the Phase B review (each cited inline).

## Depends on

- **Plan 1 (`fix-phase-a-source-bugs.md`) MUST land first.** Phase B populates
  `source_links`; until Plan 1's v11 cascade migration lands, `deleteSource` throws an FK
  violation on any source that has a link row. Do not start Phase B on a v10 DB.

## Decisions (locked)

These overturn or sharpen the parent design. They are the load-bearing choices; the
steps below follow from them.

1. **Render contract: source links render as `wiki://source?title=<display-name>`,
   mirroring pages — NOT `wiki://source?id=<ulid>`.** The display name is resolved to a
   source ULID at **click time** via a new `selectSource(byDisplayName:)`, exactly as
   page links resolve `?title=` at click time via `selectPage(byTitle:)`. This keeps a
   single Bool-style resolution closure uniform across both link kinds and needs no
   render-time ULID. *(Resolves the render-contract contradiction, finding
   PHASE-B-RENDER-CONTRACT / nav-2; removes the need for `sourceID(from:)` at render
   time.)*

2. **Parser: `LinkType` enum with a `.page` default; `source:`/`page:` reserved
   prefixes; alias is verbatim.** `ParsedLink` gains `linkType` with a defaulted init so
   every existing `ParsedLink(target:linkText:)` call site compiles unchanged. `source:`
   is stripped from the **target only** (never the alias) and the remainder is
   re-normalized. A `page:` prefix is the explicit escape, so a page literally titled
   `source:foo` stays linkable as `[[page:source:foo]]`. *(Resolves B1, B4, B5, B6, B7.)*

3. **Resolution is one shared subsystem.** Extract a single public whitespace normalizer
   consolidating the three private `collapseWhitespace` copies. Make title/display-name
   matching **case-insensitive** for *both* pages and sources via `COLLATE NOCASE` (see
   Open Decision 1 for the page-side behavior change). Add `resolveSourceByName` with the
   `updated_at DESC` tiebreak and a filename fallback. *(Resolves SR-1, SR-3, SR-4.)*

4. **Persistence: `replaceLinks` writes both link kinds in ONE transaction.** The
   existing single-`BEGIN IMMEDIATE` `replaceLinks` is extended to partition parsed links
   by `linkType`, resolve each kind against its own table, and write `page_links` +
   `source_links` atomically. No second transaction, no separate `replaceSourceLinks`
   writer. `PageUpsert` needs no change (it already passes all parsed links). *(Resolves
   SL-2, SL-3, SL-4, phase-b-source-links-table-misplacement.)*

5. **Index: one unified `links.jsonl` with a `type` field**, page rows then source rows,
   each sorted by `(from, to)`. *(Resolves links-type-backcompat,
   links-jsonl-naming-unified-graph, links-dedupe-and-ordering.)*

6. **Rename spec corrections** (these edit `sources-redesign.md`): the link-rewrite scan
   is a *new* capability (not a "general capability"); the rewrite is alias-preserving;
   `link_text` IS re-derived on re-save; the scan covers both old display-name and
   filename forms. *(Resolves scope-d-page-rename-link-rewrite,
   link-text-not-stable-on-rename.)*

---

## 1. Parser — `Sources/WikiFSCore/WikiLinkParser.swift`

### 1.1 Add `LinkType` + defaulted init

```swift
public struct ParsedLink: Equatable, Sendable {
    public enum LinkType: String, Equatable, Sendable { case page, source }

    public let linkType: LinkType
    public let target: String       // prefix-stripped, whitespace-collapsed
    public let linkText: String     // alias verbatim (never prefix-stripped)

    /// `linkType` defaults to `.page` so every existing `ParsedLink(target:linkText:)`
    /// call site (parser internals + 8 test assertions) compiles unchanged and equality
    /// holds (both sides default to `.page`).
    public init(linkType: LinkType = .page, target: String, linkText: String) {
        self.linkType = linkType
        self.target = target
        self.linkText = linkText
    }
}
```

### 1.2 Classify the target (shared with `WikiLinkMarkdown`)

Add a pure, tested classifier so the parser and the markdown rewriter share **one** copy
of the prefix rule (the parent design's "regex stays the same, strip `source:`" left this
logic implicit and would have been duplicated):

```swift
/// Split a whitespace-collapsed target into its (kind, bare-target). Reserved
/// prefixes: `page:` (explicit page link / escape) takes precedence over `source:`,
/// so a page literally titled "source:foo" is linkable as `[[page:source:foo]]`.
/// The remainder is re-normalized so `[[source: X]]` → ("X"), not (" X").
public static func classify(_ target: String) -> (LinkType, String) {
    if let rest = peel(prefix: "page:", off: target)   { return (.page,   WikiText.normalized(rest)) }
    if let rest = peel(prefix: "source:", off: target) { return (.source, WikiText.normalized(rest)) }
    return (.page, target) // target already normalized by the caller
}
private static func peel(prefix: String, off s: String) -> String? {
    guard s.hasPrefix(prefix) else { return nil }
    let rest = String(s.dropFirst(prefix.count))
    return rest.allSatisfy(\.isWhitespace) ? nil : rest // `[[source:]]` → not a source link
}
```

(`WikiText.normalized` is the extracted shared normalizer from §3.1.)

### 1.3 Update `parse` to use it, dedup per `(kind, target)`

In `parse(_:)` (lines 48-64): after `collapseWhitespace(rawTarget)` → classify it; skip
if the bare target is empty; dedup by `"\(linkType.rawValue):\(target)"` (so `[[X]]` and
`[[source:X]]` are distinct, but two `[[source:X|…]]` collapse first-alias-wins). Leave
the alias untouched (lines 54-61 already collapse-but-not-strip it — keep that). Construct
`ParsedLink(linkType:target:linkText:)`.

### 1.4 Tests — `Tests/WikiFSTests/WikiLinkParserTests.swift`

Existing tests stay green unchanged (defaulted `.page`). Add:
- `[[source:My Notes]]` → `(.source, "My Notes")`, linkText `"My Notes"`.
- `[[source:My Notes|my notes]]` → `(.source, "My Notes")`, linkText `"my notes"`.
- `[[source: X]]` → target `"X"` (no leading space).
- `[[source:]]` / `[[source:   ]]` → `.page` with target `""`? No: skip (empty). Decide:
  treat a bare empty source target as a non-link (skip), matching `[[ ]]` today.
- `[[page:source:foo]]` → `(.page, "source:foo")` (escape).
- Dedup: `[[source:X|a]]` + `[[source:X|b]]` → one row, `a` wins; `[[X]]` + `[[source:X]]`
  → two rows.

---

## 2. Rendering — `Sources/WikiFSCore/WikiLinkMarkdown.swift`

### 2.1 Closure carries `LinkType`

```swift
public static func linkified(
    _ body: String,
    isResolved: (String, LinkType) -> Bool = { _, _ in true }
) -> String
```

Inside the match loop (lines 76-92): classify the target with `WikiLinkParser.classify`
(same rule the parser uses — no second copy). If the bare target is empty, emit literal
text as today. Otherwise:

```swift
let resolved = isResolved(bareTarget, kind)
out += markdownLink(display: display, target: bareTarget, kind: kind, resolved: resolved)
```

The display text is unchanged (alias-or-target, lines 84-90).

### 2.2 `markdownLink` becomes kind-aware; payload stays `?title=`

```swift
private static func markdownLink(display: String, target: String,
                                 kind: WikiLinkParser.ParsedLink.LinkType,
                                 resolved: Bool) -> String {
    let host = resolved ? (kind == .source ? "source" : "page") : unresolvedHost
    // … existing percent-encoding of target + display escaping …
    return "[\(safeDisplay)](\(scheme)://\(host)?title=\(encodedTitle))"
}
```

The payload is always `?title=<encoded target>` — for source links that target is the
display name. **No `?id=` anywhere.** This is the crux of Decision 1.

### 2.3 URL helpers

- `target(from:)` (lines 103-112): accept host `"page"`, `"source"`, **or** `"missing"`
  (i.e. add `"source"` to the host allow-list). Still returns the `title` query value.
- Replace `isResolvedURL(_:)` (lines 116-118) with a kind-returning helper so the click
  handler can route:

```swift
/// `.page` / `.source` for a resolved link; `nil` for unresolved (`missing`) or non-wiki.
public static func resolvedKind(from url: URL) -> WikiLinkParser.ParsedLink.LinkType? {
    guard url.scheme == scheme, let host = url.host else { return nil }
    switch host {
    case resolvedHost:   return .page     // "page"
    case "source":       return .source
    default:             return nil       // "missing" or anything else → inert
    }
}
```

(Keep `isResolvedURL` if other call sites use it, delegating to `resolvedKind != nil`.)

---

## 3. Resolution — shared subsystem

### 3.1 Extract one normalizer — new `Sources/WikiFSCore/WikiText.swift`

```swift
public enum WikiText {
    /// Collapse whitespace runs to one space and trim. The single shared
    /// implementation; replaces the three private `collapseWhitespace` copies in
    /// WikiLinkParser, WikiLinkMarkdown, and HTMLToMarkdown.
    public static func normalized(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
```

Replace the private copies: `WikiLinkParser.swift:70-72`, `WikiLinkMarkdown.swift:137-139`,
and `HTMLToMarkdown.swift:184` (the internal one used cross-type by
`HTMLMarkdownRenderer.swift:149` — that caller now calls `WikiText.normalized`). The
semantics are identical, so no behavior change.

### 3.2 Case-insensitive title resolution — `SQLiteWikiStore.resolveTitleToID` (lines 688-696)

Change `WHERE title = ?1` → `WHERE title = ?1 COLLATE NOCASE`. **Audit
`WikiStoreModel`/page-resolution tests** (search `Tests/` for resolution tests that assume
case-sensitive matching) and update expectations. `COLLATE NOCASE` is ASCII-only folding
(matching the existing sort usage at line 459); document that non-ASCII case differences
won't fold. *(Resolves SR-1.)*

### 3.3 Source resolver + existence check — new on `SQLiteWikiStore` + protocol

`WikiStore.swift` protocol (alongside `resolveTitleToID` at line 36):

```swift
func resolveSourceByName(_ displayName: String) throws -> PageID?
```

`SQLiteWikiStore`:

```swift
/// Resolve a `[[source:…]]` target to a source id. Matches display_name, falling
/// back to filename (so a retired display name still resolves via its filename).
/// Case-insensitive (COLLATE NOCASE), matching page-title resolution. On a
/// multi-match collision, the most recently updated source wins (pages, by
/// contrast, tiebreak oldest-first by id — see sources-redesign.md SR-4).
public func resolveSourceByName(_ displayName: String) throws -> PageID? {
    let stmt = try statement("""
    SELECT id FROM sources
    WHERE COALESCE(display_name, filename) = ?1 COLLATE NOCASE
       OR filename = ?1 COLLATE NOCASE
    ORDER BY updated_at DESC LIMIT 1;
    """)
    defer { stmt.reset() }
    try stmt.bind(displayName, at: 1)
    guard try stmt.step() else { return nil }
    return PageID(rawValue: stmt.text(at: 0))
}
```

`WikiStoreModel` (mirror `pageExists` at lines 192-194):

```swift
public func sourceExists(displayName: String) -> Bool {
    (try? store.resolveSourceByName(displayName)) != nil
}
```

**Verify `addSource` writes `display_name = filename`** for every new row (the v10
backfill only covered pre-existing rows; new inserts must not leave `display_name` NULL or
the `COALESCE` above silently falls back). If `addSource` doesn't set it, set it.

---

## 4. Navigation — `Sources/WikiFS/MarkdownPreview.swift`

### 4.1 Inject a kind-aware closure (lines 78-80)

```swift
private func linkified(_ body: String) -> String {
    WikiLinkMarkdown.linkified(body) { name, kind in
        kind == .source ? store.sourceExists(displayName: name) : store.pageExists(title: name)
    }
}
```

### 4.2 Dispatch by kind (OpenURLAction, lines 53-64)

```swift
.environment(\.openURL, OpenURLAction { url in
    guard let title = WikiLinkMarkdown.target(from: url) else {
        if WikiFootnoteMarkdown.isFootnoteURL(url) { return .handled }
        return .systemAction
    }
    switch WikiLinkMarkdown.resolvedKind(from: url) {
    case .page:   store.selectPage(byTitle: title)
    case .source: store.selectSource(byDisplayName: title)
    case nil:     break // unresolved ("missing") → inert
    }
    return .handled
})
```

### 4.3 New `selectSource(byDisplayName:)` — `WikiStoreModel`

Mirror `selectPage(byTitle:)` (lines 206-214) line for line, resolving the display name
then routing through the **existing** `openTab(.source(id))` seam (already used by
Zotero/drag-drop/URL/folder import at `WikiStoreModel.swift:633,670,716,765`):

```swift
@discardableResult
public func selectSource(byDisplayName displayName: String) -> Bool {
    guard let id = (try? store.resolveSourceByName(displayName)) ?? nil else { return false }
    let target = WikiSelection.source(id)
    recordHistoryTransition(from: loadedSelection, to: target)
    openTab(target)
    return true
}
```

*(Resolves nav-1: the method is explicitly enumerated as Phase B work and the page/source
keying asymmetry is justified — both resolve-by-name at click time, so the closure stays
uniform. nav-5: `WikiSelection.source(PageID)` keeps the `PageID` type name; it is the
shared ULID wrapper, already documented at `SourceSummary.swift:9-13`. Leave it.)*

---

## 5. Persistence — `SQLiteWikiStore.replaceLinks` (lines 698-728)

Extend the existing single-transaction method to write both tables atomically. The
protocol signature is unchanged (`ParsedLink` now carries `linkType`):

```swift
public func replaceLinks(from pageID: PageID,
                         parsedLinks: [WikiLinkParser.ParsedLink]) throws {
    try exec("BEGIN IMMEDIATE;")
    do {
        // Wipe this page's outgoing links in BOTH tables, then re-insert the
        // resolved subsets. Unresolved targets are omitted (NULL FKs forbidden).
        let delPage = try statement("DELETE FROM page_links WHERE from_page_id = ?1;")
        delPage.reset(); try delPage.bind(pageID.rawValue, at: 1); _ = try delPage.step()
        let delSource = try statement("DELETE FROM source_links WHERE from_page_id = ?1;")
        delSource.reset(); try delSource.bind(pageID.rawValue, at: 1); _ = try delSource.step()

        let insPage = try statement("""
        INSERT OR IGNORE INTO page_links (from_page_id, to_page_id, link_text) VALUES (?1,?2,?3);""")
        let insSource = try statement("""
        INSERT OR IGNORE INTO source_links (from_page_id, to_source_id, link_text) VALUES (?1,?2,?3);""")
        for link in parsedLinks {
            switch link.linkType {
            case .page:
                guard let id = try resolveTitleToID(link.target) else { continue }
                insPage.reset()
                try insPage.bind(pageID.rawValue, at: 1); try insPage.bind(id.rawValue, at: 2)
                try insPage.bind(link.linkText, at: 3); _ = try insPage.step()
            case .source:
                guard let id = try resolveSourceByName(link.target) else { continue }
                insSource.reset()
                try insSource.bind(pageID.rawValue, at: 1); try insSource.bind(id.rawValue, at: 2)
                try insSource.bind(link.linkText, at: 3); _ = try insSource.step()
            }
        }
        try exec("COMMIT;")
    } catch {
        try? exec("ROLLBACK;"); throw error
    }
}
```

`PageUpsert.upsert` (lines 54-55) needs **no change** — it already calls
`replaceLinks(from:parsedLinks:)` with all parsed links; those links now carry `linkType`.

**Document the alias-collapsing limitation** in the method comment (it already exists for
`page_links` at lines 702-703): `PRIMARY KEY (from_page_id, to_*)` + `INSERT OR IGNORE`
means two links from one page to the same target with different aliases collapse to the
first; `source_links` inherits this. *(Resolves SL-3, SL-4.)*

---

## 6. Index — `Sources/WikiFSCore/IndexGenerators.swift`

### 6.1 `LinkRow` gains `type` (lines 21-26)

```swift
public struct LinkRow: Equatable, Sendable {
    public let from: String
    public let to: String
    public let linkText: String
    public let type: String          // "page" | "source"
    public init(from: String, to: String, linkText: String, type: String) { … }
}
```

### 6.2 `linksJSONL` emits `type` (lines 126-135)

Fixed key order `from, to, link_text, type`:

```swift
out += "{\"from\":\(from),\"to\":\(to),\"link_text\":\(text),\"type\":\(jsonString(link.type))}\n"
```

Additive — safe for the only programmatic reader
(`IndexGeneratorTests.swift:82-85`, key-presence checks). Update that test if it asserts an
exact key set.

### 6.3 Read + merge — `SQLiteWikiStore`

- `listAllLinks()` (lines 734-749): construct `LinkRow` with `type: "page"` (existing
  `ORDER BY from_page_id, to_page_id`).
- Add `listAllSourceLinks() throws -> [IndexGenerators.LinkRow]` (same shape, `type:
  "source"`, `ORDER BY from_page_id, to_source_id`).
- At the projection site that generates `links.jsonl` (the File Provider call that
  currently passes `listAllLinks()` to `IndexGenerators.linksJSONL`), pass
  `listAllLinks() + listAllSourceLinks()` — **page rows first, then source rows, each
  already sorted by `(from, to)`**. State this merge order in a comment so byte output
  stays deterministic for a given DB state. *(Resolves links-dedupe-and-ordering,
  links-jsonl-naming-unified-graph.)*

### 6.4 Agent prompt — `SystemPrompt.swift` (lines 54, 130)

Add one line where `links.jsonl` is described, documenting the `type` field
(`"page"` / `"source"`) so the managing agent knows the unified graph spans both.
*(Resolves links-type-backcompat.)*

---

## 7. Rename spec corrections — edit `plans/sources-redesign.md`

These are doc fixes to the parent design (rename is implemented in Phase D, but the spec
must be correct now so Phase D is unambiguous):

- **Line 157** — reword "the rename-update scan is a general capability, not
  source-specific" / "Same mechanism will apply to page renames" → **"the rename-update
  scan is a NEW capability introduced here; it is applied to both source and page
  renames."** The page-rename link-rewrite gap is real (documented at
  `WikiStoreModel.swift:446-448` and `PageUpsert.swift:44-46`), but there is no existing
  scanner to generalize — grep finds none. *(Resolves scope-d-page-rename-link-rewrite.)*
- **Line 155** — delete "source_links.link_text is NOT updated (it stores the alias at
  link creation time)". This is false: rename re-saves affected pages → `replaceLinks`
  wipes+reinserts `source_links` from the rewritten body, so `link_text` IS re-derived.
  Replace with: *"link_text is re-derived from the rewritten body on re-save; the rewrite
  preserves the alias segment."*
- **Rewrite rule (lines 153, 245)** — state it explicitly and alias-preserving:
  `[[source:<old>|<alias>]]` → `[[source:<new>|<alias>]]` (substitute the target segment
  only; keep the alias). The current examples show the alias-less form, which would drop
  aliases. Add a Phase D test: a page with `[[source:Old|my notes]]`, renamed to New,
  still yields `source_links.link_text == "my notes"`.
- **Rename scan scope (line 249)** — the scan must cover **both** `[[source:<old
  display_name>…]]` and `[[source:<filename>…]]`, because the filename remains a valid
  fallback target after a display-name change (§3.3). *(Resolves SR-3, SR-4.)*
- **Line 399 (Phase B checklist)** — strike "Add `source_links` table". The table was
  created in Phase A's v10 migration (`SQLiteWikiStore.swift:327-334`) and its cascade FK
  is fixed by Plan 1's v11. Phase B owns only the Swift half (parser, render, resolution,
  persistence, index, navigation). *(Resolves SL-2, phase-b-source-links-table-misplacement.)*

---

## Tests (new, beyond the per-section ones above)

- `WikiLinkParserTests`: §1.4 set.
- `WikiLinkMarkdownTests` (add if absent): `[[source:X]]` renders
  `[X](wiki://source?title=X)` when resolved, `[X](wiki://missing?title=X)` when not;
  `[[source:X|alias]]` → display `alias`, target `X`; `target(from:)`/`resolvedKind(from:)`
  round-trip for all three hosts.
- `SQLiteWikiStoreTests`: `resolveSourceByName` (display_name hit, filename fallback,
  case-insensitive, `updated_at DESC` tiebreak); `replaceLinks` writes both tables for a
  mixed-`[[source:X]]`/`[[Y]]` body and is atomic (source row present only when resolved);
  `listAllLinks`/`listAllSourceLinks` types and ordering.
- `IndexGeneratorTests`: `linksJSONL` emits `type` for both kinds in the fixed key order.
- `MarkdownPreview`/selection: extend a model-level test for `selectSource(byDisplayName:)`
  mirroring the `selectPage(byTitle:)` test.

## Gate

- `swift build` clean; `swift test` green (existing + new).
- **Manual:** in a wiki with a source whose display name is "My Notes":
  1. A page body `See [[source:My Notes]] and [[source:My Notes|the notes]].` — preview
     shows two live links (`the notes` as the second's display); clicking either opens the
     source detail.
  2. `[[source:Ghost Source]]` renders dimmed and is inert.
  3. A page titled `source:foo` is reachable via `[[page:source:foo]]` and NOT hijacked by
     the source registry.
  4. Case-insensitivity: `[[source:my notes]]` resolves the same source.
  5. `links.jsonl` contains both a `type:"page"` and a `type:"source"` row; deleting the
     source removes its rows (Plan 1's cascade) with no error.

## Open decisions (confirm before implementing)

1. **Page-resolution case-insensitivity (Decision 3).** Making `resolveTitleToID`
   case-insensitive is a behavior change for *existing* page links (`[[home]]` now resolves
   to `Home`). **Recommend: yes**, for page/source parity, and audit the resolution tests.
   **Conservative fallback:** keep page resolution case-sensitive, make only source
   resolution case-insensitive, and correct `sources-redesign.md:485`'s "same normalization
   as page titles" to state the divergence. Pick one; it changes one SQL clause and a doc
   line either way.
2. **`[[source:]]` empty target.** Skip (non-link), consistent with `[[ ]]`. (Stated above
   as the choice; flag if you'd rather it be a `.source` link to an empty target — not
   recommended.)
