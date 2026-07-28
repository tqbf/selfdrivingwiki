---
timestamp: 2026-06-15T193700Z
title: "2026-06-15 — Milestone 0: app skeleton on its legs"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-06-15 — Milestone 0: app skeleton on its legs

## Progress


Bootstrapped the SwiftPM build environment from `Makefile.example` and got a
hello-world WikiFS SwiftUI app building, signing, and launching.

**Added**

- `Package.swift` — executable target `WikiFS`, macOS 14+, Swift tools 6.0.
- `Sources/WikiFS/WikiFSApp.swift` — `@main` App + `WindowGroup`.
- `Sources/WikiFS/ContentView.swift` — `NavigationSplitView` shell (foreshadows
  the sidebar/editor split).
- `Sources/WikiFS/WelcomeView.swift` — hello-world detail pane.
- `WikiFS/WikiFS.entitlements` — minimal (no sandbox yet).
- `scripts/make-icon.swift` — generates the app icon (white `books.vertical.fill`
  on a blue→indigo squircle) at all macOS sizes.
- `build.sh` — `swift build` → assemble `.app` → write `Info.plist` → codesign.
- `Makefile` — adapted from `Makefile.example` (Moves → WikiFS): app name,
  entitlements path, icon comment, notary profile `wikifs-notary`.
- `.gitignore` — `build/ .build/ dist/`.
- Docs: `PLAN.md` (index), `plans/build-environment.md` (build deep-dive).

**Verified**

- `make` builds `build/WikiFS.app` (debug, v0.0.0-dev). Dev cert not in this
  keychain → ad-hoc signature (expected; `make run` still works).
- `make check` compiles clean.
- Live gate (`SWIFTUI-RULES` §9.1): `make run` launches, window renders the
  native two-column layout with the books hero, process stays alive past the
  first display cycle. Screenshot confirmed the UI.

**Notes / decisions**

- Bundle id `org.sockpuppet.WikiFS`; min macOS 14 (matches `Makefile.example`).
- Ran the `swiftui-pro` skill on the sources (CLAUDE.md requirement). Only
  finding: one-type-per-file — extracted `WelcomeView` out of `ContentView.swift`.
- Toolchain present: Apple Swift 6.3.2, macOS 26.5 host.

**Next (Milestone 1 / setup)**

- Add a `WikiFSTests` target so `make test` does something.
- Begin SQLite store + page model (Milestone 0 deliverables in `plans/INITIAL.md`
  also include persistence; the build skeleton is done, the data layer is not).

## Verification

Historical verification remains in the progress record above.
