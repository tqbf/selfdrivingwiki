import Foundation
import MLX
import WikiFSCore

/// Installs the MiniLM (MLX/Metal) embedder into Core's `EmbeddingService` seam.
///
/// Lives in this **app-only** `WikiFSMLX` target, NOT `WikiFSCore`, because
/// `import MLX` links Metal/Accelerate. The read-only File Provider extension
/// (`WikiFSFileProvider`) links `WikiFSCore`; if `WikiFSCore` imported MLX the
/// extension would pull Metal — forbidden by `com.apple.fileprovider-nonui` on
/// macOS 26, which asserts against it in `_EXRunningExtension._start` and
/// crashes the extension on launch. Mirrors the PDFKit/AppKit isolation in
/// `Sources/WikiFS/PDFTitleExtractor.swift`.
///
/// Core reaches the MiniLM implementation through `EmbeddingService.miniLMFactory`
/// (default `nil`); the app installs it here at launch. Non-app contexts (the
/// extension, `wikictl`, tests without this target linked) keep the default and
/// fall back to `NLEmbedder`.
public enum EmbedderBootstrap {

    /// Register the MiniLM embedder factory with Core. Idempotent. Call once at
    /// launch from `WikiFSApp.init` (before the store opens / backfill begins).
    /// `MiniLMEmbedder.identifier` must equal `EmbeddingService.miniLMIdentifier`.
    public static func install() {
        EmbeddingService.miniLMFactory = { modelDirectoryURL in
            // Wrap MLX model construction in `withError` so any failure in the
            // one-time GPU init (e.g. the metallib not being found) becomes a
            // Swift throw that EmbeddingService.configure()'s do/catch handles
            // (→ _embedder stays nil → NLEmbedder fallback / backfill no-ops).
            // WITHOUT this, MLX's *default* C++ error handler is still active
            // (mlx-swift only installs its handler lazily on first withError
            // call) and calls exit() — an uncatchable process death that leaves
            // no crash report.
            try await withError {
                try await MiniLMEmbedder(modelDirectoryURL: modelDirectoryURL)
            }
        }
    }
}
