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
/// The macOS integration target can wedge SwiftPM's shared test helper when its
/// AppKit, WebKit, File Provider, and daemon suites overlap. Keep it out of the
/// default test graph; opt in with `WIKIFS_APP_TESTS=1 swift test`.
let appTestsEnabled = ProcessInfo.processInfo.environment["WIKIFS_APP_TESTS"] == "1"
let podcastSwiftSettings: [SwiftSetting] = podcastTranscriptsEnabled ? [.define("PODCAST_TRANSCRIPTS")] : []
/// Treat compiler warnings as errors so they never silently accumulate (#493).
let strictSwiftSettings: [SwiftSetting] = podcastSwiftSettings + [.unsafeFlags(["-warnings-as-errors"])]

let package = Package(
    name: "WikiFS",
    platforms: [.macOS("26.0")],
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
        // GRDB.swift — GRDB toolkit for SQLite. `GRDBWikiStore` is the sole
        // production store backend, and QueueStore also uses DatabaseQueue +
        // DatabaseMigrator. See plans/grdb-adoption.md.
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        // swift-crypto — Apple's Swift Crypto package. On macOS, `CryptoKit`
        // (system framework) provides SHA256 etc. On Linux, this package
        // provides the identical API under the `Crypto` module. Declared
        // directly so WikiFSCore can depend on the `Crypto` product on Linux
        // (#754, #780).
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
        // tantivy.swift — Rust Tantivy full-text search via UniFFI bindings + an
        // @TantivyDocument macro. Provides the app/CLI BM25 lexical search leg
        // that fuses with vector similarity through the `bm25Leg` store seam.
        // macOS arm64 only: the pre-built XCFramework has no x86_64 slice, which
        // is acceptable because MLX already requires Apple Silicon. See
        // plans/tantivy-search-sidecar.md.
        .package(url: "https://github.com/wsargent/tantivy.swift.git", from: "0.3.5"),
        // Yams — YAML decoding for CordisLoader patch files
        // (bundles/profiles/home/--patch layers). See plans/cordis-full-architecture.md.
        .package(url: "https://github.com/jpsim/Yams", from: "5.0.0"),
    ],
    targets: [
        // Foundation-only typed component runtime. Cordis owns actor-isolated
        // service and component lifecycles, but no SwiftUI, store, XPC, or queue
        // domain types. See plans/cordis-swift-components.md.
        .target(
            name: "Cordis",
            dependencies: ["WikiFSTypes"],
            path: "Sources/Cordis",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "CordisTests",
            dependencies: ["Cordis"],
            path: "Tests/CordisTests",
            swiftSettings: strictSwiftSettings
        ),
        // Declarative boot composition: entries, layered patches (bundle →
        // profile → home → --patch), and the profile boot driver. See
        // plans/cordis-full-architecture.md.
        .target(
            name: "CordisLoader",
            dependencies: [
                "Cordis",
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Sources/CordisLoader",
            resources: [.copy("../../bundles")],
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "CordisLoaderTests",
            dependencies: ["Cordis", "CordisLoader"],
            path: "Tests/CordisLoaderTests",
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "DynamicRendererPRSeriesAudit",
            path: "Sources/DynamicRendererPRSeriesAudit",
            swiftSettings: strictSwiftSettings
        ),
        // No-dependency process fixture for Phase 0 extractor lifecycle tests.
        .executableTarget(
            name: "ExtractorProcessFixture",
            path: "Sources/ExtractorProcessFixture",
            swiftSettings: strictSwiftSettings
        ),
        // Development-only validator for local renderer package authoring. The
        // core owns argument parsing, isolated validation roots, and cleanup;
        // the executable is a thin stdout/stderr process shell.
        .target(
            name: "RendererPackageToolCore",
            dependencies: ["WikiFSCore"],
            path: "Sources/RendererPackageToolCore",
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "RendererPackageTool",
            dependencies: ["RendererPackageToolCore"],
            path: "Sources/RendererPackageTool",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "RendererPackageToolTests",
            dependencies: ["RendererPackageToolCore", "RendererPackageTool"],
            path: "Tests/RendererPackageToolTests",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "DynamicRendererPRSeriesAuditTests",
            dependencies: ["DynamicRendererPRSeriesAudit"],
            path: "Tests/DynamicRendererPRSeriesAuditTests",
            swiftSettings: strictSwiftSettings
        ),
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
        .target(
            name: "CRendererPackageMove",
            path: "Sources/CRendererPackageMove",
            publicHeadersPath: "include"
        ),
        // Pinned local Tree-sitter runtime and generated parser sources for the
        // reader's inert fenced-code syntax highlighting. This C target has no
        // package-manager, system-package, or runtime-download dependency.
        .target(
            name: "CTreeSitterHighlighting",
            path: "Sources/CTreeSitterHighlighting",
            exclude: [
                "Runtime/alloc.c",
                "Runtime/get_changed_ranges.c",
                "Runtime/language.c",
                "Runtime/lexer.c",
                "Runtime/node.c",
                "Runtime/parser.c",
                "Runtime/query.c",
                "Runtime/stack.c",
                "Runtime/subtree.c",
                "Runtime/tree.c",
                "Runtime/tree_cursor.c",
                "Runtime/wasm_store.c",
                "Runtime/wasm/stdlib.c",
            ],
            publicHeadersPath: "include",
            cSettings: [
                // Upstream Tree-sitter compiles its runtime with `-Isrc`, and its
                // vendored ICU subset relies on it: Runtime/unicode/utf8.h asks for
                // "unicode/umachine.h" and "unicode/utf.h", which only resolve to
                // the pinned copies when Runtime/ is a header search root. Without
                // this the includes fall through to the SDK's system ICU — dragging
                // in urename.h and the deprecated utf_old.h, and silently swapping
                // the pinned U8_*/U16_* decoding macros for the platform's.
                .headerSearchPath("Runtime"),
                // The pinned Scala scanner has optional stderr diagnostics behind
                // DEBUG. Keep generated vendor bytes intact and prevent project
                // build settings from enabling those diagnostics at runtime.
                .unsafeFlags(["-UDEBUG"]),
            ]
        ),
        // The native ordinary-fence highlighter is a leaf library so the app
        // and the release benchmark link the exact same Swift/C implementation.
        // It deliberately owns no UI, renderer, parser, tree, or cursor state.
        .target(
            name: "WikiFSCodeHighlighting",
            dependencies: ["CTreeSitterHighlighting"],
            path: "Sources/WikiFSCodeHighlighting",
            swiftSettings: strictSwiftSettings
        ),
        // Thin process shell for the opt-in, fresh-process release measurement.
        // It is not a WikiFS app resource or a shipping product.
        .executableTarget(
            name: "CodeHighlightBenchmark",
            dependencies: ["WikiFSCodeHighlighting"],
            path: "Sources/CodeHighlightBenchmark",
            swiftSettings: strictSwiftSettings
        ),
        // Shared leaf types (PageID, ULID, ResourceKind, EmbedTarget, ParsedLink)
        // — Foundation-only, depended on by WikiFSLinks and WikiFSCore. Extracted
        // from WikiFSCore in module restructuring Phase 1 (#532) so the pure-logic
        // link cluster (WikiFSLinks) and the store/protocol (WikiFSCore) can both
        // reference these foundational types without a circular dependency.
        .target(
            name: "WikiFSTypes",
            dependencies: [
                // macOS uses CryptoKit; Linux resolves the matching API from
                // swift-crypto's Crypto module.
                .product(name: "Crypto", package: "swift-crypto",
                         condition: .when(platforms: [.linux])),
            ],
            path: "Sources/WikiFSTypes",
            swiftSettings: strictSwiftSettings
        ),
        // The app↔daemon XPC contract — the single, explicit boundary between
        // the `wikid` XPC service (server) and its clients. Holds only the two
        // `@objc` protocols (WikiDaemonProtocol + WikiDaemonEventSink) and the
        // shared WikiDaemonError. Foundation-only leaf: every payload crosses
        // the wire as JSON `Data`, so the protocols reference no domain types
        // (the DTOs stay in WikiFSCore/WikiFSEngine). All source is
        // `#if os(macOS)` (NSXPC/@objc are unavailable on Linux), so the module
        // is empty there. See plans/xpc-service-migration.md.
        .target(
            name: "WikiDaemonContract",
            path: "Sources/WikiDaemonContract",
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
        // JavaScriptCore: MarkdownLinter runs vendored markdownlint JS; Mermaid
        // validation uses the bundled Mermaid v11 library (no Node at runtime).
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
                // TantivySwift (Tantivy FFI + @TantivyDocument macro) backs the
                // BM25 lexical search leg. macOS-only: the pre-built XCFramework
                // ships only a macOS arm64 slice. Guarded with #if os(macOS) in
                // source; the dependency is conditional so Linux builds don't try
                // to build it (#754).
                .product(name: "TantivySwift", package: "tantivy.swift",
                         condition: .when(platforms: [.macOS])),
            ],
            path: "Sources/WikiFSSearch",
            swiftSettings: strictSwiftSettings
        ),
        // Non-UI core: page model, the WikiStore protocol, GRDBWikiStore, and
        // the @Observable WikiStoreModel. Depended on by the executable AND the
        // test target so logic is testable without a running app (SWIFTUI-RULES
        // §9.1 — model logic in its own target).
        .target(
            name: "WikiFSCore",
            dependencies: [
                "Cordis",
                "WikiFSTypes",
                "WikiFSLinks",
                "WikiFSMarkdown",
                "WikiFSSearch",
                "CRendererPackageMove",
                .product(name: "GRDB", package: "GRDB.swift"),
                // On Linux, `import SQLite3` needs this system module wrapper.
                // On macOS, the SDK provides SQLite3 directly.
                .target(name: "CSQLite", condition: .when(platforms: [.linux])),
                // On macOS, `CryptoKit` (system framework) provides SHA256.
                // On Linux, swift-crypto provides the identical API under the
                // `Crypto` module (#754, #780).
                .product(name: "Crypto", package: "swift-crypto",
                         condition: .when(platforms: [.linux])),
            ],
            path: "Sources/WikiFSCore",
            resources: [
                // Prompt markdown files, bundled as read-only resources so they
                // are available inside the .app's Contents/Resources/ at runtime.
                // Loaded via Bundle.module (see PromptLoader.swift).
                .copy("Resources/Prompts"),
                .copy("../../docs/skills/renderer-package-maintainer/references/wiki-state-chat-reference.md"),
            ],
            swiftSettings: strictSwiftSettings
        ),
        // MLX on-device MiniLM embeddings. Kept out of WikiFSCore so the File
        // Provider extension never links MLX/Metal (com.apple.fileprovider-nonui
        // forbids Metal on macOS 26). Core reaches the implementation via the
        // injectable EmbeddingService.miniLMFactory seam; the app installs it at
        // launch through EmbedderBootstrap. Mirrors the PDFKit isolation.
        .target(
            name: "WikiFSMLX",
            dependencies: [
                "WikiFSCore",
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
            ],
            path: "Sources/WikiFSMLX",
            swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]
        ),
        // The agent execution engine — extracted from the app target so the
        // bundled `wikid` XPC service can link it. Holds AgentLauncher,
        // ACPBackend, AgentOperationRunner, GenerationGate, ExtractionCoordinator,
        // AgentBackend/Factory, OperationRequest, queue workers, and the ACP
        // stall-recovery + permission seams. See plans/multi-wiki-daemon.md §3.
        .target(
            name: "WikiFSEngine",
            dependencies: [
                "Cordis",
                "CordisLoader",
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
                "Cordis",
                "WikiFSCore",
                "WikiFSCodeHighlighting",
                // The XPC contract — the app implements WikiDaemonEventSink
                // (DaemonQueueEventSink). Empty on Linux; harmless there.
                "WikiDaemonContract",
                // WikiFS (the app) is macOS-only — links WebKit, MLX, etc.
                .target(name: "WikiFSEngine", condition: .when(platforms: [.macOS])),
                // WikiCtlCore provides DaemonWorkloadClient + WikiDaemonConnection
                // for the app's XPC proxy to the wikid daemon (Phase A+B).
                .target(name: "WikiCtlCore", condition: .when(platforms: [.macOS])),
                "WikiFSMLX",
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            path: "Sources/WikiFS",
            resources: [
                // The reviewed package is copied into the executable resource
                // bundle. Runtime bootstrap reads only this bundled location,
                // never the source checkout.
                .copy("../../RendererPackages/Excalidraw"),
            ],
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
            dependencies: [
                "WikiFSCore",
                "CordisLoader",
                // The XPC contract — the typed client (WikiDaemonConnection +
                // DaemonWorkloadClient) speaks WikiDaemonProtocol + throws
                // WikiDaemonError. Empty on Linux; harmless there.
                "WikiDaemonContract",
                // WikiFSEngine is needed for DaemonWorkloadClient (Phase 0 daemon
                // workloads) which decodes QueueSnapshot from XPC JSON. macOS-only
                // because WikiFSEngine pulls in the ACP product.
                .target(name: "WikiFSEngine",
                        condition: .when(platforms: [.macOS])),
            ],
            path: "Sources/WikiCtlCore",
            // Must match WikiFSCore's PODCAST_TRANSCRIPTS flag so conditional
            // API in SourceRefreshService (the podcast refresh branch) compiles
            // consistently across the dependency.
            swiftSettings: strictSwiftSettings
        ),
        // wikictl — the agent's scriptable path into a wiki. It opens the wiki's
        // <ulid>.sqlite in the App Group container via GRDBWikiStore, performs
        // read/write commands, and posts a per-wiki Darwin notification after
        // committing writes so the app refreshes. Raw source reads go through the
        // `wikictl file` family rather than the File Provider mount.
        .executableTarget(
            name: "wikictl",
            dependencies: ["WikiFSCore", "WikiCtlCore"],
            path: "Sources/wikictl",
            swiftSettings: strictSwiftSettings
        ),
        // Test-only process helper for kernel-lock integration coverage. It is
        // not bundled into the app or daemon.
        .executableTarget(
            name: "ProviderConfigMutationHelper",
            dependencies: ["WikiFSCore"],
            path: "Sources/ProviderConfigMutationHelper",
            swiftSettings: strictSwiftSettings
        ),
        // wikid — the bundled XPC service (Contents/XPCServices/wikid.xpc). It
        // owns the live wiki registry + GRDBWikiStore lifecycle and serves app
        // clients through WikiDaemonProtocol. macOS runs it as an on-demand XPC
        // service tied to the app; Linux keeps the portable stdio JSON-RPC path.
        // On macOS it also links WikiFSEngine for queue/chat workloads; on Linux
        // that workload host is compiled out because ACP is macOS-only.
        .executableTarget(
            name: "wikid",
            dependencies: [
                "WikiFSCore",
                // The XPC contract — the daemon IS the server: it implements
                // WikiDaemonProtocol + holds WikiDaemonEventSink proxies. Empty
                // on Linux (the daemon uses the stdio transport there).
                "WikiDaemonContract",
                .target(name: "WikiFSEngine",
                        condition: .when(platforms: [.macOS])),
            ],
            path: "Sources/wikid",
            swiftSettings: strictSwiftSettings
        ),
        // FuzzHarness — property-based fuzzer for the pure-logic parser cluster
        // (WikiFSLinks + WikiFSMarkdown). NOT a swift-test target — it's a
        // standalone executable that runs an open-ended grammar-driven fuzzer
        // against the wiki-link / markdown / HTML parsers to hunt memory-safety
        // bugs (precondition failures, force-unwraps, EXC_BAD_ACCESS). Builds
        // with Address Sanitizer via the documented user command:
        //   swift build --target FuzzHarness -Xswiftc -sanitize=address
        // and runs as `.build/debug/FuzzHarness [seed] [iterations]`. See
        // plans/fuzz-harness.md for the full design.
        //
        // -sanitize=address is intentionally NOT baked into unsafeFlags —
        // SwiftPM refuses to mix sanitized and non-sanitized object files
        // across git-imported dependencies, and `-warnings-as-errors` interacts
        // poorly with the sanitizer runtime. Documenting the build flag on the
        // command line is the standard pattern (clang/swift docs).
        .executableTarget(
            name: "FuzzHarness",
            dependencies: ["WikiFSLinks", "WikiFSMarkdown", "WikiFSTypes"],
            path: "Sources/FuzzHarness",
            resources: [
                .copy("fuzz-dict.txt")
            ],
            // No `-warnings-as-errors` here — fuzzer output is noisy and the
            // harness deliberately exercises formatting paths that are
            // sometimes_warnable. The dependencies still build strict.
            swiftSettings: []
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
            dependencies: ["Cordis", "CordisLoader", "WikiFSCore", "WikiCtlCore", "ProviderConfigMutationHelper",
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
            // Compiler-boundary fixtures deliberately include invalid Swift.
            // They are invoked directly by IdentifierBoundaryTypecheckTests,
            // not compiled as part of the test target itself.
            exclude: ["Fixtures"],
            swiftSettings: strictSwiftSettings
        ),
        // Renderer contract tests depend on the portable leaf target alone.
        // This makes an accidental WikiFSTypes -> WikiFSCore dependency a
        // package-graph failure on every supported platform.
        .testTarget(
            name: "WikiFSTypesRendererTests",
            dependencies: ["WikiFSTypes"],
            path: "Tests/WikiFSTypesRendererTests",
            swiftSettings: strictSwiftSettings
        ),
        // Signal-target validation tests compile against the pure validation
        // target only. They deliberately cannot link the production `kill`
        // closures in WikiFSCore, so a test can never signal a real process.
        .testTarget(
            name: "ProcessSignalSafetySeamTests",
            dependencies: ["WikiFSTypes"],
            path: "Tests/ProcessSignalSafetySeamTests",
            swiftSettings: strictSwiftSettings
        ),
        // macOS-only integration tests — AppKit/WebKit/FileProvider/SwiftUI-hosted
        // views, Tantivy integration, MLX embedder, PDF extraction, JS linter/
        // validator. Kept out of the default test graph because these suites can
        // wedge SwiftPM's shared test helper when run alongside daemon/app tests;
        // opt in with WIKIFS_APP_TESTS=1 (#754, #949).
        .testTarget(
            name: "WikiFSAppTests",
            dependencies: [
                "WikiFSCore", "WikiCtlCore", "WikiDaemonContract",
                "WikiFSCodeHighlighting",
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
            // The deterministic benchmark corpus is read through #filePath so
            // fixture construction remains outside timed samples; it is not a
            // SwiftPM runtime resource.
            exclude: ["Fixtures"],
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "CodeHighlightBenchmarkTests",
            dependencies: ["CodeHighlightBenchmark", "WikiFSCodeHighlighting"],
            path: "Tests/CodeHighlightBenchmarkTests",
            swiftSettings: strictSwiftSettings
        ),
        // The File Provider extension binary. build.sh repackages this into a
        // .appex bundle under Self Driving Wiki.app/Contents/PlugIns and signs it.
        // Declared unconditionally so macOS test dependencies can name it; the
        // source files are #if os(macOS)-guarded, and the Linux filter below keeps
        // the target name available while dropping app/MLX/test targets that would
        // pull unavailable frameworks or Cmlx CUDA code.
        .executableTarget(
            name: "WikiFSFileProvider",
            dependencies: ["WikiFSCore", "WikiFSTypes"],
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
        // Keep the Linux manifest focused on portable code. Filter targets that
        // require Obj-C private frameworks, AppKit/SwiftUI/WebKit/FileProvider,
        // Darwin notifications, or MLX/Cmlx GPU code that fails on CUDA-less
        // Linux runners. macOS is unaffected; WIKIFS_APP_STORE=1 still drops the
        // private podcast helper on all platforms (#754, #780).
        //
        // Filtered on Linux:
        // - podcast-token-helper: Obj-C executable, Foundation.h + private
        //   AppleMediaServices framework.
        // - wikictl: standalone macOS CLI; uses Darwin notification and XPC seams.
        // - WikiFS: app executable; imports AppKit/SwiftUI and links WebKit/MLX.
        // - WikiFSMLX: links MLXEmbedders → mlx-swift → Cmlx GPU code.
        // - WikiFSAppTests: macOS integration target that depends on app/MLX/FileProvider.
        //
        // WikiFSFileProvider stays declared because its sources are os(macOS)-
        // guarded and macOS-only test dependencies need the target name. wikid is
        // intentionally NOT filtered: it has a Linux stdio JSON-RPC transport.
        if $0.name == "WikiFSAppTests" && !appTestsEnabled { return false }
        #if os(Linux)
        if $0.name == "podcast-token-helper" { return false }
        if $0.name == "wikictl" { return false }
        if $0.name == "WikiFS" { return false }
        if $0.name == "WikiFSMLX" { return false }
        if $0.name == "WikiFSAppTests" { return false }
        #endif
        return podcastTranscriptsEnabled || $0.name != "podcast-token-helper"
    }
)
