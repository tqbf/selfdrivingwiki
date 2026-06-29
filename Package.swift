// swift-tools-version: 6.0
import PackageDescription

// Self Driving Wiki — native macOS SwiftUI wiki with a File Provider filesystem
// projection. Built with SwiftPM (no Xcode IDE, no xcodebuild); ./build.sh
// bundles the executable produced here into build/Self Driving Wiki.app and codesigns it.
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
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
            ],
            path: "Sources/WikiFSCore",
            // NaturalLanguage: semantic-search embeddings. JavaScriptCore: the
            // MermaidValidator runs the vendored merval bundle in a JSContext
            // (system framework — no Node) to validate ```mermaid blocks on save.
            linkerSettings: [
                .linkedFramework("NaturalLanguage"),
                .linkedFramework("JavaScriptCore"),
            ]
        ),
        .executableTarget(
            name: "WikiFS",
            dependencies: [
                "WikiFSCore",
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            path: "Sources/WikiFS",
            // WKWebView for the reader path (Sources/WikiFS/WikiReaderView.swift)
            // — the single markdown reader (replaced the vendored Textual).
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
        .testTarget(
            name: "WikiFSTests",
            dependencies: ["WikiFSCore", "WikiCtlCore", "WikiFS", "WikiFSFileProvider"],
            path: "Tests/WikiFSTests"
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
    ]
)
