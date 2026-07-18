# Tantivy Phase 0 Build Spike — Results

> **Status:** ✅ Build spike PASSED. The `botisan-ai/tantivy.swift` package
> resolves, builds, and works end-to-end under bare `swift build` (no Xcode,
> no xcodebuild). Phase 1 (shadow index) is unblocked.
>
> **Issue:** [#526](https://github.com/tqbf/selfdrivingwiki/issues/526)
> **Design doc:** [`tantivy-search-sidecar.md`](tantivy-search-sidecar.md) (PR #541)
> **Branch:** `spike/tantivy-build-verification`

## TL;DR

| Question | Result |
|---|---|
| Does the XCFramework resolve under bare `swift build`? | ✅ Yes |
| Does it support macOS (`aarch64-apple-darwin`)? | ✅ Yes |
| Is there an `x86_64` slice? | ✅ **Yes** (universal binary — contradicts the design doc's assumption) |
| Binary size delta (debug executable)? | +12 MB (98 MB → 110 MB) |
| UniFFI / macro warnings under `-warnings-as-errors`? | ✅ Zero warnings |
| Does `@TantivyDocument` macro work under Swift 6.0? | ✅ Yes |
| Does the FFI bridge work end-to-end (index + search)? | ✅ Smoke test passed (0.11 s) |

**One correction to the design doc:** the XCFramework's macOS slice is
`macos-arm64_x86_64` — a **universal binary** containing both `arm64` and
`x86_64` (confirmed via `lipo -archs`). The design doc (§1.2) and the repo's
build instructions ("only aarch64 is targeted") both said Intel was likely
unsupported. This is wrong: **Intel Macs are supported.** This doesn't change
the project's stance (MLX already requires Apple Silicon), but it removes a
risk the design doc flagged as LOW.

## 1. What was done

### 1.1 Dependency added to `Package.swift`

```swift
.package(url: "https://github.com/botisan-ai/tantivy.swift.git", from: "0.3.4"),
```

> **Note:** the issue referenced `from: "0.1.3"`, but the current release tag is
> `0.3.4` (the README is stale; `Package.swift` is the source of truth). The
> design doc (PR #541) already flagged this and recommended `0.3.4`. We use
> `0.3.4`.

The `TantivySwift` product was added to two targets:

- **`WikiFSSearch`** — the natural home for search-engine integration (per the
  design doc §8.1). Not wired into any production code yet.
- **`WikiFSTests`** — so the smoke test can `import TantivySwift`.

### 1.2 Build

```
swift build          → Build complete! (68.15s)   [exit 0]
```

The XCFramework (`libtantivy-rs.xcframework.zip`, ~20 MB compressed) downloaded
into `.build/artifacts/tantivy.swift/TantivyRS/` and linked against the
`aarch64-apple-darwin` slice with no errors.

### 1.3 Smoke test

`Tests/WikiFSTests/TantivySmokeTests.swift` — a minimal round-trip:

1. Creates a `TantivySwiftIndex<SpikeDoc>` at a fresh temp path
2. `SpikeDoc` is a `@TantivyDocument` struct with `@IDField` + `@TextField`
3. Indexes one document
4. Searches for `"tantivy"` across title + body
5. Verifies the result count (1), the document ID, and a positive BM25 score

```
swift test --filter TantivySmokeTests
→ Test indexAndSearchRoundTrip() passed after 0.114 seconds.
→ Test run with 1 test in 1 suite passed after 0.115 seconds.
```

The test is fast (<1 s), uses no SQLite, no network, and is **untagged** (not
`.integration`) so it runs in the fast CI tier — every PR validates the FFI
bridge still works.

## 2. Findings

### 2.1 Architecture coverage

The XCFramework `Info.plist` declares three library slices:

| LibraryIdentifier | SupportedPlatform | Architectures |
|---|---|---|
| `ios-arm64` | ios | `arm64` |
| `macos-arm64_x86_64` | macos | `arm64`, `x86_64` |
| `ios-arm64_x86_64-simulator` | ios (simulator) | `arm64`, `x86_64` |

`lipo -archs` on the macOS static archive confirms: **`x86_64 arm64`**.

**This contradicts the design doc §1.2**, which said "macOS (Intel): ⚠️ Likely
no." The macOS slice is a universal binary — both Apple Silicon and Intel Macs
are supported. This does not change the project's requirement (MLX needs Apple
Silicon), but it eliminates the Intel-support risk the design doc flagged.

### 2.2 Binary size

| Metric | Value |
|---|---|
| Baseline `WikiFS` executable (debug) | 98 MB |
| With Tantivy linked (debug) | 110 MB |
| **Delta (debug)** | **+12 MB** |
| macOS `libtantivy.a` (universal, unstripped static archive) | 98 MB |
| arm64-only `libtantivy.a` (unstripped) | 49 MB |

The +12 MB debug delta is consistent with the design doc's §1.5 estimate
(~6–16 MB). The 49 MB arm64-only static archive is *unstripped* — most of that
is dead code from the Tantivy/Rust core that the linker drops. The debug
executable links 8,691 Tantivy symbols; a release build with dead-code
stripping (LTO) would be smaller. The design doc's <20 MB acceptance threshold
is met.

### 2.3 Warnings and `-warnings-as-errors`

**Zero warnings** from Tantivy-related code in the `swift build` output.

The project's `-warnings-as-errors` flag is applied via `swiftSettings` on our
targets only — SPM compiles dependencies under their own settings. The
UniFFI-generated `TantivyFFI` bindings, the `TantivySwift` API layer, and the
`TantivySwiftMacros` macro plugin all compile cleanly under Swift 6.0 (the
package declares `swift-tools-version: 6.0`).

**Macro expansion side effect:** because `TantivySmokeTests` lives under
`WikiFSTests` (which has `strictSwiftSettings` including
`-warnings-as-errors`), the `@TantivyDocument` macro's *expanded output*
(Codable conformance, CodingKeys, `TantivySearchableDocument` conformance) is
type-checked under our strict settings. A clean compile confirms the macro
emits no Swift 6 concurrency warnings — the design doc's open question §9.3 #4
("Does Tantivy's actor model interact safely with Swift 6 concurrency?") is
answered: **yes.**

### 2.4 API surface confirmed

The actual public API matches the README and the upstream test suite. Key types
used in the smoke test:

```swift
// Generic actor — the type param is your @TantivyDocument
let index = try TantivySwiftIndex<SpikeDoc>(path: indexPath)
try await index.index(doc: doc)           // add + auto-commit
let count = await index.count()           // UInt64
let results = try await index.search(query: query)  // TantivySearchResults<SpikeDoc>

// Query builder (params after queryStr have defaults)
let query = TantivySwiftSearchQuery<SpikeDoc>(
    queryStr: "tantivy",
    defaultFields: [.title, .body]   // CodingKeys synthesized by the macro
)

// Results
results.count        // UInt64 — total hits
results.docs[i].score // Float — BM25
results.docs[i].doc   // SpikeDoc — decoded back to the struct
```

The `@TantivyDocument` macro synthesizes `CodingKeys` (so `.title` / `.body`
work as field references), `Codable` conformance, `TantivySearchableDocument`
conformance, and the schema-building `toTantivyDocument()` /
`init(fromFields:)` round-trip — all with zero boilerplate.

**Snippet API:** the design doc (§4.3) flagged this as an open question. The
README and API surface do **not** expose `SnippetGenerator`. The
`TantivySearchResult` struct carries only `score` and `doc` — no snippet/highlight
field. This confirms the design doc's fallback recommendation: client-side
highlighting for Phase 1 (post-search regex on the body).

## 3. No conflicts

The Tantivy XCFramework coexists with the existing `CSqliteVec` C target in
the same package graph with no symbol conflicts. Both link into the same
`WikiFS` executable. `TantivyRS` is a static `.a` archive (Rust core);
`CSqliteVec` is a C amalgamation compiled from source — they have disjoint
symbol namespaces.

## 4. What this does NOT do

This spike **only** validates the build. It does not:

- Wire Tantivy into the search pipeline (that's Phase 1)
- Add `TantivySearchService` / `TantivyIndexer` / `WikiSearchDocument` to
  `WikiFSSearch` (Phase 1)
- Subscribe to the `WikiEventBus` (Phase 1)
- Touch any production search code (`searchPagesFTS`, `hybridSearch`, etc.)

The `WikiFSSearch` target now depends on `TantivySwift`, but no source file in
`Sources/WikiFSSearch/` imports it yet. The dependency is present so the smoke
test can compile against a real target.

## 5. Recommendation

**Proceed to Phase 1 (shadow index).** All three Phase 0 risks the design doc
identified are resolved:

1. ✅ **Build feasibility** — XCFramework resolves under bare `swift build`,
   links for macOS, coexists with `CSqliteVec`, zero warnings.
2. ✅ **Architecture coverage** — universal binary (arm64 + x86_64); the
   "Intel likely unsupported" risk is eliminated entirely.
3. ✅ **Swift 6 / macro compatibility** — `@TantivyDocument` macro expands
   cleanly under `-warnings-as-errors`; the actor API is `Sendable`-safe.

The snippet API gap is confirmed but non-blocking (client-side fallback
suffices for Phase 1). Binary size (+12 MB debug, <20 MB threshold) is
acceptable.

The next step is implementing `TantivySearchService` + `TantivyIndexer` +
`WikiSearchDocument` in `WikiFSSearch` and wiring the event bus subscription,
per the design doc §3 and §8.1.
