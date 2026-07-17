Closes #501.

## Summary

Three sub-fixes converting raw-string DB seams to typed enums, eliminating silent-runtime-failure to compile-time-case:

### R2: SourceMarkdownVersion.origin: String to SourceMarkdownOrigin enum

Introduced `enum SourceMarkdownOrigin: String, Sendable, CaseIterable` with five cases (the issue's audit listed three, but grepping every call site revealed two more persisted values):

- `extraction` -- backend extraction (pdf2md, anthropic, gemini, docling)
- `user` -- manual user edit
- `revert` -- revert to an older version
- `source` -- native markdown file seeded from raw bytes
- `transcript` -- media (audio/video) transcription

Updated the SQLite read-decode seam (`sourceMarkdownVersion(from:)`) to use `SourceMarkdownOrigin(rawValue:) ?? .extraction`, the SQL string-compare guard (`row.origin == "extraction"` to `.extraction`), the `appendProcessedMarkdown` protocol + impl signature, all six call sites (SourceCommand, WikiStoreModel, seedNativeMarkdownSources), and both `SourceDetailView` switch sites.

### R3: WorkspaceStatus read path uses rawValue decode

Replaced two raw string compares (`statusStmt.text(at: 0) == "open"`) with `WorkspaceStatus(rawValue: statusStmt.text(at: 0)) == .open` at both sites in SQLiteWikiStore.swift. The `WorkspaceStatus` enum already existed -- the read path just wasn't using it.

### R4: role: String = "cite" to WikiLinkParser.LinkRole enum

Introduced `enum LinkRole: String, Sendable, CaseIterable { case cite, embed }` nested in `WikiLinkParser`. Changed the `sourceLinkPin` default param from `role: String = "cite"` to `role: WikiLinkParser.LinkRole = .cite`, updated the SQL bind (`role.rawValue`), and updated the `WikiLinkParser` dedup key to use `.embed`/`.cite` instead of string literals.

## Test plan

- [x] `swift build` -- clean compile (0 errors)
- [x] `swift test --skip '<fast tier>'` -- 2444 tests passed, 0 failures
