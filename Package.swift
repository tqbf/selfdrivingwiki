// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Self Driving Wiki — native macOS SwiftUI wiki with a File Provider filesystem
// projection. Built with SwiftPM (no Xcode IDE, no xcodebuild); ./build.sh
// bundles the executable produced here into build/Self Driving Wiki.app and codesigns it.

// Apple Podcasts transcript ingest uses the PRIVATE PodcastsFoundation framework
// (via the `podcast-token-helper` target) — fine for local/dev, NOT App Store
// shippable. INCLUDED BY DEFAULT. Set WIKIFS_APP_STORE=1 to build without it: that
// drops the helper target AND compiles the feature out of the Swift sources via the
// `PODCAST_TRANSCRIPTS` compilation condition. See plans/podcast-transcripts.md.
let podcastTranscriptsEnabled = ProcessInfo.processInfo.environment["WIKIFS_APP_STORE"] == nil
let podcastSwiftSettings: [SwiftSetting] = podcastTranscriptsEnabled ? [.define("PODCAST_TRANSCRIPTS")] : []
/// Treat compiler warnings as errors so they never silently accumulate (#493).
let strictSwiftSettings: [SwiftSetting] = podcastSwiftSettings + [.unsafeFlags(["-warnings-as-errors"])]

let package = Package(
    name: "WikiFS",
    platforms: [.macOS(.v15)],
    dependencies: [
        // swift-markdown powers the reader's markdown→HTML renderer
        // (plans/source-web-reader.md / textual-to-wkwebview.md). Pure-Swift GFM
        // AST (tables, footnotes, task lists); we walk it with a MarkupVisitor to
        // emit HTML for the WKWebView reader that replaced the vendored Textual.
        .package(url: "https://github.com/apple/swift-markdown", from: "0.8.0"),
        // MLX on-device embeddings (all-MiniLM-L6-v2, Metal/GPU). MLXEmbedders
        // bundles its own tokenizer + pooling. Needs >= 2.31.3 (MLXEmbedders was
        // added after the 0.x line). See plans/mlx-minilm-design.md.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "2.31.3"),
        // swift-acp — native Swift SDK for the Agent Client Protocol (ACP). Used by
        // ACPBackend (plans/acp-backend-and-permissions.md): the app is the ACP
        // *client*; it launches any ACP agent subprocess over JSON-RPC/stdio and
        // mediates writes via session/request_permission (the always-ask/yolo lever).
        //
        // Forked from wiedymi/swift-acp v0.1.0 (plans/acp-stall-recovery.md Phase 2):
        // the upstream is dead since v0.1.0 and has four root-cause bugs (unordered
        // transport reads, actor head-of-line blocking on request_permission,
        // discarded stderr, unexposed PID). The fork fixes all four. Upstream PRs
        // offered when the upstream resumes.
        .package(url: "https://github.com/wsargent/swift-acp", from: "0.2.0"),
        // GRDB.swift — GRDB toolkit for SQLite. Phase 1 pilot: QueueStore uses
        // DatabaseQueue + DatabaseMigrator replacing hand-rolled sqlite3_* calls
        // (plans/grdb-adoption.md §6). The default GRDB product uses the system
        // SQLite (same as SQLiteWikiStore) — they coexist on different database
        // files with no conflict.
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        // swift-crypto — Apple's Swift Crypto package. On macOS, `CryptoKit`
        // (system framework) provides SHA256 etc. On Linux, this package
        // provides the identical API under the `Crypto` module. Already a
        // transitive dependency via GRDB; declared directly so WikiFSCore can
        // depend on the `Crypto` product on Linux (#754, #780).
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
        // tantivy.swift — Rust Tantivy full-text search via UniFFI bindings + an
        // @TantivyDocument macro. Phase 0 build spike (plans/tantivy-search-sidecar.md):
        // verify the pre-built XCFramework (libtantivy-rs.xcframework) resolves under
        // bare `swift build` (no Xcode) and links for aarch64-apple-darwin. Ships a
        // macOS arm64 slice; no x86_64 (acceptable — MLX already requires Apple Silicon).
        // NOT wired into the search pipeline yet — spike only.
        .package(url: "https://github.com/wsargent/tantivy.swift.git", from: "0.3.5"),
    ],
    targets: [
        // System SQLite3 module for Linux. On macOS, `import SQLite3` resolves
        // to the SDK's built-in module. On Linux, this system module wraps
        // libsqlite3-dev's <sqlite3.h> so `import SQLite3` works identically.
        // WikiFSCore depends on it conditionally (macOS-only — on macOS the
        // SDK module is used directly).
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            pkgConfig: "sqlite3"
        ),
        // Shared leaf types (PageID, ULID, ResourceKind, EmbedTarget, ParsedLink)
        // — Foundation-only, depended on by WikiFSLinks and WikiFSCore. Extracted
        // from WikiFSCore in module restructuring Phase 1 (#532) so the pure-logic
        // link cluster (WikiFSLinks) and the store/protocol (WikiFSCore) can both
        // reference these foundational types without a circular dependency.
        .target(
            name: "WikiFSTypes",
            path: "Sources/WikiFSTypes",
            swiftSettings: strictSwiftSettings
        ),
        // The wiki-link grammar cluster — pure-logic parser/resolver/rewriter/
        // rules. Depends only on WikiFSTypes (PageID/ULID/ParsedLink/etc.).
        // Extracted from WikiFSCore in module restructuring Phase 1 (#532).
        // Re-exported by WikiFSCore via @_exported import (ModuleExports.swift)
        // so existing importers of WikiFSCore see link types with no per-file
        // imports. Previously Sources/WikiFSCore/Links/.
        .target(
            name: "WikiFSLinks",
            dependencies: ["WikiFSTypes"],
            path: "Sources/WikiFSLinks",
            swiftSettings: strictSwiftSettings
        ),
        // Markdown/content-transformation cluster — linter, extractors, diffs,
        // HTML↔markdown converters, slug utils, mermaid validator. Depends on
        // WikiFSTypes (DebugLog/PageID/etc.) and WikiFSLinks (WikiLinkFixer/
        // WikiLinkSpan). Extracted from WikiFSCore in module restructuring
        // Phase 2 (#532). Re-exported by WikiFSCore via ModuleExports.swift.
        // Previously Sources/WikiFSCore/Markdown/.
        // JavaScriptCore: MarkdownLinter + MermaidValidator run vendored JS
        // bundles (markdownlint, merval) in a JSContext (no Node at runtime).
        .target(
            name: "WikiFSMarkdown",
            dependencies: ["WikiFSTypes", "WikiFSLinks"],
            path: "Sources/WikiFSMarkdown",
            swiftSettings: strictSwiftSettings
        ),
        // Search/embedding cluster — Embedder protocol, NLEmbedder, embedding
        // service, text chunker, rank fusion, wiki index. Depends only on
        // WikiFSTypes (PageID/DebugLog). Extracted from WikiFSCore in module
        // restructuring Phase 3 (#532). Re-exported by WikiFSCore via
        // ModuleExports.swift. Previously Sources/WikiFSCore/Search/.
        // NaturalLanguage: NLEmbedder uses NLEmbedding for on-device vectors.
        .target(
            name: "WikiFSSearch",
            dependencies: [
                "WikiFSTypes",
                // Phase 0 spike: TantivySwift (Tantivy FFI + @TantivyDocument macro).
                // Natural home for search-engine integration (plans/tantivy-search-sidecar.md §8.1).
                // macOS-only: the pre-built XCFramework ships only a macOS arm64 slice.
                // Guarded with #if os(macOS) in source; the dependency is conditional so
                // Linux `swift build --target WikiFSSearch` doesn't try to build it (#754).
                .product(name: "TantivySwift", package: "tantivy.swift",
                         condition: .when(platforms: [.macOS])),
            ],
            path: "Sources/WikiFSSearch",
            swiftSettings: strictSwiftSettings
        ),
        // Non-UI core: page model, ULID, the WikiStore protocol + SQLite
        // implementation, and the @Observable WikiStoreModel. Depended on by
        // the executable AND the test target so logic is testable without a
        // running app (SWIFTUI-RULES §9.1 — model logic in its own target).
        .target(
            name: "WikiFSCore",
            dependencies: [
                "WikiFSTypes",
                "WikiFSLinks",
                "WikiFSMarkdown",
                "WikiFSSearch",
                .product(name: "GRDB", package: "GRDB.swift"),
                // On Linux, `import SQLite3` needs this system module wrapper.
                // On macOS, the SDK provides SQLite3 directly.
                .target(name: "CSQLite", condition: .when(platforms: [.linux])),
                // On macOS, `CryptoKit` (system framework) provides SHA256.
                // On Linux, `swift-crypto` (transitive via GRDB) provides the
                // identical API under the `Crypto` module (#754, #780).
                .product(name: "Crypto", package: "swift-crypto",
                         condition: .when(platforms: [.linux])),
            ],
            path: "Sources/WikiFSCore",
            swiftSettings: strictSwiftSettings,
        ),
        // — which the File Provider extension must NOT (com.apple.fileprovider-
        // nonui forbids Metal on macOS 26). Core reaches the implementation via
        // the injectable EmbeddingService.miniLMFactory seam; the app installs it
        // here at launch (EmbedderBootstrap). Mirrors the PDFKit isolation.
        .target(
            name: "WikiFSMLX",
            dependencies: [
                "WikiFSCore",
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
            ],
            path: "Sources/WikiFSMLX",
            swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]
        ),
        // The agent execution engine — extracted from the app target so a
        // standalone daemon (`wikid`) can link it. Holds: AgentLauncher,
        // ACPBackend, ClaudeCLIBackend, AgentOperationRunner, GenerationGate,
        // ExtractionCoordinator, AgentBackend/Factory, OperationRequest, plus
        // the ACP stall-recovery + permission seams. See
        // plans/multi-wiki-daemon.md §3.
        .target(
            name: "WikiFSEngine",
            dependencies: [
                "WikiFSCore",
                // ACP client runtime (ACPBackend — plans/acp-backend-and-permissions.md).
                // The `ACP` product is macOS-only: it uses ACPProcessManager and os.log.
                // Guarded with #if os(macOS) in source so the portable logic in
                // WikiFSEngine (queue engine, protocols, ACPModel-only files) compiles
                // on Linux (#754, #780). `ACPModel` (pure model types) is portable.
                .product(name: "ACP", package: "swift-acp",
                         condition: .when(platforms: [.macOS])),
                .product(name: "ACPModel", package: "swift-acp"),
            ],
            path: "Sources/WikiFSEngine",
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "WikiFS",
            dependencies: [
                "WikiFSCore",
                // WikiFS (the app) is macOS-only — links WebKit, MLX, etc.
                .target(name: "WikiFSEngine", condition: .when(platforms: [.macOS])),
                "WikiFSMLX",
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            path: "Sources/WikiFS",
            // WKWebView for the reader path (Sources/WikiFS/WikiReaderView.swift)
            // — the single markdown reader (replaced the vendored Textual).
            swiftSettings: strictSwiftSettings,
            linkerSettings: [.linkedFramework("WebKit")]
        ),
        // wikictl's logic (arg parsing, command dispatch, wiki resolution, the
        // Darwin post) lives in a LIBRARY target so it's unit-testable — the same
        // split WikiFSCore uses (logic out of the executable). The executable
        // below is a thin process shell over it.
        .target(
            name: "WikiCtlCore",
            dependencies: ["WikiFSCore"],
            path: "Sources/WikiCtlCore",
            // Must match WikiFSCore's PODCAST_TRANSCRIPTS flag so conditional
            // API in SourceRefreshService (the podcast refresh branch) compiles
            // consistently across the dependency.
            swiftSettings: strictSwiftSettings
        ),
        // wikictl — the agent's write path (plans/llm-wiki.md Phase A). A
        // scriptable CLI that writes straight to a wiki's <ulid>.sqlite in the
        // App Group container and posts a per-wiki Darwin notification so the app
        // refreshes. Reads still go via the read-only File Provider mount; this
        // is the WRITE half of "read via the mount, write via wikictl".
        .executableTarget(
            name: "wikictl",
            dependencies: ["WikiFSCore", "WikiCtlCore"],
            path: "Sources/wikictl",
            swiftSettings: strictSwiftSettings
        ),
        // wikid — the XPC daemon (plans/multi-wiki-daemon.md Phase 1B). Owns the
        // live wiki registry + store lifecycle, serving clients via XPC. Launchd
        // starts it on-demand when a client connects to the mach service name.
        // The daemon links WikiFSCore (for WikiRegistry, SQLiteWikiStore, the
        // WikiDaemonProtocol) — not WikiFSEngine (agent execution stays in the
        // app for now; the daemon grows it in a later phase).
        .executableTarget(
            name: "wikid",
            dependencies: ["WikiFSCore"],
            path: "Sources/wikid",
            swiftSettings: strictSwiftSettings
        ),
        // podcast-token-helper — the FairPlay/Mescal bearer-token signer for Apple
        // Podcasts transcripts. An ObjC executable ON PURPOSE: it dlopens the private
        // PodcastsFoundation framework and calls undeclared selectors (AMSMescal /
        // AMSMescalSession), so it must be isolated from Swift 6 strict-concurrency
        // and from the app process (the signing call can segfault on cleanup — a
        // crash here costs one failed fetch, never the app). WikiFSCore spawns it via
        // Process. -Wno-objc-method-access allows the undeclared-selector calls; the
        // private AppleMediaServices framework (AMSMescal's home) is linked from
        // /System/Library/PrivateFrameworks. See plans/podcast-transcripts.md and
        // Sources/PodcastTokenHelper/main.m. build.sh bundles it under
        // Contents/Helpers and signs it beside wikictl. Gated on
        // `podcastTranscriptsEnabled` so WIKIFS_APP_STORE=1 drops it entirely.
        .executableTarget(
            name: "podcast-token-helper",
            path: "Sources/PodcastTokenHelper",
            cSettings: [
                // -Wno-objc-method-access: allow the undeclared private selectors.
                // -fno-objc-arc: the reference is MRC — under ARC, calling a selector
                // with unknown ownership semantics is a hard error, not a warning.
                .unsafeFlags(["-Wno-objc-method-access", "-fno-objc-arc"]),
            ],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .unsafeFlags([
                    "-F/System/Library/PrivateFrameworks",
                    "-framework", "AppleMediaServices",
                ]),
            ]
        ),
        // Portable logic tests — store, links, markdown algebra, registry,
        // shellwords, ranks, chunking, embeddings-meta, concurrency, queue/engine,
        // ACP wiring (pure), etc. These run on both macOS and Linux (#754).
        .testTarget(
            name: "WikiFSCoreTests",
            dependencies: ["WikiFSCore", "WikiCtlCore",
                           // WikiFSEngine is macOS-only at build time because it
                           // depends on the `ACP` product (macOS-only). On Linux
                           // the test target still builds — the ACP-backed tests
                           // are #if os(macOS)-guarded (#754, #780).
                           .target(name: "WikiFSEngine",
                                   condition: .when(platforms: [.macOS])),
                           // On Linux, several test files do `import SQLite3`
                           // to call sqlite3_* directly. The SDK's Swift module
                           // map isn't auto-available there — link the CSQLite
                           // system-module wrapper, same as WikiFSCore does
                           // (#754, #780).
                           .target(name: "CSQLite",
                                   condition: .when(platforms: [.linux])),
                           .product(name: "ACPModel", package: "swift-acp")],
            path: "Tests/WikiFSTests",
            swiftSettings: strictSwiftSettings
        ),
        // macOS-only tests — AppKit/WebKit/FileProvider/SwiftUI-hosted views,
        // Tantivy integration, MLX embedder, PDF extraction, JS linter/validator.
        // Every file is wrapped in #if os(macOS) so on Linux this compiles to an
        // empty module and `swift test` runs only WikiFSCoreTests (#754).
        .testTarget(
            name: "WikiFSAppTests",
            dependencies: [
                "WikiFSCore", "WikiCtlCore",
                .target(name: "WikiFSEngine", condition: .when(platforms: [.macOS])),
                .target(name: "WikiFS", condition: .when(platforms: [.macOS])),
                .target(name: "WikiFSMLX", condition: .when(platforms: [.macOS])),
                .target(name: "WikiFSFileProvider", condition: .when(platforms: [.macOS])),
                .target(name: "wikid", condition: .when(platforms: [.macOS])),
                .product(name: "TantivySwift", package: "tantivy.swift",
                         condition: .when(platforms: [.macOS])),
                .product(name: "ACPModel", package: "swift-acp"),
            ],
            path: "Tests/WikiFSAppTests",
            swiftSettings: strictSwiftSettings
        ),
        // The File Provider extension binary. build.sh repackages this into a
        // .appex bundle under Self Driving Wiki.app/Contents/PlugIns and signs it.
        .executableTarget(
            name: "WikiFSFileProvider",
            dependencies: ["WikiFSCore"],
            path: "Sources/WikiFSFileProvider",
            swiftSettings: [.unsafeFlags(["-warnings-as-errors"])],
            linkerSettings: [
                .linkedFramework("FileProvider"),
                // Override the Mach-O entry point to _NSExtensionMain (the same
                // entry Xcode gives app extensions). ExtensionFoundation
                // re-invokes the entry point to run the principal class; that
                // entry MUST be NSExtensionMain itself. A Swift main() that
                // calls NSExtensionMain() instead recurses infinitely on
                // re-invocation and SIGSEGVs. See Sources/.../main.swift.
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"]),
            ]
        ),
    ].filter {
        // Drop the private-API podcast helper for App Store builds (WIKIFS_APP_STORE=1);
        // the feature is also #if'd out of the Swift sources, so nothing references it.
        podcastTranscriptsEnabled || $0.name != "podcast-token-helper"
    }
)
