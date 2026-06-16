# Build environment

How Self Driving Wiki is compiled, bundled, signed, and run. This is the source of truth
for *how we build*; `plans/INITIAL.md` is the source of truth for *what we
build*.

## Principle: SwiftPM, not Xcode

The build is driven by `swift build` + `./build.sh`, orchestrated by the
`Makefile`. **No Xcode IDE, no `xcodebuild`, no XcodeGen.** Xcode is only a
toolchain provider (`swift`, `codesign`, and later `notarytool` / `stapler`).
This keeps the build reproducible from a plain shell / agent and out of the
`.xcodeproj` merge-conflict business.

This mirrors the proven setup from the "Moves" app that `Makefile.example`
came from.

## Layout

```
Package.swift                 SwiftPM manifest — executable target "WikiFS", macOS 14+
Sources/WikiFS/               Swift sources (one type per file)
  WikiFSApp.swift             @main App + window scene
  ContentView.swift           NavigationSplitView shell
  WelcomeView.swift           hello-world detail pane (Milestone 0)
WikiFS/
  WikiFS.entitlements         codesign entitlements (minimal in M0)
scripts/make-icon.swift       renders build/AppIcon.iconset from an SF Symbol
build.sh                      swift build → assemble .app → write Info.plist → codesign
Makefile                      orchestration (adapted from Makefile.example)
build/                        output (gitignored): Self Driving Wiki.app, AppIcon.icns, .iconset
.build/                       SwiftPM intermediate (gitignored)
dist/                         release zips (gitignored)
```

## The build pipeline

`make` runs `deps` → builds the icon → calls `build.sh`:

1. **`deps`** — checks macOS ≥ 14, `swift` on PATH, `Package.swift` and
   `build.sh` present.
2. **Icon** — `build/AppIcon.icns` is regenerated whenever
   `scripts/make-icon.swift` changes. The script draws a white
   `books.vertical.fill` SF Symbol on a blue→indigo squircle at all ten macOS
   icon sizes into `build/AppIcon.iconset`; `iconutil -c icns` packs it.
3. **`build.sh <config>`**:
   - `swift build -c <config>` produces the executable.
   - Assembles `build/Self Driving Wiki.app/Contents/{MacOS,Resources}`, copies the
     binary and `AppIcon.icns`.
   - Writes `Info.plist` (bundle id `org.sockpuppet.WikiFS`, min macOS 14,
     `NSHighResolutionCapable`, productivity category). Version resolves from
     a `vX.Y.Z` git tag → `VERSION` file → `0.0.0-dev`.
   - `codesign`s with `$SIGN_IDENTITY`, **falling back to ad-hoc (`-`)** when
     the named dev identity isn't in the keychain — so `make run` works on any
     machine.

## Common targets

| Target | Effect |
| --- | --- |
| `make` / `make build` | Debug build → `build/Self Driving Wiki.app` |
| `make run` | Build + `open` the app |
| `make check` | `swift build` only — no bundle/sign. **The CI / agent gate.** |
| `make test` | `swift test` (no test target yet) |
| `make release` | Release-config build |
| `make install` | Copy to `/Applications` + register with LaunchServices |
| `make clean` | Remove `build/ .build/ dist/` |
| `make help` | Full target list |

## Signing

- **Dev** (`DEV_IDENTITY`, default `Apple Development: Thomas Ptacek …`): used
  by `build.sh`. Ad-hoc fallback means missing certs never block a local run.
- **Release** (`make dist`): Developer ID + hardened runtime + timestamp +
  notarize + staple, gated on an exact `vX.Y.Z` git tag. Wired but unused
  until v0 ships. One-time `make notary-setup` stores creds in the keychain
  under profile `wikifs-notary` (team `KK7E9G89GW`).

## Verifying a build (live gate)

Per `SWIFTUI-RULES.md` §9.1, a compile is not a passing app. After a UI
change, run it and confirm the process survives the first display cycle:

```sh
make run
sleep 4 && pgrep -x "Self Driving Wiki" && echo alive
```

## What's deliberately deferred

- **App Group + sandbox** — needed for SQLite sharing with the File Provider
  extension (Milestone 2). Entitlements gain `group.org.sockpuppet.wiki`
  then.
- **File Provider extension target** — a second SwiftPM/bundle product;
  `build.sh` will grow an `.appex` assembly step.
- **Test target** — `make test` is wired but there's no test target in
  `Package.swift` yet.
