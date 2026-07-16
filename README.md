# Self Driving Wiki

![SDW Screen Shot](SDW.png)

A native **macOS SwiftUI wiki**, backed by **SQLite**, mirrored **read-only** onto
the filesystem by a **File Provider extension** — and now a **self-maintaining LLM
wiki**. A user keeps **many** wikis (a personal one, a research one, a per-book
one); for each wiki an LLM (`claude -p`, run from the app as **Ingest / Ask /
Edit / Lint**) authors and maintains the content: it *reads* the wiki through `wikictl` (DB-direct) and
*writes* it through the same `wikictl` CLI. The File Provider mount is an optional
read-only projection — useful for browsing in Finder, but not required for the agent. The human curates sources and asks
questions; the agent does the bookkeeping (summary/entity/concept pages,
`[[wiki-links]]`, a curated `index.md`, a chronological `log.md`).

It runs **locally only** — free local dev signing, no Developer ID / notarization
needed to build and run it yourself.

---

## The non-negotiable invariant

> **SQLite is the source of truth. The File Provider mount is READ-ONLY and
> optional. Both reads and writes go through `wikictl` (DB-direct). Never make
> the mount writable.**

This is the whole point of the proof-of-concept. The File Provider extension is
*part of the design*, not a convenience — do **not** replace it with a plain-folder export.
The agent reads via `wikictl` (DB-direct), so the mount is not required for the agent
to function; it exists for the UI page reader and Finder integration. Making the mount writable
(implementing `createItem`/`modifyItem` write-back) would dissolve the invariant
that the project exists to demonstrate. The split is deliberate:

```
  claude -p ──reads──>  wikictl  ──reads──>  SQLite (App Group DB)
        │                                                 │ (optional read-only projection)
        └──writes──>  wikictl  ──writes──>  SQLite  ──projects──>  File Provider mount
                          │
                          └── Darwin notification ──> app: refresh sidebar + signalChange()
```

---

## Quick start

### Prerequisites

- **macOS 14+** (the appex targets macOS 14; this was developed/gated on macOS 26).
- A **Swift 6 toolchain** — Xcode from the App Store, or the swift.org toolchain.
  Xcode is only a toolchain provider here (`swift`, `codesign`); there is **no
  `.xcodeproj`, no `xcodebuild`, no XcodeGen** — the build is `swift build` +
  [`build.sh`](build.sh).
- For the **signed install path** (the only way the File Provider extension
  actually loads): an **Apple Development certificate** in your keychain plus the
  **App Group** + **File Provider** provisioning profiles under `signing/`. The
  manual Apple-portal checklist is [`plans/signing.md`](plans/signing.md). Without a
  real cert + profiles, `build.sh` falls back to ad-hoc signing — the app still
  launches, but **the extension will not register as a File Provider**.
- For the agent operations: **`claude` must be on your login-shell PATH.** The app
  preflights this (`PathPreflight.resolveOnLoginShell`) and surfaces a clear error
  if it's missing, rather than spawning a doomed process.

### Build & run

From the repo root (full detail in [`plans/build-environment.md`](plans/build-environment.md)):

```sh
make            # debug build → build/Self Driving Wiki.app (also builds + embeds wikictl)
make run        # install to /Applications, register File Provider, then open the app
make check      # compile-only gate, no bundle/sign (CI / agent verification)
make test       # the SwiftPM test suite
make install    # copy to /Applications and register LaunchServices + File Provider
make help       # every target
```

### Runtime notes a new dev WILL hit

These are not optional polish — without them the File Provider half does not work:

1. **`make install` (the app must live in `/Applications`).** macOS only discovers
   third-party File Provider extensions from an app installed in `/Applications`.
   Running straight out of `build/` will not register the domains. See
   [`plans/file-provider.md`](plans/file-provider.md).
2. **The domain must be user-enabled.** A third-party File Provider has to be
   toggled on by the user in **System Settings** before its mount appears in
   Finder's sidebar.
3. **The macOS-26 TCC prompt on first / re-signed launch.** A first launch (or any
   re-signed install) fires a Transparency/Consent prompt ("…would like to access
   data from other apps") that *blocks the extension from launching* until you grant
   it. This is recorded in [`ISSUES.md`](ISSUES.md) (and the live-gate memory).
4. **Read-after-write lag (~5 s).** The File Provider mount lags the database by
   a few seconds after a write — it self-heals, no relaunch needed. The agent reads via
   `wikictl page get` (DB-direct, always current), so this never affects the agent. Only
   Finder browsing sees the lag. See [`ISSUES.md`](ISSUES.md).

For live testing, **create a fresh wiki** rather than reusing a long-lived,
heavily-churned one (a hammered domain replica can wedge — see `ISSUES.md`).

---

## Repo layout (the 5 SwiftPM targets)

Defined in [`Package.swift`](Package.swift):

| Target | Kind | Purpose |
| --- | --- | --- |
| **`WikiFSCore`** | library | The dependency-free core: data model, hand-rolled SQLite store, multi-wiki registry, the `claude -p` operation seams, log/index/TREE rendering, URL-ingest + HTML→Markdown. Shared by the app, the extension, the CLI, and the tests. |
| **`WikiFS`** | executable | The SwiftUI app target for Self Driving Wiki — the editor/viewer, the wiki switcher, the Operations panel (Ingest/Query/Lint), domain registration + change bridge. |
| **`WikiFSFileProvider`** | executable* | The File Provider extension target — the read-only SQLite→filesystem projection. (*Built as an executable, then repackaged into a `.appex` by `build.sh`; entry point overridden to `_NSExtensionMain`.) |
| **`WikiCtlCore`** | library | `wikictl`'s logic: arg parsing, command dispatch, wiki resolution, the Darwin post. Library-split so it's unit-testable. |
| **`wikictl`** | executable | The agent's **write path** — a scriptable CLI that writes straight to a wiki's `<ulid>.sqlite` and posts a per-wiki Darwin notification. A thin shell over `WikiCtlCore`. |

The test target is `WikiFSTests` (in `Tests/WikiFSTests/`).

**Where to look** for the main subsystems:

- **Schema + migrations + change token:** `Sources/WikiFSCore/SQLiteWikiStore.swift`
- **Multi-wiki:** `WikiRegistry.swift` / `WikiDescriptor.swift` / `WikiRegistryClient.swift`, `DatabaseLocation.swift`
- **File Provider projection:** `Sources/WikiFSFileProvider/Projection.swift`, `FileProviderExtension.swift`, `WikiFSEnumerator.swift`, `WikiFSItem.swift`
- **The agent operations:** `WikiOperation.swift` / `OperationCommand.swift` / `IngestPlan.swift` / `IngestWriteRule.swift` / `AgentEvent.swift` (core) and `AgentLauncher.swift` / `SpawnGate.swift` (spawn serialization) / `QueryConversationView.swift` (ask/edit sessions) / `OperationsView.swift` / `AgentActivityView.swift` / `OperationRequest.swift` (app)
- **Write path + change bridge:** `wikictl/main.swift`, `WikiCtlCore/*`, `WikiFSCore/PageUpsert.swift`, `WikiFSCore/WikiChangeNotification.swift`, `WikiFS/WikiChangeBridge.swift`, `WikiFSCore/ChangeCoalescer.swift`
- **URL ingest:** `URLIngestService.swift`, `URLSessionFetcher.swift`, `ShareLinkNormalizer.swift`, `HTMLToMarkdown.swift` (+ `HTMLTokenizer`/`HTMLMarkdownRenderer`/`HTMLEntities`)

---

## How it works (tour)

A deeper map is in [`plans/architecture.md`](plans/architecture.md); the short version:

- **Many wikis.** A `wikis.json` registry lists the user's wikis. Each wiki is one
  self-contained `<ulid>.sqlite` file in the App Group container **plus one File
  Provider domain** (`NSFileProviderDomain`), mounting at its own
  `~/Library/CloudStorage/Self Driving Wiki-<name>`. A wiki's stable identity is its **ULID**,
  never its display name (rename-safe). The extension is instantiated per domain;
  `domain.identifier` *is* the wiki ULID, which selects the DB to open.

- **Read/write split.** The agent reads and writes through `wikictl` (DB-direct).
  The File Provider mount is an optional read-only projection for Finder integration
  and the UI page reader. The agent (`page upsert/get/list/delete`, `log append`,
  `index set`), which writes the App Group SQLite directly and posts a per-wiki
  Darwin notification `org.sockpuppet.wiki.changed.<ulid>`. The app's
  `WikiChangeBridge` observes it, debounces a burst (`ChangeCoalescer`, ~250 ms),
  rebuilds the sidebar, and `signalChange()`s that wiki's domain so the mount
  refreshes. `PageUpsert` is the **shared** create-or-update + `[[link]]`-reparse
  seam used by *both* the app and `wikictl`, so the link graph can't drift.

- **The `claude -p` operations.** The app surfaces four operations. **Ingest** and
  **Lint** are one-shot `claude -p` spawns, each launched into a fresh scratch dir
  with `WIKI_DB` (the wiki ULID) and `WIKICTL` (the wikictl path) in the environment,
  the wiki's schema via `--append-system-prompt`, `--dangerously-skip-permissions`,
  and `--output-format stream-json` (parsed live into an activity panel; also
  written to a backend `run.jsonl`). The in-app editor is **locked** during a run.
  **Ask** and **Edit** are persistent interactive sessions — each owns its own tab,
  process, and transcript; follow-up turns go to stdin rather than spawning a new
  process. All four surfaces share one `SpawnGate`: at most one `claude` process runs
  at a time, FIFO-serialized across ingest / ask / edit / lint.
  - **Ingest** is tiered by source size: a **tiny** source gets a single **Opus**
    pass; a **large** source gets an **Opus curator** that fans out to **2–19
    Sonnet `source-reader` subagents** which only *digest* the bulk (read-only,
    never write) — **Opus decides what belongs and writes everything**.
  - **Ask** runs under a physically-enforced read-only seatbelt — the agent cannot
    write the wiki regardless of prompt. **Edit** may write the wiki (governed by the
    sandbox enable toggle in Settings → Agent). **Lint** is a single-Opus one-shot run.
- **URL ingest.** Paste a URL → fetch (desktop UA, follows redirects) → share-link
  normalize (e.g. Dropbox `www`→`dl`) → content-sniff magic numbers →
  HTML→Markdown (hand-rolled) or verbatim PDF/bytes → stored through the same
  ingest path as a drag-dropped file.
- **Projected root docs.** Each mount root carries `CLAUDE.md`/`AGENTS.md` (the
  agent schema), `index.md` (curated catalog), `log.md` (grep-able chronological
  log), `WIKI-STRUCTURE.md` (layout map; `TREE.md` is a legacy alias), plus
  `pages/`, `files/`, `manifest.json`, and `indexes/*.jsonl`.

---

## Docs map

- **[`PLAN.md`](PLAN.md)** — master index: the doc table, milestone status, build
  quick-reference.
- **[`PROGRESS.md`](PROGRESS.md)** — the running build log, newest first, with each
  gate's evidence. **To get up to speed, read `PLAN.md` then `PROGRESS.md`.**
- **[`plans/architecture.md`](plans/architecture.md)** — the system map (this repo's
  companion to the README).
- **`plans/`** — deep design: [`INITIAL.md`](plans/INITIAL.md) (original
  architecture), [`llm-wiki.md`](plans/llm-wiki.md) (the LLM-wiki design + phases),
  [`BRINGUP.md`](plans/BRINGUP.md), [`build-environment.md`](plans/build-environment.md),
  [`file-provider.md`](plans/file-provider.md), [`signing.md`](plans/signing.md).
- **[`ISSUES.md`](ISSUES.md)** — known limitations we've chosen to live with.
- **[`SWIFTUI-RULES.md`](SWIFTUI-RULES.md)** + **[`CLAUDE.md`](CLAUDE.md)** — the
  SwiftUI/macOS coding rules and the working agreement (docs to keep, skills to use,
  PR rules).

---

## Contributing notes

- **Dependency-free by default.** No SwiftPM package dependencies — the SQLite layer
  is hand-wrapped over the system `SQLite3` C API; HTML→Markdown is hand-rolled (no
  `NSAttributedString(html:)`). Keep it that way unless there's a strong reason.
- **Pure-core / thin-app split.** Logic lives in `WikiFSCore` / `WikiCtlCore` so it's
  unit-testable without a running app or a real `claude` process. The app and the
  CLI are thin shells; the `Process` spawn and the SwiftUI views stay deliberately
  thin over pure, injectable seams (`OperationCommand`, `WikiOperation`, `PageUpsert`,
  `AgentEventParser`, `URLIngestService` with an injected fetcher).
- **Run `make test` before pushing** (320 tests).
- **Follow [`SWIFTUI-RULES.md`](SWIFTUI-RULES.md)**, and respect the
  **"live-gate, don't trust a green build"** ethos: a passing build and a passing
  test suite are necessary but not sufficient — File Provider behavior has to be
  verified on a real signed install (see the gate evidence in `PROGRESS.md`).
- **PRs are fine; never merge to `main` yourself** ([`CLAUDE.md`](CLAUDE.md)).
