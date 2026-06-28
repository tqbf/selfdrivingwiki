# Share pages and sources via File Provider mount

**Status:** Implemented on `feature/more-share`. 1146 tests pass.
**Depends on:** [`fileprovider-schema-migration-and-cache-warming.md`](fileprovider-schema-migration-and-cache-warming.md) (merged — provides `sourceByNamePrefix` in `WikiFSContainerID`, schema migration, and cache warming).
**Parent design:** none — this is a standalone feature.

## Goal

Add Share to every surface that displays a page or source. The share sheet must
show the full set of sharing services (AirDrop, Mail, Messages, Finder, etc.)
with a human-readable filename — not a raw ULID.

## Decisions

1. **Daemon-resolved URLs, never path-constructed.** `NSSharingServicePicker`
   needs the file UTI synchronously; a cold File Provider cache means path
   resolution fails and the picker shows zero services.  Instead of
   constructing paths from `fileProvider.path + "/pages/by-title/" + leaf`,
   call `getUserVisibleURL` with the item's `page-by-title:<ulid>` or
   `source-by-name:<ulid>` identifier.  The daemon returns the canonical URL
   directly — same mechanism `openSource` already uses.

2. **`source-by-name` for sources, `page-by-title` for pages.** Both views
   produce human-readable filenames: `Thinking is Believing--01KW3S67.pdf`
   instead of `01KW3RQ4B2P2ZS5HYM14P427S0.pdf`.  The daemon handles filename
   escaping — the app never reconstructs it.

3. **Batch share resolves in parallel.** Multi-select (Shift/Cmd-click) in the
   sidebar shows "Share N Pages" / "Share Selected" (sources).  All selected
   item URLs resolve concurrently via `withTaskGroup`, then pass to a single
   `NSSharingServicePicker`.

4. **`Task`-wrapped picker presentation.** `getUserVisibleURL` is async;
   wrap the resolution + picker in a `Task` so the UI stays responsive while
   the daemon responds (sub-millisecond for cached items).

5. **No temp files.** Earlier iterations wrote source bytes to temp files to
   guarantee UTI detection.  The daemon-resolved URL makes that unnecessary —
   the file is always materialized on-demand through the File Provider.

## New methods on `FileProviderSpike`

### `resolvePageByTitleURL(id:) -> URL?`

Resolves the user-visible URL for a page's `page-by-title:<ulid>` identifier
via `getUserVisibleURL`.  Returns `nil` if the domain isn't active.

### `resolveSourceByNameURL(id:) -> URL?`

Same, for a source's `source-by-name:<ulid>` identifier.  Mirrors `openSource`
which uses `source-by-id`.

## Share surfaces

| Surface | Single share | Batch share |
|---|---|---|
| **Page detail** (toolbar button) | `PageDetailView` → `resolvePageByTitleURL` | — |
| **Page sidebar** (context menu) | `SidebarView` → `resolvePageByTitleURL` | Sidebar multi-select → `withTaskGroup` over selected page IDs |
| **Source detail** (toolbar button) | `SourceDetailView` → `resolveSourceByNameURL` | — |
| **Source sidebar** (context menu) | `SourcesSectionView` → `resolveSourceByNameURL` (via `SourceRow.onShare`) | Sidebar multi-select → `withTaskGroup` over selected source IDs (via `SourceRow.onShareSelected`) |

### Button layout in `SourceDetailView`

Left-to-right: Ingest → Extract → Edit → **Share** → **Outline**.
Share sits between Edit and the Outline toggle; Outline is rightmost.

## Removed dead code

- `sourceMountPath(for:)` — path construction replaced by `resolveSourceByNameURL`
- `pageMountPath` (private computed property) — replaced by `resolvePageByTitleURL`
- 5 `sourceMountPath` unit tests — method no longer exists

## Tests

- **`FileProviderSpikeMountPathTests`** (2 tests): schema migration no-op when version matches; `resolvePath` returns without blocking (warmCaches is detached).
- **`ProjectionTests`** cross-module prefix checks (unchanged from fileprovider branch).

## What `feature/fileprovider-schema-migration` provided (merged first)

- Schema version auto-migration (`files` → `sources` rename)
- `sourceByNamePrefix` shared constant in `WikiFSContainerID`
- `warmCaches` (async, top-down directory enumeration after domain activation)
- `migrateDomainsIfNeeded` called before `registerAllDomains` on launch
