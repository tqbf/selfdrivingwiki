# Linux GitHub Runner CI Job

## Goal
Add a Linux CI job that builds the portable Swift targets (`WikiFSCoreTests`)
and runs the portable test suite on `ubuntu-latest`. This validates the #754
portability split and catches Linux-only build breaks.

## Current state

### What's already done
- **#776** split test targets: `WikiFSCoreTests` (portable, `Tests/WikiFSTests/`)
  + `WikiFSAppTests` (macOS-only, `Tests/WikiFSAppTests/`).
- **#776** added `#if canImport(JavaScriptCore)`, `#if os(macOS)`,
  `#if canImport(Accelerate)` guards to `WikiFSMarkdown`, `WikiFSSearch`,
  `VectorCosine`.
- **#628** retired CSqliteVec and added a pure-Swift `VectorCosine.dot`
  fallback (no Accelerate needed on Linux).
- `WikiFSSearch` has TantivySwift behind `.when(platforms: [.macOS])`.
- `WikiFSAppTests` has `WikiFS`, `WikiFSMLX`, `WikiFSFileProvider`, `wikid`
  behind `.when(platforms: [.macOS])`.
- The existing `ubuntu-latest` job only runs Python/pdf2md lint+tests.

### What this PR does
- Adds a `linux-swift` job to `.github/workflows/ci.yml` that uses
  `swift-actions/setup-swift@v2` to install Swift 6.0 on `ubuntu-latest`,
  runs `make version prompts` (codegen), caches `.build`, builds
  `WikiFSCoreTests`, and runs `swift test --parallel --skip` with the same
  skip list as the macOS job.
- Adds `#if os(macOS)` guards to two previously-unguarded files in
  `WikiFSAppTests`:
  - `EnvVarHintsTests.swift` — `@testable import WikiFS`
  - `WikiDaemonTests.swift` — `@testable import wikid`
  These imports reference macOS-only targets; without the guard,
  `swift test` on Linux fails to build `WikiFSAppTests` (even though it
  compiles to an empty module, the unresolved import breaks the build).

## Implementation

### CI job structure

```yaml
  linux-swift:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Swift
        uses: swift-actions/setup-swift@v2
        with:
          swift-version: "6.0"
      - name: Generate codegen files
        run: make version prompts
      - name: Cache Swift build
        uses: actions/cache@v4
        with:
          path: |
            .build
            ~/.cache/swiftpm
          key: ${{ runner.os }}-swift-${{ hashFiles('Package.resolved', 'Package.swift') }}
      - name: Build portable targets
        run: swift build --target WikiFSCoreTests
      - name: Test portable suite
        run: swift test --parallel --skip "$SKIP"
        env:
          SKIP: '...'  # same skip list as macOS job
        timeout-minutes: 15
```

### Codegen on Linux
`tools/promptgen/main.swift` and `tools/versiongen/main.swift` both use
`import Foundation` only — `Process`, `FileHandle`, `Data`, `URL` are all
available in swift-corelibs-foundation on Linux. No macOS-only APIs. The
`make version prompts` targets work directly.

### Guard changes
Only two files needed `#if os(macOS)` guards. All other WikiFSAppTests files
were already guarded by #776.

### Skip list
The same skip list from the macOS job applies — those suites test macOS-only
functionality (WebKit, AppKit, FileProvider, Tantivy, etc.). On Linux they
won't compile (in WikiFSAppTests, which compiles to empty), so they're
naturally excluded by building only `WikiFSCoreTests`-relevant code.

## Files modified
| File | Change |
|---|---|
| `.github/workflows/ci.yml` | Add `linux-swift` job |
| `Tests/WikiFSAppTests/EnvVarHintsTests.swift` | Wrap in `#if os(macOS)` |
| `Tests/WikiFSAppTests/WikiDaemonTests.swift` | Wrap in `#if os(macOS)` |

## Acceptance criteria
- [x] A `linux-swift` CI job runs on `ubuntu-latest`.
- [x] `swift build --target WikiFSCoreTests` is the build gate on Linux.
- [x] `swift test` runs the portable test suite on Linux (WikiFSCoreTests only).
- [x] macOS CI is unaffected (no changes to the existing `swift` job).
- [x] `make build && make test` still passes on macOS.
- [x] PR links #754.

## Gotchas
1. **Codegen** (`make version prompts`) is portable — both scripts use
   Foundation only, no macOS-specific APIs.
2. **GRDB Linux support** — GRDB.swift supports Linux via swift-corelibs-foundation
   + system SQLite.
3. **`swift-actions/setup-swift@v2`** supports Swift 6.x and downloads from
   swift.org for the Ubuntu 22.04 platform.
4. **WikiFSAppTests** is NOT built by `swift build --target WikiFSCoreTests`;
   `swift test` builds it but it compiles to an empty module (all source
   guarded by `#if os(macOS)`).
5. **File overlap**: this touches `.github/workflows/ci.yml` — the existing
   `swift` and `python` jobs are NOT modified.
