# Plan — Issue #754: Portable Daemon + Fuzzer Core

**Goal:** Split macOS-only dependencies behind conditional compilation so `WikiFSCore` + `wikid` build and the `WikiFSCoreTests` suite runs on Linux, with **zero macOS regression**.

---

## 0. Headline finding — the issue's portability map needs one correction

The issue's per-target map says *"make the entire `WikiFSSearch` target `#if os(macOS)` … WikiFSCore's dependency on WikiFSSearch must be conditional — on Linux, search is a no-op or a stub."* **That framing does not survive contact with the code.** `WikiFSCore` depends on `WikiFSSearch`'s *portable* types pervasively and unconditionally; it cannot drop the dependency on Linux.

Concretely, `GRDBWikiStore` and `WikiStoreModel` call these `WikiFSSearch` types at dozens of sites:

| WikiFSSearch type | Used by Core at | Portable? |
|---|---|---|
| `EmbeddingService.isAvailable` / `.embeddingBlob` / `.chunkedEmbeddings` / `.selectedEmbedderIdentifier` / `.configure()` / `.miniLMIdentifier` | `GRDBWikiStore.swift:79,4932,5361-5363,5460-5462,6060-6062,6552-6554,7433`; `PageUpsert.swift:79`; `WikiStoreModel.swift:3068,3071-3072` | **Partly** — references `NLEmbedder` (macOS-only) at `EmbeddingService.swift:41,46,76` |
| `VectorCosine.decode` / `.dot` / `.rankBestChunkPerDoc` | `GRDBWikiStore.swift:5363-5398,5462-5491,6062-6089` | **No** — imports `Accelerate` (`VectorCosine.swift:1`) for `vDSP_dotpr` (`:53`) |
| `RankFusion.rrf` | `GRDBWikiStore.swift:5398,5491,6089` | ✅ pure Swift |
| `WikiIndex.defaultBody` / `WikiIndexTokenContributor` | `GRDBWikiStore.swift:571,2323,2721,2758` | ✅ pure Swift |
| `TantivySearchService` / `TantivyDocumentKind` / `TantivyShadowSearchResult` / `TantivyContentSource` | `WikiStoreModel.swift:304,3151,3190,3218`; `StoreBackedTantivyContentSource.swift:20,29,91,197,202,253` | **No** — defined in `TantivySearchDocument.swift` (imports `TantivySwift:2`) + `TantivyIndexer`/`TantivySearchService` (import `TantivySwift`) |

**Therefore the real split is:** *portable search algebra* (`Embedder`, `EmbeddingService`, `VectorCosine`, `RankFusion`, `TextChunker`, `WikiIndex`, + the Tantivy *value* types) stays reachable on Linux behind `#if canImport(...)` guards; only the **concrete macOS implementations** (`NLEmbedder`, `TantivyIndexer`, `TantivySearchService`, the `@TantivyDocument` macro type, the MLX embedder) are excluded.

A second, equally important finding: **`wikid` is XPC-bound.** `wikid/main.swift` is built entirely on `NSXPCListenerDelegate` / `NSXPCConnection` / `NSXPCInterface` / launchd mach-service (`main.swift:6,10,17-25`), and `WikiDaemonProtocol` is `@objc` (`WikiDaemonProtocol.swift:12`). XPC does not exist on Linux. The daemon *logic* (`WikiDaemon.swift`) is portable Foundation, but the *transport* is not — so "wikid builds on Linux" requires a transport abstraction, not just conditional deps.

These two corrections are the crux of the plan.

---

## 1. Verified portability map (against actual code)

| Target | Linux? | Evidence / Blocker |
|---|---|---|
| `WikiFSTypes` | ✅ | Foundation-only. `PageID`, `ULID`, `DebugLog`, etc. |
| `WikiFSLinks` | ✅ | Foundation-only (`_Exports.swift` re-exports WikiFSTypes only) |
| `WikiFSMarkdown` | ⚠️ | Only `MarkdownLinter.swift:2` + `MermaidValidator.swift:2` `import JavaScriptCore`. The other 12 files are pure Foundation. Needs JS guard. |
| `WikiFSSearch` | ⚠️ split | Portable core (`Embedder`, `EmbeddingService`, `RankFusion`, `TextChunker`, `WikiIndex`, Tantivy value types) + macOS-only (`NLEmbedder`→NaturalLanguage, `TantivyIndexer`/`TantivySearchDocument`/`TantivySearchService`→TantivySwift, `VectorCosine`→Accelerate) |
| `WikiFSCore` | ⚠️ | Needs conditional Tantivy wiring in `WikiStoreModel` + `StoreBackedTantivyContentSource`. Embedding/Vector/Rank paths stay (gated by `isAvailable`). `UniformTypeIdentifiers` imports (`GRDBWikiStore.swift:3`, etc.) **are** Linux-available. |
| `WikiFSEngine` | ✅ (after Core) | Depends on `WikiFSCore` + `swift-acp` (JSON-RPC/stdio → portable). No SwiftUI/AppKit imports found. |
| `WikiCtlCore` | ✅ (after Core) | Depends on `WikiFSCore` only. Note `CLITantivyLegResolver.swift` likely references Tantivy types → needs `#if os(macOS)`. |
| `wikictl` | ✅ (after Core) | Thin shell over `WikiCtlCore`. |
| `wikid` | ⚠️ | Logic (`WikiDaemon.swift`) portable; **transport (`main.swift`) is XPC/launchd — macOS-only.** Needs Linux transport. |
| `WikiFSMLX` | ❌ | `import MLX/MLXEmbedders/MLXNN` (`EmbedderBootstrap.swift:2`, `MiniLMEmbedder.swift:4-6`). No Linux SwiftPM build. |
| `WikiFS` (GUI) | ❌ | SwiftUI/AppKit/WebKit throughout. |
| `WikiFSFileProvider` | ❌ | `import FileProvider` everywhere. |
| `podcast-token-helper` | ❌ | ObjC + private `AppleMediaServices`. |
| `WikiFSTests` | ❌ (must split) | Depends on `WikiFS, WikiFSMLX, WikiFSFileProvider, wikid, TantivySwift` (`Package.swift:240-245`). ~24 files import AppKit/WebKit/FileProvider; more test SwiftUI-hosted views. |

### Package dependencies — Linux reachability
| Package | Portable? | Used by (Linux-reachable?) |
|---|---|---|
| `apple/swift-markdown` | ✅ pure Swift | `WikiFS` (❌ not built on Linux) — effectively unused on Linux |
| `mlx-swift-lm` | ❌ Metal | `WikiFSMLX` (❌) |
| `wsargent/swift-acp` | ✅ (expected; stdio JSON-RPC) | `WikiFSEngine` (✅) — **verify** |
| `groue/GRDB.swift` | ✅ (system SQLite) | `WikiFSCore` (✅) — needs `libsqlite3-dev` on Linux |
| `botisan-ai/tantivy.swift` | ❌ macOS-arm64 XCFramework | `WikiFSSearch` macOS-only parts (must be macOS-conditional) |

---

## 2. Architectural decision: split WikiFSSearch, not drop it

Keep `WikiFSSearch` as a single target but make it **self-portable** using internal `#if` guards, so `WikiFSCore` can keep its *unconditional* dependency on `WikiFSSearch` (required — see §0). The macOS-only concrete implementations compile out on Linux; the portable search algebra remains.

---

## 3. Phased refactoring

### Phase A — `Package.swift` (conditional deps & framework links)

**A1.** Make `TantivySwift` a macOS-conditional product dependency in `WikiFSSearch`.
**A2.** Remove `linkerSettings: [.linkedFramework(...)]` for JavaScriptCore (WikiFSMarkdown) and NaturalLanguage (WikiFSSearch); replace in-source imports with `#if canImport(...)`.
**A3.** Gate macOS-only package deps via conditional product deps.
**A4.** Document that Linux uses explicit `--target` flags.

### Phase B — `WikiFSMarkdown` JS guard

Wrap `import JavaScriptCore` in `#if canImport(JavaScriptCore)` and provide Linux no-op stubs in `MarkdownLinter.swift` and `MermaidValidator.swift`.

### Phase C — `WikiFSSearch` portable core + macOS-only `#if`

**C1.** Split portable Tantivy value types into `TantivySearchTypes.swift` (no `import TantivySwift`).
**C2.** Guard `NLEmbedder.swift` / `TantivyIndexer.swift` / `TantivySearchService.swift` with `#if os(macOS)`.
**C3.** `EmbeddingService.swift` Linux stub (returns `"unavailable-linux"`, no-op configure, `isAvailable=false`).
**C4.** `VectorCosine.swift` Accelerate fallback with pure-Swift `dot`.

### Phase D — `WikiFSCore` conditional Tantivy wiring

Guard `TantivyShadowSync` (L197+) in `StoreBackedTantivyContentSource.swift`. Guard `tantivySearch` property + `resolveTantivyLeg*` paths in `WikiStoreModel.swift`. Guard `CLITantivyLegResolver.swift`.

### Phase E — `wikid` Linux transport

`main.swift`: `#if os(macOS)` XPC / `#else` stdio JSON-RPC serve loop dispatching WikiDaemon operations.

### Phase F — Test split

Split `WikiFSTests` → `WikiFSCoreTests` (portable) + `WikiFSAppTests` (macOS-only with `#if os(macOS)` wrapping).

---

## 6. `#if` guard summary table

| Module | File | Guard | Reason |
|---|---|---|---|
| WikiFSMarkdown | `MarkdownLinter.swift`, `MermaidValidator.swift` | `#if canImport(JavaScriptCore)` (+ stub) | JSContext |
| WikiFSSearch | `NLEmbedder.swift` | `#if os(macOS)` | NaturalLanguage |
| WikiFSSearch | `TantivyIndexer.swift`, `TantivySearchService.swift`, `TantivySearchDocument.swift`(macro) | `#if os(macOS)` | Tantivy XCFramework |
| WikiFSSearch | `TantivySearchTypes.swift` (4 value types) | **no guard** | portable |
| WikiFSSearch | `VectorCosine.swift` | `#if canImport(Accelerate)` (dot only) | vDSP |
| WikiFSSearch | `EmbeddingService.swift` | `#if !os(macOS)` (stub branch) | NLEmbedder refs |
| WikiFSCore | `StoreBackedTantivyContentSource.swift` (TantivyShadowSync only) | `#if os(macOS)` | TantivySearchService |
| WikiFSCore | `WikiStoreModel.swift` (Tantivy property/methods) | `#if os(macOS)` | Tantivy types |
| WikiCtlCore | `CLITantivyLegResolver.swift` | `#if os(macOS)` | Tantivy types |
| wikid | `main.swift` (XPC) | `#if os(macOS)` / `#else` (stdio) | NSXPC* |

---

## 7. Linux build/test invocation contract

```bash
# Linux (Swift 6, libsqlite3-dev installed)
swift build --target WikiFSCore --target wikid          # acceptance line 1
swift test --filter WikiFSCoreTests                      # acceptance line 2

# macOS (unchanged)
swift build && swift test                                # acceptance line 3
```

---

## 8. Acceptance Criteria

| AC | Issue acceptance | Named test / verification | Executable now? |
|---|---|---|---|
| AC.1 | `swift build && swift test` on macOS unchanged | `make build && make test` — all tests pass | ✅ Yes (macOS) |
| AC.2 | No macOS-only code compiles on Linux (guards) | grep gate for `#if` guards | ✅ Yes (grep) |
| AC.3 | `swift build --target WikiFSCore --target wikid` on Linux | run on Linux host | ❌ Deferred — needs Linux host |
| AC.4 | `swift test --filter WikiFSCoreTests` on Linux | run portable tests on Linux | ❌ Deferred |
| AC.5 | `wikid` runs on Linux | `./wikid --container tmp/wiki` round-trip | ❌ Deferred |
| AC.6 | Guards are correct | first Linux build reveals | ❌ Deferred |

---

## 12. Follow-up issues (explicitly out of scope for #754)

- Fuzzer harness (libFuzzer)
- Linux CI job
- Portable embedding backend (ONNX runtime / remote API)
- wikid Linux transport hardening (Unix socket / gRPC)
- Extract `WikiFSSearchCore` portable target

---

## 13. File-level change manifest

```
Package.swift
  - WikiFSMarkdown: drop .linkedFramework("JavaScriptCore")
  - WikiFSSearch: TantivySwift dep → condition:.when([.macOS]); drop .linkedFramework("NaturalLanguage")
  - Split WikiFSTests → WikiFSCoreTests + WikiFSAppTests
Sources/WikiFSMarkdown/MarkdownLinter.swift         #if canImport(JavaScriptCore) + stub
Sources/WikiFSMarkdown/MermaidValidator.swift        #if canImport(JavaScriptCore) + stub
Sources/WikiFSSearch/TantivySearchTypes.swift        NEW (4 value types, portable)
Sources/WikiFSSearch/TantivySearchDocument.swift     keep only @TantivyDocument macro, #if os(macOS)
Sources/WikiFSSearch/TantivyIndexer.swift            #if os(macOS)
Sources/WikiFSSearch/TantivySearchService.swift      #if os(macOS)
Sources/WikiFSSearch/NLEmbedder.swift                #if os(macOS)
Sources/WikiFSSearch/VectorCosine.swift              #if canImport(Accelerate) (dot only)
Sources/WikiFSSearch/EmbeddingService.swift          #if !os(macOS) stub branch
Sources/WikiFSCore/Store/StoreBackedTantivyContentSource.swift  TantivyShadowSync only #if os(macOS)
Sources/WikiFSCore/Store/WikiStoreModel.swift        tantivySearch prop + resolveTantivyLeg* #if os(macOS)
Sources/WikiCtlCore/CLITantivyLegResolver.swift      #if os(macOS) + nil stub
Sources/wikid/main.swift                             #if os(macOS) XPC / #else stdio serve loop
Tests/WikiFSCoreTests/  (portable subset)
Tests/WikiFSAppTests/   (macOS-only subset, each #if os(macOS)-wrapped)
```
