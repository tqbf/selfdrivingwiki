# Connections substrate — Zotero as connection #1

**Status:** Spike built (branch `spike/zotero-as-connection`) — Zotero proven as
connection #1 via a native schema-driven form; coexists with the legacy button.
See "Spike as built" below. Supersedes the "Add from Zotero" button; first
concrete step toward the four-layer origin model in the wiki design pages
*Connections Architecture for Source Ingest* (`01KXNQS1`) and *Source Providers
and Extraction Scripts* (`01KXNXRS`), and resolves issue #483 in favor of native
SwiftUI rendering.

## Decisions locked (2026-07-16)

1. **Rendering: native SwiftUI `SchemaForm` from JSON Schema.** No WKWebView, no
   json-render/JS. The manifest's JSON Schema is the portable, drop-in contract;
   what renders it is native SwiftUI. (Issue #483 "Decision needed" → native.)
2. **Scope this pass: substrate + Zotero only.** Build the Connection
   abstraction (model + app-wide store + Connections sidebar section + a
   connection detail tab + native `SchemaForm` config). Route Zotero through it
   as connection #1. **Defer** script-backed generic providers.
3. **Zotero stays native.** A connection can be *native built-in* or (later)
   *script-backed*. Zotero remains native `ZoteroClient` + native search picker
   (keystroke-latency reason from `plans/zotero-integration.md` still holds).
   Only its **config form** becomes schema-driven.

## What already exists (don't rebuild)

- The materializer seam is done and generalized:
  `SourceMaterializer.materialize() → MaterializedSource →
  WikiStoreModel.storeMaterialized(_:) → store.addSource(provenance:)`.
  `ZoteroMaterializer` is already one conformer of five. **The write path does
  not change.**
- Zotero config/secrets split: non-secret `zotero-config.json` at the app-group
  root (`ZoteroConfig`), API key in Keychain (`KeychainZoteroCredentialStore`,
  service `org.sockpuppet.WikiFS.zotero` / account `zotero-api-key`).
- `ZoteroClient` (search/child metadata), `ZoteroLocalStorage` (local byte
  read), `AddFromZoteroSheet` (search → attachment multi-select picker).

## What's missing (this plan builds)

There is **no Connection concept anywhere** — no model, no store, no tab. Zotero
"works" only because it hard-codes a singleton connection into `ZoteroConfig` +
Keychain. This plan gives that singleton a first-class home and makes the shape
reusable.

## Model (`Sources/WikiFSCore/`)

### `ProviderManifest` — the "Kind" layer

```
struct ProviderManifest {
    let id: String                 // stable identity, e.g. "zotero"
    let displayName: String
    let description: String
    let icon: String               // SF Symbol
    let configSchema: JSONSchema   // rendered by SchemaForm
    let secretFields: Set<String>  // schema fields that go to Keychain, not config JSON
    let capabilities: Capabilities // { supportsBrowse, ... }
    let backing: Backing           // .native | .script(path)  (.script deferred)
}
```

`configSchema` is a **minimal JSON Schema** value type (object → properties, each
`{ type, title, format, enum?, default?, description? }`). Zotero's manifest
declares: `apiKey` (`format: password`, secret), `libraryID` (string),
`zoteroDirOverride` (`format: path`, optional).

### `Connection` — the configured instance

```
struct Connection {
    let id: ConnectionID           // ULID
    let providerID: String         // → manifest
    var label: String              // "Work Zotero"
    var config: [String: JSONValue]// non-secret values, keyed by schema field
    let createdAt: Date
    // secrets NOT here — Keychain, keyed by (connectionID, fieldName)
}
```

### `ConnectionStore` — app-wide persistence

`connections.json` at the app-group container root, sibling to `wikis.json` /
`zotero-config.json`, following `WikiRegistry`'s atomic load/save pattern.
Connections are **app-wide** (matches the existing app-wide Zotero decision);
ingestion still targets the *current* wiki's store. Secrets live in Keychain
keyed by connection ULID + field name.

> Decision (open): app-wide JSON store (recommended, migration-free, matches
> `ZoteroConfig`) vs. a per-wiki SQLite `connections` table (matches the design
> page's Phase-4 sketch but needs a migration and a per-wiki story). Recommend
> JSON now; revisit when script providers + plural browse land.

### `ProviderRegistry`

Returns built-in manifests. One entry this pass: `zotero`. A `.native` provider
supplies factories: `configSchema` (above), a **workspace view** (the picker),
and a **materializer** (`ZoteroMaterializer`, unchanged). `.script(path)` is an
enum case left as a documented stub.

## UI (`Sources/WikiFS/`)

### `SchemaForm.swift` — native JSON Schema → SwiftUI Form

`Form { ForEach(schema.properties) { fieldView } }`, `@State values`, per-field
bindings: `password → SecureField`, `enum → Picker`, `boolean → Toggle`,
`number → numeric TextField`, `path → TextField + NSOpenPanel`, else `TextField`.
On save, secret fields route to Keychain, the rest to the connection's config.
Reusable for every future provider — this is the ~150-line core of #483.

### Connections sidebar section

Add `SidebarSection.connections` (alongside `pages/sources/bookmarks/chats` in
`SidebarView.swift`) → `ConnectionsContainerView`: lists configured connections
(Zotero once configured) + an "Add Connection" affordance (pick a provider kind
→ create → configure). Opening a connection calls `openTab(.connection(id))`.

### Connection detail tab

Add `WikiSelection.connection(ConnectionID)` (`WikiSelection.swift`) + a render
branch in `WikiDetailView` → `ConnectionDetailView`:

- **Unconfigured / editing** → `SchemaForm` over the provider's `configSchema` +
  "Test Connection" (Zotero: `ZoteroClient.verifyConnection()`) + Save.
- **Configured** → the connection's **workspace**. For Zotero: the native search
  picker + attachment multi-select + "Add Selected" — the guts of
  `AddFromZoteroSheet` re-homed from a modal sheet into the tab, driven by the
  resolved `Connection` instead of app-wide `ZoteroConfig`.

### Removals

- The `books.vertical` "Add from Zotero…" header button in
  `SourcesContainerView.swift` (and its `showingAddFromZotero` binding through
  `ContentView` / `SidebarView` / `WikiDetailView`).
- `AddFromZoteroSheet` as a modal — its picker moves into
  `ZoteroConnectionWorkspaceView`.
- **Settings ▸ Zotero** tab folds into the connection's config view (single
  home). (Open decision: remove entirely vs. keep a thin "manage in Connections"
  redirect.)

## Config bridge

Zotero's client/storage stop reading `ZoteroConfig` + `KeychainZoteroCredentialStore`
directly; instead build `ZoteroClient.Config { libraryID, apiKey }` and the
Zotero dir from a resolved `Connection` (config + Keychain). Add a small adapter
`Connection → ZoteroClient.Config` / `→ zoteroDir`.

## Migration

On first load after this lands: if no Zotero connection exists but legacy
`zotero-config.json` `isConfigured`, synthesize a Zotero `Connection` (fixed or
derived ULID) whose config carries `libraryID`/`zoteroDirOverride` and which
reads the existing Keychain item (least-disruptive: reference the legacy key, or
copy it under the connection-scoped account). No data loss; the button-era user
lands with one pre-configured "Zotero" connection.

## The preserved invariant

"Add Selected" still calls `store.ingestFromZotero(...)` → `ZoteroMaterializer` →
`storeMaterialized`. Provenance keeps `agentName = "zotero"`. **Snapshotting the
connection ULID/label into provenance** (the Connections-doc invariant) is
noted-but-deferred: with a single native Zotero connection it isn't yet
load-bearing, and it touches the PROV columns. Revisit when plural connections
or script providers land.

## Phases

1. **Core (pure, tested).** `JSONSchema`, `ProviderManifest`, `Connection`,
   `ConnectionStore`, `ProviderRegistry` (Zotero manifest), the
   `Connection → ZoteroClient.Config` adapter. Unit tests mirror
   `ZoteroConfigTests` / `WikiRegistry` patterns. No UI.
2. **Config surface.** `SchemaForm`, `SidebarSection.connections` +
   `ConnectionsContainerView`, `WikiSelection.connection` +
   `ConnectionDetailView` config mode, legacy migration. Zotero configurable in
   the tab; Settings ▸ Zotero folds/redirects.
3. **Workspace + removals.** Re-home the Zotero picker into
   `ZoteroConnectionWorkspaceView` inside the connection tab; delete the
   "Add from Zotero" button + sheet + threaded bindings. End-to-end: open the
   Zotero connection → search → add → source lands via the unchanged seam.

## Deferred (explicit non-goals this pass)

- Script-backed providers (`manifest.json` in `scripts/`,
  `ProviderScriptMaterializer`, `--list` browse). The `.script` backing case and
  `Capabilities.supportsBrowse` are the seams left for it.
- Per-wiki SQLite `connections` table + `wikictl connection` commands.
- Provenance connection snapshot.
- Plural Zotero connections UI polish (model supports plural; UI ships single).
- WKWebView json-render path (issue #483 — not pursued).

## Spike as built (branch `spike/zotero-as-connection`)

Proves the thesis end to end; the legacy button/Settings are left in place to
compare (a spike proves, then we delete).

**Core (`WikiFSCore`)**
- `ConnectionModel.swift` — `SchemaField`/`ProviderConfigSchema` (defaulting
  decoder), `ProviderManifest`/`ProviderCapabilities`/`ProviderBacking`
  (`.native` | `.script`), `ProviderRegistry` (Zotero manifest decoded from
  **embedded JSON** — the drop-in shape), `Connection` + `ConnectionStore`
  (app-wide `connections.json`).
- `ZoteroConnection.swift` — `Connection → ZoteroClient`/dir adapter + legacy
  `ZoteroConfig` → connection migration.

**UI (`WikiFS`)**
- `SchemaForm.swift` — native JSON-schema → SwiftUI `Form` (the #483 renderer).
- `ConnectionRegistry.swift` — shared `@Observable` app-wide list; seeds/migrates
  the Zotero connection; routes the `apiKey` secret to the existing Keychain item.
- `ConnectionsContainerView.swift` — the **Connections** sidebar section.
- `ConnectionDetailView.swift` — the connection tab: schema config form (Test +
  Save) or workspace.
- `ZoteroConnectionWorkspaceView.swift` — the native search picker re-homed from
  the modal sheet into the tab; still `store.ingestFromZotero` → unchanged seam.

**Wiring** — `WikiSelection.connection(String)` + its 6 exhaustive switches;
`SidebarSection.connections`; `WikiDetailView` render branch.

**Verified** — `swift build` (full package) green; `ConnectionModelTests`
(8 tests) green: manifest JSON decode, store round-trip, corrupt-degrades,
Zotero migration, `isConfigured`, dir override. The manifest-decode test caught
a real bug (a required `secret` key would have made *every* manifest fail to
decode → no connections shown).

### Generalized past Zotero (proves the substrate)

- **Second provider — Folder.** `FolderConnection.swift` + a `folder` manifest
  (one `path` field, no secret); `FolderConnectionWorkspaceView.swift` is a
  native file browser (navigate subfolders, multi-select) that ingests picks
  through the existing `store.addFiles` → `LocalFileMaterializer` seam. Zero
  changes to the tab/sidebar plumbing — a new provider is a manifest + adapter +
  workspace view.
- **Plural connections + Add Connection.** Connections are no longer
  singleton-Zotero: `ConnectionsContainerView` has an **＋ Add Connection** menu
  (`ProviderRegistry.addable`), `ConnectionRegistry.create(providerID:)` mints a
  new instance and opens it in the config form. Multiple folders *and* multiple
  Zotero libraries (one per user ID) are supported; rename distinguishes them.
- **Per-connection credentials.** `ConnectionCredentialStore` keys secrets by
  `(connectionID, field)`, so two Zotero connections hold two independent API
  keys. A compatibility shim maps the auto-migrated `zotero-default` connection's
  `apiKey` to the legacy single-key Keychain item, so current users keep their
  key and the legacy button still reads it.
- Rename works exactly like a page/source: the connection-tab header is an
  `EditableTitle` (double-click / right-click → Rename) → `ConnectionRegistry.rename`
  + `store.retitleTabs`.

**Verified additions:** `ConnectionModelTests` now 11 — folder manifest +
`addable`, tilde-expansion + existence, per-connection credential isolation.

**Spike simplifications (follow-ups):** config values are `[String:String]`
(typed values later); `ConnectionRegistry` is a singleton; connection **deletion**
+ credential cleanup not wired yet; the legacy button/Settings-tab and
`AddFromZoteroSheet` still exist (removal after sign-off).

## Open decisions to confirm before Phase 1

- **Store:** app-wide JSON (recommended) vs per-wiki SQLite table.
- **Settings ▸ Zotero:** remove vs thin redirect.
- **Connection home:** sidebar section (recommended) vs a top-level detail tab
  only vs a Settings tab.
- **Plural now:** ship single Zotero connection UI vs allow multiple immediately.
