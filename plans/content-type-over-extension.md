# Content-Type Over Extension — make `mime_type` authoritative

**Status:** ✅ Implemented (2026-06-21, branch `feature/content-type-over-extension`).
**Parent design:** [`sources-redesign.md`](sources-redesign.md) "Design Principle: Content-Type
Over Extension" (lines 419-475).
**Consumed by:** [`phase-c-source-markdown-projection.md`](phase-c-source-markdown-projection.md)
relies on this for trustworthy PDF-only eligibility. Land this first (or alongside).

## Goal

Kill the remaining extension-based behavioral branches and make the **content-derived
`mime_type`** the single behavioral authority, with the filename extension demoted to a
display/filename hint. This is the plan's own principle (`sources-redesign.md:419`), and it
must hold at the *source* of the data — the `mime_type` column — not just at the branch
sites.

## Why this is its own plan

The principle is cross-cutting: it touches ingest, the File Provider content-type, the
Zotero filter, and the agent extraction gate. Several sites the parent design flagged
(`sources-redesign.md:450-465`) were already converted to MIME in Phase A/B
(`SourceDetailView.isPDF`/`isMarkdownNative`, `AgentOperationRunner`'s PDF gate now read
`mimeType`). This plan covers the **surviving** extension branches and the one that
matters most: `mime_type` itself is currently extension-derived, which makes every
"trust MIME" check circular.

## Decisions (locked)

1. **One content-sniff helper, in core.** Extract `URLIngestService`'s magic-byte sniffer
   into a pure `WikiFSCore` helper used by every ingest path.
2. **`addSource` persists a content-derived `mime_type`.** Sniff the bytes; ext is the
   last-resort fallback only when sniffing is inconclusive.
3. **`WikiFSItem.contentType` is MIME-first.** Carry `mime_type` onto `ProjectedNode` and
   prefer `UTType(mimeType:)`; keep `UTType(filenameExtension:)` as the fallback.
4. **No new extension checks.** Add a house-rule grep guard (an allowlisted test) so the
   pattern can't silently come back.

> **Coordinated with Phase C, not owned here:** the markdown lazy-seed
> (`WikiStoreModel.swift:870`, `guard file.ext == "md"|"markdown"|"txt"`) is an extension
> check, but removing it changes the chain model (markdown sources get no chain). Phase C
> owns that removal for model reasons; this plan does not touch it.

---

## 1. Extract `ContentSniff` into `WikiFSCore`

`URLIngestService.sniffContentType(_:)` (`URLIngestService.swift:161`) sniffs magic bytes
(PDF `%PDF`, PNG/JPEG/GIF/ZIP). Move it (and `normalizedMIME` if shared) into a pure helper:

```swift
/// Sources/WikiFSCore/ContentSniff.swift
public enum ContentSniff {
    /// Content-derived MIME from magic bytes, or nil if inconclusive.
    public static func mimeType(of data: Data) -> String? { … }   // moved from URLIngestService
}
```

`URLIngestService` calls `ContentSniff.mimeType(of:)` instead of its private copy. One
implementation; the store (which has no business depending on `URLIngestService`) can now
sniff too.

## 2. `addSource` makes `mime_type` content-authoritative

`SQLiteWikiStore.swift:861` today derives MIME from the extension:

```swift
let mime = ext.isEmpty ? nil : UTType(filenameExtension: ext)?.preferredMIMEType
```

Add an explicit `mimeType:` override (so `URLIngestService` passes the type it already
sniffed, no double sniff), then sniff the bytes, then fall back to ext:

```swift
// addSource(filename:data:mimeType:zoteroItemKey:zoteroItemTitle:)  — new optional param
let mime = mimeType
    ?? ContentSniff.mimeType(of: data)
    ?? (ext.isEmpty ? nil : UTType(filenameExtension: ext)?.preferredMIMEType)
```

Add `mimeType: String? = nil` to `addSource` and the `WikiStore` protocol declaration;
existing callers compile unchanged. `URLIngestService` passes its sniffed type; drag-drop /
Zotero / folder-import get the byte sniff automatically. **A PDF renamed `.txt` now stores
`application/pdf`** — which is what unblocks reliable PDF-only gating downstream.

### Optional backfill (separate step)

A one-shot migration that re-sniffs `content` for every `sources` row and rewrites
`mime_type` where it differs. Improves existing wikis; not required for correctness going
forward. Gated on its own `user_version` bump.

## 3. `WikiFSItem.contentType` is MIME-first

Today the ingested-file branch (`WikiFSItem.swift:26-29`) derives `UTType` from
`node.ingestedExt`. Carry the source's `mime_type` onto the node and prefer it:

- `ProjectedNode` (`Projection.swift:620-654`): add `let mimeType: String?` (default `nil`
  so the page/index/folder factories are unaffected) and pass `source.mimeType` from
  `sourceNode(for:file:)` (`:441-458`). (Phase C's sibling node sets `mimeType: "text/markdown"`.)
- `WikiFSItem.contentType` ingested branch:

```swift
if node.ingestedExt != nil {                       // an ingested-file leaf
    if let mime = node.mimeType, let t = UTType(mimeType: mime) { return t }
    if let ext = node.ingestedExt, !ext.isEmpty, let t = UTType(filenameExtension: ext) { return t }
    return .data
}
```

MIME first, ext fallback — matching the principle. (The `.md`/`.json`/`.jsonl` name-suffix
branches below are for generated docs whose names we control and stay as-is.)

## 4. Zotero first-pass filter — prefer API `contentType`

`ZoteroClient.swift:284` filters `isIngestable` on `filename.hasSuffix(".pdf")|.md`. Use
the attachment's `contentType` from the Zotero API when present; keep the suffix check only
as a last-resort heuristic. Lower priority — it's a UI filter, not a behavioral gate.

## 5. Stale comment

`AgentOperationRunner.swift:130` — `// end if source.ext == "pdf"`; the code is already
MIME-based (`:63`). Fix the comment.

## 6. House-rule grep guard (enforce "no new ext checks")

Add a test that fails if a new extension-based behavioral branch appears outside an
allowlist. Roughly:

```swift
@Test func noNewExtensionChecks() throws {
    // Behavioral extension checks are a bug (see plans/content-type-over-extension.md).
    // Allowlist: FilenameEscaping (filename construction), WikiFilePanels (.sqlite export),
    // WikiFSItem's generated-doc suffixes (.md/.json/.jsonl on names we control).
    let offenders = try grep(SourcesDir, pattern: #"\.ext ==|ext == \"|hasSuffix\("\.#",
                             allowlist: ["FilenameEscaping", "WikiFilePanels", "WikiFSItem.swift:3"])
    #expect(offenders.isEmpty, "new extension check: \(offenders)")
}
```

(Mirror the project's existing grep-style tests; tune the allowlist to the final set.) This
turns the principle into something a future commit can't quietly violate.

---

## Reconciliation with `sources-redesign.md` "Pre-Existing Extension-Check Bugs"

The parent design (lines 450-475) listed six sites to fix "as part of Phase A." Status:

| Site (plan line) | Now | This plan |
|---|---|---|
| `SourceDetailView:48` `isPDF` | ✅ already `file.mimeType == "application/pdf"` | — |
| `SourceDetailView:44-46` `isMarkdownNative` | ✅ already `mime.hasPrefix("text/")` | — |
| `AgentOperationRunner:63` PDF gate | ✅ already `source.mimeType == "application/pdf"` | stale comment only (§5) |
| `SourceDetailView:480` symbol switch | verify at implement time; switch on `mimeType` if still ext-based | covered by §6 guard |
| `EditorTab:52` tab icon | verify at implement time; switch on `mimeType` | covered by §6 guard |
| `SourceRow:110-115` `symbol(forExtension:)` | verify at implement time; switch on `mimeType` | covered by §6 guard |

So the "severe" behavioral gates were already fixed; this plan closes the **root cause**
(`addSource`), the File Provider content-type, the Zotero filter, and adds the guard. The
three icon-symbol switches should be audited and converted during implementation (they're
cosmetic, but the §6 guard will flag them if left ext-based).

## Tests

- `addSource` stores a content-derived `mime_type`: feed PDF bytes with a `.txt` filename →
  `mime_type == "application/pdf"`. Feed real PNG bytes extension-less → `image/png`.
- `WikiFSItem.contentType` for an ingested source reflects `mimeType` (e.g. a PDF source →
  `application/pdf` UTType), even when `ingestedExt` is wrong/empty.
- The §6 grep guard passes on the current tree (after the §1-5 fixes) and fails if a new
  `.ext ==` is added outside the allowlist.

## Gate

- `swift build` clean; `swift test` green (new tests + the grep guard).
- `grep -rn '\.ext ==\|hasSuffix("\.' Sources/` shows only the allowlisted hits
  (`FilenameEscaping`, `WikiFilePanels`, `WikiFSItem` generated-doc branches).

## Out of scope

- The markdown lazy-seed removal — owned by Phase C (model-driven).
- A `mime_type` backfill migration — optional, separate step (§2).
- Generalizing the sniffer to more types (Office docs, etc.) — add magic bytes as needed;
  the helper is the seam.
