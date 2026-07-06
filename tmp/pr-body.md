## Graph-model Phase 4 foundation: `sources.role` + `source_links` rebuild (v22) + media filtering

Lands the **storage substrate** for graph-model Phase 4 (Media & roles): schema
v22 adds `sources.role` (`'primary'` | `'media'`) and rebuilds `source_links`
into the §4.4 rowid + role/pin shape, plus the one demoable behavior — **media
sources are filtered out of the main Sources list**.

### Schema (v22)

Two additive, data-preserving changes inside one `migrateV21ToV22()` transaction:

- **`sources.role TEXT NOT NULL DEFAULT 'primary'`** — `ALTER TABLE ADD COLUMN`
  applies the default to every existing row (the backfill *is* the default).
- **`source_links` rebuild** (mirrors the shipped v10→v11 pattern): drops the
  composite PK (rowid table per §4.4), adds `role TEXT NOT NULL DEFAULT 'cite'` +
  `pinned_version_id TEXT`, and creates the `source_links_edge` unique index on
  `(from_page_id, to_source_id, role, COALESCE(pinned_version_id, ''))`. The
  COALESCE restores the v11 dedup semantics (SQLite treats NULLs as distinct).

### Value type + read/write paths

New `SourceRole` enum (`.primary`/`.media`, modeled on `RefKind`);
`SourceSummary.role` + `isPrimary` seam; the central `sourceSummary(from:)`
decoder + all six SELECTs (incl. both search paths) append `role`;
`addSource`/`addBytelessSource` write the column (defaulted `role:` param). The
`WikiStore` protocol requirement gains `role` (undeclared-defaulted — the 3
existential call sites in `WikiStoreModel` pass `.primary` explicitly).

### Media filtering

`SourcesContainerView.visibleSources` applies `.filter { $0.isPrimary }` — a
`.media` source never appears in the main Sources list or its search.

### Bug fix found in testing

The `FreshSchemaParityTests.columns`/`fks` helpers used `PRAGMA table_info table`
(no parens) which silently failed to prepare — they always returned `[]`. Fixed
to `PRAGMA table_info(table)`. The parity fingerprint test passed vacuously (both
paths produced empty column lists); it now actually compares column/FK data.

### Deferred to the second Phase 4 handoff

`![[source:…]]` embed parsing, render-by-content-type dispatch, sibling
`original_path` resolution, and the transcript-level `apple-ttml` extract PROV.

### Tests

1577 tests green (+5 new). No `changeToken` change (default column doesn't move
the token for existing rows).
