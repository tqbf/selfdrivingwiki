# Plan: Typed Page-Author Provenance (#797) — Phase 1

## Summary

Create a typed `PageAuthor` enum and `AgentKind` enum in `WikiFSTypes` as the
single source of truth for the `agents.name` / `agents.kind` string conventions.
Route every construction and parse site through them. Fix the three `nil`-author
leaks that silently destroy chat/agent provenance by degrading to `legacy-import`.

**No DB migration** — `agents.name` and `agents.kind` values are byte-identical;
only how Swift builds and reads them changes.

## Problem

The page-version author string (`agents.name`: `"user"`, `"chat:<id>"`,
`"agent:<kind>"`, `"legacy-import"`) is enforced by string discipline scattered
across the codebase with no single source of truth:

- **Construction**: `AgentLauncher.authorForRun(kind:chatID:)` (`AgentLauncher.swift:2623`)
  is the canonical builder, but `chat:<id>` is also built inline at
  `AgentLauncher.swift:2870`, bypassing the helper.
- **Parsing**: duplicated in 3 places — `GRDBWikiStore.authorKind(_:)`
  (`:2633`), the `pageOrigin` SQL `substr(a.name, 6)` (`:4494`), and
  `ProvenancePanel` `hasPrefix("chat:")` (`:195`).
- **Nil-leak bug**: `ensurePageAuthorAgent(nil)` (`:2647`) maps nil/empty to the
  shared `legacy-import` agent. Three callers pass nil:
  1. Rename — `WikiStoreModel.swift:1780` (`updatePage(..., lastEditedBy: nil)`)
  2. Preflight lint auto-fix — `WikiStoreModel.swift:1494` (`PageUpsert.upsert` with no author)
  3. Daemon Home bootstrap — `WikiDaemon.swift:64` (`createPage(createdBy: nil)`)

Consequence: a page a chat wrote, once renamed or lint-fixed in-app, loses its
`chat:` HEAD provenance and flips to `legacy-import`.

## Design

### New: `Sources/WikiFSTypes/PageAuthor.swift`

```swift
/// Typed identity for a page-version author. Single source of truth for the
/// `agents.name` convention: `user`, `chat:<id>`, `agent:<kind>`,
/// `legacy-import`. Every construction and parse site routes through here.
public enum PageAuthor: Equatable, Hashable, Sendable {
    case user                  // "user"
    case chat(String)          // "chat:<ulid>"
    case agent(String)         // "agent:<kind>" (ingest/lint/query/bootstrap/…)
    case legacyImport          // "legacy-import"
    case other(String)         // preserved verbatim (forward compat)

    /// The canonical string stored in `agents.name`.
    public var rawValue: String { ... }

    /// Parse a stored `agents.name` value. nil/"" -> .legacyImport.
    public init(rawValue: String?) { ... }

    /// Classification for the `agents.kind` column.
    public var agentKind: AgentKind { ... }

    /// The chat ID when this is `.chat`, else nil.
    /// Replaces the SQL `substr(a.name, 6)` logic at the Swift layer.
    public var chatID: String? { ... }
}
```

Parsing rules for `init(rawValue:)`:
- nil or empty → `.legacyImport`
- `"user"` → `.user`
- `"legacy-import"` → `.legacyImport`
- `chat:` prefix → `.chat(String(dropFirst(5)))` — drop the 5-char `"chat:"` prefix
- `agent:` prefix → `.agent(String(dropFirst(6)))` — drop the 6-char `"agent:"` prefix
- anything else → `.other(rawValue)`

The `chat:` prefix comes from `ResourceKind.chat.linkPrefix` (which is `"chat:"`).
Use it in `rawValue` for construction to avoid a hardcoded literal.

### New: `Sources/WikiFSTypes/AgentKind.swift`

```swift
/// The `agents.kind` taxonomy — who/what performed the activity.
/// Stored in the `agents.kind` TEXT column.
public enum AgentKind: String, Equatable, Hashable, Sendable, CaseIterable {
    case human    = "human"
    case chat     = "chat"
    case agent    = "agent"
    case software = "software"
    case model    = "model"

    /// Parse a stored `agents.kind` value; unknown -> .software (historical default).
    public init(rawValue: String?) { ... }
}
```

### Route existing sites through the enums

| Site | File (approx line) | Change |
|------|--------------------|--------|
| `authorForRun(kind:chatID:)` | `Sources/WikiFSEngine/AgentLauncher.swift:2623` | Build via `PageAuthor` then return `.rawValue` |
| Inline `chat:<id>` construction | `Sources/WikiFSEngine/AgentLauncher.swift:2870` | Replace with `PageAuthor.chat(chatID).rawValue` |
| `authorKind(_:)` | `Sources/WikiFSCore/Store/GRDBWikiStore.swift:2633` | Thin shim: `PageAuthor(rawValue: author).agentKind.rawValue` |
| `ProvenancePanel` tap handler | `Sources/WikiFS/Detail/ProvenancePanel.swift:~195` | Use `PageAuthor(rawValue:)` + switch on case + `.chatID` for navigation |
| `ProvenancePanel` context menu | `Sources/WikiFS/Detail/ProvenancePanel.swift:~116` | Same pattern for `navigableSource(_:)` |

For `authorKind(_:)`, keep the existing signature `private func authorKind(_ author: String?) -> String`
so `appendPageVersionLocked` and other callers are untouched — just rewrite the body.

> **Note — source-origin parse sites (deferred to Phase 2).** Two additional sites
> compare against the `"legacy-import"` string in the **source-provider** display
> path, not the page-author path: `SourceDetailView.swift:565`
> (`origin.agentName != "legacy-import"`) and `SourceMaterializer.swift:179`
> (`case "legacy-import": return "Imported"` in `displayLabel`). These parse
> `SourceOrigin.agentName` (provider identity), not `PageAuthor`. They are
> properly addressed by the `SourceProvider` enum (Phase 2). In Phase 1 the
> `"legacy-import"` literal is identical regardless of which enum owns it;
> changing it would require updating both enums simultaneously.

### Fix the nil-author leaks

| Site | File (approx line) | Current | Fix |
|------|--------------------|---------|-----|
| Rename | `Sources/WikiFSCore/Store/WikiStoreModel.swift:1780` | `lastEditedBy: nil` | `lastEditedBy: PageAuthor.user.rawValue` |
| Preflight lint auto-fix | `Sources/WikiFSCore/Store/WikiStoreModel.swift:1494` | `PageUpsert.upsert(...)` with no `author:` (defaults to nil) | Pass `author: PageAuthor.agent("lint").rawValue` |
| Daemon Home bootstrap | `Sources/wikid/WikiDaemon.swift:64` | `createdBy: nil` | `createdBy: PageAuthor.user.rawValue` |

For the lint auto-fix: `PageUpsert` is defined in `Sources/WikiFSCore/Core/PageUpsert.swift:17`
and its `upsert` method already has `author: String? = nil` in its signature
(`PageUpsert.swift:48-55`). **No signature change needed** — just add
`author: PageAuthor.agent("lint").rawValue` to the existing call at `WikiStoreModel.swift:1494`.
(Another call at `WikiStoreModel.swift:1355` already passes `author: "user"`, confirming
the parameter is in active use.)

### SQL subqueries (documented exceptions — do NOT change)

These 4 SQL sites use `substr(a.name, 6)` + `LIKE 'chat:%'` to strip the chat
prefix inside SQL (which can't call Swift). They stay as-is. Add a one-line
comment at each:

> `// Raw 'chat:' prefix stripping — format owned by PageAuthor.chat(_:).rawValue.`
> `// Do not change the prefix without updating PageAuthor too.`

Sites:
- `pageOrigin` (`GRDBWikiStore.swift:~4494`)
- `pageEditHistory` (`GRDBWikiStore.swift:~4546`)
- `sourceOrigin` (`GRDBWikiStore.swift:~3449`)
- `sourceEditHistory` (`GRDBWikiStore.swift:~3495`)

## Module placement: `WikiFSTypes`

Both new files go in `Sources/WikiFSTypes/` (the shared leaf target alongside
`ResourceKind.swift` and `MimeType.swift`). Rationale:
- Pure value types, no dependencies.
- `PageAuthor.chat(_)` references `ResourceKind.chat.linkPrefix` — same target.
- Visible to `WikiFSCore` (GRDBWikiStore), `WikiFSEngine` (AgentLauncher), and
  `WikiFS` (ProvenancePanel) without pulling new dependency edges.

## Acceptance criteria

- **AC.1** — `PageAuthor(rawValue: a.rawValue) == a` for every case (round-trip identity).
- **AC.2** — `init(rawValue:)` parses each convention correctly: nil/"" → `.legacyImport`,
  `"user"` → `.user`, `"legacy-import"` → `.legacyImport`, `"chat:01J…"` → `.chat("01J…")`,
  `"agent:lint"` → `.agent("lint")`, unknown → `.other(rawValue)`.
- **AC.3** — `agentKind` maps correctly: `.user` → `.human`, `.chat(_)` → `.chat`,
  `.agent(_)` → `.agent`, `.legacyImport` → `.software`, `.other(_)` → `.model`.
- **AC.4** — Rename a chat-authored page → HEAD author is `"user"`, not `"legacy-import"`.
  Prior version retains `chat:<id>`.
- **AC.5** — Preflight lint auto-fix → HEAD author is `"agent:lint"`, not `"legacy-import"`.
- **AC.6** — Daemon bootstrap `createPage` → author is `"user"`, not `"legacy-import"`.
- **AC.7** — `AgentKind(rawValue:)` round-trips all 5 cases; unknown → `.software`.
- **AC.8** — Existing `PageVersionTests` and provenance tests stay green (no `agents.name`
  value changes except at the 3 fixed leak sites).

## Test strategy

| AC | Test | Location |
|----|------|----------|
| AC.1 | Property test: round-trip every case | `Tests/WikiFSTests/PageAuthorTests.swift` |
| AC.2 | `init(rawValue:)` edge cases (nil, "", each prefix, unknown) | `Tests/WikiFSTests/PageAuthorTests.swift` |
| AC.3 | `agentKind` mapping for each case | `Tests/WikiFSTests/PageAuthorTests.swift` |
| AC.4 | Rename chat-authored page → read `pageOrigin` → assert `"user"` | Store integration test (existing test file or new) |
| AC.5 | Preflight lint auto-fix → assert `"agent:lint"` | Store integration test |
| AC.6 | Daemon `createPage` → assert `"user"` | Store integration test |
| AC.7 | `AgentKind` round-trip + unknown fallback | `Tests/WikiFSTests/PageAuthorTests.swift` |
| AC.8 | Full `swift test` suite green (no regressions) | Existing suite, unmodified |

**`chatID` accessor** (not a standalone AC but covered in PageAuthorTests): `.chat("01J…")`
→ `"01J…"`, all other cases → nil.

## Files touched

**New:**
- `Sources/WikiFSTypes/PageAuthor.swift`
- `Sources/WikiFSTypes/AgentKind.swift`
- `Tests/WikiFSTests/PageAuthorTests.swift`

**Edit:**
- `Sources/WikiFSEngine/AgentLauncher.swift` — `authorForRun` (`:2623`) + inline (`:2870`)
- `Sources/WikiFSCore/Store/GRDBWikiStore.swift` — `authorKind(_:)` shim (`:2633`) + 4 SQL comments
- `Sources/WikiFSCore/Store/WikiStoreModel.swift` — rename (`:1780`) + lint (`:1494`, pass existing `author:` param — no signature change needed)
- `Sources/wikid/WikiDaemon.swift` — bootstrap (`:64`)
- `Sources/WikiFS/Detail/ProvenancePanel.swift` — tap handler (`:~195`) + context menu (`:~116`)

## Build & test commands

```bash
cd /Users/wsargent/work/selfdrivingwiki
make prompts && swift build          # compile (make prompts regenerates GeneratedPrompts.swift)
swift test --filter PageAuthorTests  # new unit tests
swift test                           # full suite (~1.5 min) — run before PR
```

CI runs `make version prompts` before `swift build`; bare `swift build` does NOT
regenerate. Run `make prompts` first when building locally.

## Out of scope (future PRs)

- `SourceProvider` enum (source origin taxonomy — Phase 2), which will route `SourceDetailView.swift:565` and `SourceMaterializer.swift:179` through a typed enum instead of raw `"legacy-import"` comparisons.
- `SourceContentType` enum (content type taxonomy — Phase 3)
- DB CHECK constraints on `agents.kind` / `sources.role` (migration v42+)
- Backfilling pre-v39 `legacy-import` pages (author never recorded — impossible)
- Provenance-panel UI improvements (done in #796)
