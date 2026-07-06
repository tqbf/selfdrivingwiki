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
    ],
    targets: [
        // Statically-linked sqlite-vec (semantic vector search). The amalgamation
        // is compiled with -DSQLITE_CORE so it registers on a connection without
        // sqlite3_load_extension (which the macOS system SQLite omits). See
        // Sources/CSqliteVec/README.md. The app still uses the system SQLite;
        // only the vec extension is vendored.
        .target(
            name: "CSqliteVec",
            path: "Sources/CSqliteVec",
            publicHeadersPath: "include",
            cSettings: [
                .define("SQLITE_CORE"),
                .define("SQLITE_VEC_STATIC"),
                // sqlite-vec.c #includes "sqlite3ext.h"/"sqlite3.h" (from the
                // macOS SDK) and "sqlite-vec.h" (in this target's root).
                .headerSearchPath("."),
            ]
        ),
        // Non-UI core: page model, ULID, the WikiStore protocol + SQLite
        // implementation, and the @Observable WikiStoreModel. Depended on by
        // the executable AND the test target so logic is testable without a
        // running app (SWIFTUI-RULES §9.1 — model logic in its own target).
        .target(
            name: "WikiFSCore",
            dependencies: [
                "CSqliteVec",
            ],
            path: "Sources/WikiFSCore",
            // NaturalLanguage: semantic-search embeddings. JavaScriptCore: the
            // MermaidValidator runs the vendored merval bundle in a JSContext
            // (system framework — no Node) to validate ```mermaid blocks on save.
            swiftSettings: podcastSwiftSettings,
            linkerSettings: [
                .linkedFramework("NaturalLanguage"),
                .linkedFramework("JavaScriptCore"),
            ]
        ),
        // App-only MiniLM (MLX/Metal) embeddings. Links MLX (Metal/Accelerate)
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
            path: "Sources/WikiFSMLX"
        ),
        .executableTarget(
            name: "WikiFS",
            dependencies: [
                "WikiFSCore",
                "WikiFSMLX",
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            path: "Sources/WikiFS",
            // WKWebView for the reader path (Sources/WikiFS/WikiReaderView.swift)
            // — the single markdown reader (replaced the vendored Textual).
            swiftSettings: podcastSwiftSettings,
            linkerSettings: [.linkedFramework("WebKit")]
        ),
        // wikictl's logic (arg parsing, command dispatch, wiki resolution, the
        // Darwin post) lives in a LIBRARY target so it's unit-testable — the same
        // split WikiFSCore uses (logic out of the executable). The executable
        // below is a thin process shell over it.
        .target(
            name: "WikiCtlCore",
            dependencies: ["WikiFSCore"],
            path: "Sources/WikiCtlCore"
        ),
        // wikictl — the agent's write path (plans/llm-wiki.md Phase A). A
        // scriptable CLI that writes straight to a wiki's <ulid>.sqlite in the
        // App Group container and posts a per-wiki Darwin notification so the app
        // refreshes. Reads still go via the read-only File Provider mount; this
        // is the WRITE half of "read via the mount, write via wikictl".
        .executableTarget(
            name: "wikictl",
            dependencies: ["WikiFSCore", "WikiCtlCore"],
            path: "Sources/wikictl"
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
        .testTarget(
            name: "WikiFSTests",
            dependencies: ["WikiFSCore", "WikiCtlCore", "WikiFS", "WikiFSMLX", "WikiFSFileProvider"],
            path: "Tests/WikiFSTests",
            // Matches WikiFSCore so the gated podcast test files compile in/out too.
            swiftSettings: podcastSwiftSettings
        ),
        // The File Provider extension binary. build.sh repackages this into a
        // .appex bundle under Self Driving Wiki.app/Contents/PlugIns and signs it.
        .executableTarget(
            name: "WikiFSFileProvider",
            dependencies: ["WikiFSCore"],
            path: "Sources/WikiFSFileProvider",
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
