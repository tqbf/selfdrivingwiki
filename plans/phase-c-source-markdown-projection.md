# Phase C — Source Markdown in the File Provider (implemented correctly)

**Status:** Ready to implement **after** [`fix-phase-a-source-bugs.md`](fix-phase-a-source-bugs.md)
and [`phase-b-source-wikilinks.md`](phase-b-source-wikilinks.md) have landed.
**Parent design:** [`sources-redesign.md`](sources-redesign.md) Feature 2 (lines 161-208)
and the Phase C bullet (lines 405-408).
**Why a separate plan:** the parent design's Phase C assumes two mechanisms that are not
true in the current code, and one eligibility rule that contradicts the intended model.
This plan re-states Phase C so it is internally consistent and grounded in the real code.
It supersedes the Phase C portion of `sources-redesign.md` wherever they conflict
(conflicts called out below).

## Depends on

- **Plan 1** (`fix-phase-a-source-bugs.md`) — `source_links` cascade + the `sources.jsonl`
  projection-name fix. Not strictly required for Phase C to compile, but land it first so
  the sources tree is consistent.
- **Plan 2** (`phase-b-source-wikilinks.md`) — the rename and `source_markdown_versions`
  table are in place (Phase A/B merged). Phase C builds on those names.

## The model (from design intent — load-bearing)

1. **Only PDF sources have a processing chain.** The `source_markdown_versions` table holds
   the git-lite history of a PDF→markdown *conversion* and the user's edits to it. Markdown
   sources are verbatim-only — there is no "processed markdown" for a file that is already
   markdown.
2. **The chain is internal history; everyone else sees only HEAD.** The File Provider, the
   agent, and the CLI see the latest version (`MAX(id)`). The version history powers revert
   (shipped: `revertProcessedMarkdown`) and compare (future UI feature, out of scope here).
3. **Content type drives behavior, never the filename extension.** `mime_type` is the
   behavioral authority; `ext` is a display/filename hint only. This is the plan's own
   "Content-Type Over Extension" principle (`sources-redesign.md:419-475`) — and it must
   hold at the *source* of the data, not just at the branch sites.

## Decisions (locked)

These overturn or sharpen the parent design.

1. **`mime_type` is content-authoritative** — owned by
   [`content-type-over-extension.md`](content-type-over-extension.md), which makes
   `addSource` sniff the bytes and `WikiFSItem.contentType` MIME-first. Phase C's "only PDFs
   have chains" model (Decision 2) and the sibling eligibility (Decision 4) are only
   trustworthy once `mime_type` is content-derived, so **land that plan first**.
2. **Remove the markdown lazy-seed.** `WikiStoreModel.processedMarkdownHead(for:)`
   (`:865-877`) seeds a v1 from a markdown source's own verbatim bytes. That contradicts the
   model (no chain for markdown) and is the one ext-check bug that, under the parent
   design's projection rule, would project a colliding `<id>.md` sibling next to the
   verbatim `<id>.md`. Removing it makes "only PDFs have chains" true by construction.
3. **The change bridge must see chain edits.** Fold `source_markdown_versions` into
   `changeToken()` and version the sibling node off the HEAD row, so extraction / edit /
   revert refresh the mount. The parent design's "change bridge signals → File Provider
   refreshes the `.md` sibling" (`sources-redesign.md:206`) is false without this.
4. **Eligibility for the projected sibling is `hasProcessedMarkdown`** (after Decision 2,
   only PDFs can satisfy it). Project the sibling in **both** `by-id` and `by-name`, with
   proper identity prefixes (the parent design specified only the by-id prefix).
5. **The sibling serves HEAD only**, as `text/markdown`, size and version derived from the
   HEAD version row — never from the `sources` row.

---

## 1. Prerequisite — content-authoritative `mime_type`

Phase C assumes `source.mimeType` is trustworthy (PDF detection, eligibility). That work —
extracting a `ContentSniff` helper, making `addSource` sniff the bytes instead of trusting
the extension (`SQLiteWikiStore.swift:861`), MIME-first `WikiFSItem.contentType`, and a grep
guard against new extension checks — is owned by
[`content-type-over-extension.md`](content-type-over-extension.md). **Land it first.**

The one extension check Phase C *does* own is the markdown lazy-seed
(`WikiStoreModel.swift:870`), removed in §4 for model reasons — it's an extension check, but
its removal is about the chain model (no chains for markdown), not about MIME-vs-ext, so it
stays here. The other surviving checks (the stale `AgentOperationRunner.swift:130` comment,
`ZoteroClient.swift:284`) belong to the content-type plan.

---

## 2. Change bridge — make chain edits move the anchor

### 2.1 Fold `source_markdown_versions` into `changeToken()`

`SQLiteWikiStore.swift:564-570` returns a 7-component token
`pCount:pSum:fCount:fSum:spVersion:logCount:idxVersion`. None of those move when
`appendProcessedMarkdown` (`:1412`) or `revertProcessedMarkdown` (`:1440`) inserts a version
row, because neither touches `sources.version`/`sources.updated_at`. Add a resilient count
helper (mirroring `logRowCount`, `:600-607`) as an 8th token component.

```swift
private func sourceMarkdownVersionCount() -> Int64 {
    guard let stmt = try? statement("SELECT COUNT(*) FROM source_markdown_versions;") else { return 0 }
    defer { stmt.reset() }
    guard (try? stmt.step()) == true else { return 0 }
    return stmt.int(at: 0)
}
// in changeToken():
let smvCount = sourceMarkdownVersionCount()
return "\(pCount):\(pSum):\(fCount):\(fSum):\(spVersion):\(logCount):\(idxVersion):\(smvCount)"
```

`COUNT(*)` moves on any extraction / user-edit / revert (each appends a row), which is all
the git-lite model needs. *(Existing `changeToken` tests will need the new component
appended — they assert the full token string.)*

### 2.2 Signal on every write path

- **CLI** (`wikictl source edit-markdown`, §5): posts the per-wiki Darwin notification
  (`signalChange`) after the append, like every other `wikictl` write.
- **In-app** (`SourceDetailView` save → `saveProcessedMarkdown`): confirm the save path
  triggers the change bridge (the model's existing post-save signal). With §2.1 the anchor
  now moves, so the signal actually carries the change.

---

## 3. Projection — the `.md` sibling

### 3.1 Identity prefixes + parsers

The parent design specified only `sourceMarkdownByIDPrefix`. Add both, with constructors
and a parser (parity with the verbatim source identity, `Projection.swift:76-110`):

```swift
// in Projection.Identity
static let sourceMarkdownByIDPrefix   = "source-markdown-by-id:"
static let sourceMarkdownByNamePrefix = "source-markdown-by-name:"

static func sourceMarkdownByID(_ ulid: String)   -> NSFileProviderItemIdentifier { … }
static func sourceMarkdownByName(_ ulid: String) -> NSFileProviderItemIdentifier { … }

// parse either markdown prefix → ulid (mirrors the fileULID/pageULID helpers)
static func sourceMarkdownULID(from id: NSFileProviderItemIdentifier) -> String? { … }
```

### 3.2 The sibling node — versioned off HEAD, not the source row

Add `sourceMarkdownNode(for:source:head:)`. It takes the **HEAD** version (not just the
`SourceSummary`) so size and version track the chain, not the (unchanging-on-edit) source
row:

```swift
static func sourceMarkdownNode(
    for id: NSFileProviderItemIdentifier,
    source: SourceSummary,
    head: SourceMarkdownVersion
) -> ProjectedNode {
    let raw = id.rawValue
    let isByName = raw.hasPrefix(Identity.sourceMarkdownByNamePrefix)
    let name = isByName
        ? FilenameEscaping.byNameSourceFilename(filename: source.filename, ext: "md", sourceID: source.id.rawValue)
        : "\(source.id.rawValue).md"
    let body = Data(head.content.utf8)
    let parent = isByName ? Identity.sourcesByName : Identity.sourcesByID
    // contentVersion/metadataVersion from the HEAD row: a new HEAD (edit/revert/extraction)
    // changes these, so the daemon re-fetches contents after the anchor in §2.1 moves.
    let v = Data(head.id.rawValue.utf8)
    return .file(id: id, parent: parent, name: name, size: body.count,
                 version: v,
                 metadataVersion: Data("\(head.id.rawValue)|\(head.createdAt.timeIntervalSince1970)".utf8),
                 created: head.createdAt, modified: head.createdAt,
                 ingestedExt: "md")   // → served as text/markdown (see §3.4)
}
```

> Why both `version` and `metadataVersion` off HEAD: the anchor (§2.1) tells the enumerator
> *something* in the DB changed; the per-item `contentVersion` tells it *this* sibling's
> bytes changed. Both are needed — anchor alone leaves the daemon serving stale contents.
>
> **The sibling's `contentVersion` must differ from the verbatim node's `contentVersion`.**
> The verbatim node versions off `Data(String(file.version).utf8)` — the source row version.
> The sibling versions off `Data(head.id.rawValue.utf8)` — the HEAD version id. These are
> naturally distinct (different types, different values), so the daemon can tell them apart
> and re-fetches the sibling when a new HEAD row is appended.

### 3.3 Enumeration — emit the sibling for eligible sources, without N+1

`sourceNodes(byName:)` (`Projection.swift:559-570`) currently maps each source to one
verbatim node. Extend it to also emit a sibling when the source has a chain. To avoid an
N-queries-per-source penalty (run twice per enumeration, plus the working set), fetch the
HEAD for every source-with-a-chain in **one** query and join in memory:

```swift
private func sourceNodes(byName: Bool) -> [ProjectedNode] {
    guard let store = openReadStore(),
          let files = try? store.listAllSourcesOrderedByID() else { return [] }
    // One query: sourceID → HEAD, for every source that has a chain.
    let heads = (try? store.processedMarkdownHeadsBySource()) ?? [:]  // new, §3.5
    return files.flatMap { row -> [ProjectedNode] in
        let summary = SourceSummary(id: PageID(rawValue: row.id), filename: row.filename, ext: row.ext,
                                    mimeType: row.mime, byteSize: row.byteSize,
                                    createdAt: row.createdAt, updatedAt: row.updatedAt, version: row.version)
        let vid = byName ? Identity.sourceByName(row.id) : Identity.sourceByID(row.id)
        var nodes = [Self.sourceNode(for: vid, file: summary)]   // verbatim, always
        if let head = heads[row.id] {                            // has a chain → sibling
            let mid = byName ? Identity.sourceMarkdownByName(row.id) : Identity.sourceMarkdownByID(row.id)
            nodes.append(Self.sourceMarkdownNode(for: mid, source: summary, head: head))
        }
        return nodes
    }
}
```

Eligibility is simply "has a HEAD" (after Decision 2, only PDFs can). `heads` is keyed by
source id; the verbatim node is always emitted, so the original bytes remain reachable
(satisfying `sources-redesign.md:185`).

### 3.4 `contents(for:)` serves HEAD; contentType is explicit

In `contents(for:)` (`Projection.swift:576-615`), before the verbatim-source branch:

```swift
if let ulid = Identity.sourceMarkdownULID(from: id) {
    guard let store = openReadStore(),
          let head = try? store.processedMarkdownHead(sourceID: PageID(rawValue: ulid)) else { return nil }
    return Data(head.content.utf8)
}
```

`WikiFSItem.contentType` (`:19-30`) already falls back to markdown for any `.md` name
(`:30`); setting `ingestedExt: "md"` on the sibling (§3.2) makes it explicit and avoids
relying on the suffix — consistent with the content-type-over-extension principle.

### 3.5 One-query HEAD read

Add to `SQLiteWikiStore` (not the protocol — a read-projection helper, like
`listAllLinks`):

```swift
/// sourceID → HEAD version, for every source that has a chain. One query for the
/// whole projection (avoids N+1 in `sourceNodes`). Ordered so the dict is built once.
public func processedMarkdownHeadsBySource() throws -> [String: SourceMarkdownVersion] { … }
// e.g. SELECT m.* FROM source_markdown_versions m JOIN (SELECT file_id, MAX(id) mid
//      FROM source_markdown_versions GROUP BY file_id) h ON m.id = h.mid;
```

---

## 4. Delete the markdown lazy-seed (Decision 2, detail)

`WikiStoreModel.processedMarkdownHead(for:)` (`:865-877`) becomes:

```swift
public func processedMarkdownHead(for file: SourceSummary) -> SourceMarkdownVersion? {
    try? store.processedMarkdownHead(sourceID: file.id)
}
```

No seeding branch. A markdown source now has no chain (matching the model); a PDF source
gets its chain from extraction (`seedPdfMarkdown`, `:894-903`, origin `"extraction"`).
`saveProcessedMarkdown` (`:886-891`, origin `"user"`) still appends user edits to a PDF's
existing chain. **Collision is impossible by construction**: PDF verbatim is `<id>.pdf`,
sibling is `<id>.md`.

> If a future extraction target is itself markdown-ext, revisit the sibling filename then.
> Do not pre-engineer a disambiguator now.

---

## 5. CLI — `wikictl source edit-markdown`

Add to `SourceCommand` (`Sources/WikiCtlCore/SourceCommand.swift`), alongside `.list` /
`.cat` / `.export`:

```swift
case editMarkdown(Selector, content: String)   // body text from --content or --file
```

Resolution reuses the existing `Selector` resolver (`:152`). Behavior:

1. Resolve selector → `PageID`.
2. Require an existing chain (extraction baseline must exist first): if
   `hasProcessedMarkdown(sourceID:)` is false, error
   `"no processed markdown for <id>; extract first"`. This matches the git-lite flow
   (extraction seeds v1; edits append) and refuses to create a chain for a non-PDF.
3. Append a `"user"` version via `appendProcessedMarkdown(sourceID:content:origin:"user":note:nil)`.
4. `signalChange()` so the mount refreshes (§2.1 makes the anchor actually move).

Wire the `@Argument`/`--content`/`--file` parsing in the `wikictl` command layer (mirroring
how other commands read `--file <path>` into a string). The app's in-app editor
(`SourceDetailView` → `saveProcessedMarkdown`) is the other write path and is unchanged.

---

## 6. Index + agent prompt (locked)

- **`sources.jsonl`** (`IndexGenerators.swift:142-`): add a `has_markdown` boolean so the
  agent can discover which sources have a `.md` sibling without `ls`-ing. Additive; update
  `IndexGeneratorTests`. (After Decision 2, `has_markdown` is true only for extracted PDFs.)
- **`SystemPrompt`** (`SystemPrompt.swift`): document the `.md`-sibling convention — for a
  source with processed markdown, a `<id>.md` sibling holds the latest conversion/edit and
  is the one to `Read` in preference to the raw PDF. One line in the prompt's sources
  section.

---

## Tests

- **`SQLiteWikiStoreTests`**:
  - `changeToken` gains the `smvCount` component and advances on
    `appendProcessedMarkdown` / `revertProcessedMarkdown` (it does not today).
  - `addSource` sets `mime_type` from bytes (sniff), e.g. a PDF fed with a `.txt` filename
    still stores `application/pdf`.
  - `processedMarkdownHeadsBySource` returns the right HEAD per source.
- **`WikiStoreModelTests`** (or equivalent): `processedMarkdownHead(for:)` for a `.md`
  source returns nil and creates **no** chain (regression test for the lazy-seed removal).
- **Projection** (File Provider test target): a PDF source with a chain projects TWO nodes
  in `by-id` and `by-name` (`<id>.pdf` + `<id>.md`); a PDF without a chain projects one; a
  `.md` source projects one (no sibling). `contents(for: <md sibling id>)` serves the HEAD
  text; editing the chain changes the node's `contentVersion`.
- **`SourceCommandTests`**: `edit-markdown` appends a `"user"` version; refuses when no
  chain exists.

## Gate

- `swift build` clean; `swift test` green (update the `changeToken` assertion + new tests).
- **Manual (signed mount):**
  1. Ingest a PDF → Extract Markdown → a `<id>.md` sibling appears under `sources/by-id/`
     and `sources/by-name/`; `cat` shows the extracted text.
  2. Edit the markdown in-app (or `wikictl source edit-markdown`) → `cat` of the sibling
     updates **without a relaunch** (validates §2.1 + §2.2 + §3.2 versioning).
  3. Revert to an older version → the sibling reflects the reverted content.
  4. A `.md` source projects a single verbatim node (no sibling, no collision).
  5. A PDF misnamed `.txt` still extracts (validates §1.2 — `mime_type` is content-derived).

## Out of scope

- **Compare** (diff two stored versions) — future UI feature over
  `processedMarkdownHistory`; the mount stays HEAD-only.
- **Phase D** display-name editing — when it lands, the by-name sibling switches from
  `filename` to `display_name` for its stem (one-line change in §3.2).
- A backfill migration to re-sniff existing rows' `mime_type` (§1.2 note) — optional.
- Generalizing extraction beyond PDF — the design leaves room (eligibility keys on
  `hasProcessedMarkdown`, not on `ext`/`mime`), but only PDFs produce chains today.

## Open decisions (all locked)

1. **`smvCount` vs `MAX(id)` in the token.** ✅ `COUNT(*)` — simpler, matches `logRowCount`.
   Either moves on any append.
2. **`edit-markdown` when no chain exists.** ✅ Refuse ("extract first"). Seeding a `"user"` v1
   muddies the "extraction is the baseline" model.
3. **`has_markdown` in `sources.jsonl`.** ✅ Yes. One boolean, cheap to compute, saves the agent
   from `ls`-ing sources to discover which have processed markdown.
