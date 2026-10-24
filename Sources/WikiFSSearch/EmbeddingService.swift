import Foundation

/// Embedding generation for semantic search. Holds the active `Embedder`,
/// selected at launch: `MiniLMEmbedder` (384-dim, Metal/GPU) when the model is
/// bundled. The legacy `NLEmbedder` (512-dim) branch requires an explicit
/// app-bundle `configure()` call; normal startup skips it when MiniLM is absent.
///
/// The store depends on the `Embedder` abstraction, so swapping the embedder is a
/// behind-the-scenes change: the chunk index stores opaque Float32 BLOBs and the
/// Swift-side dot product (issue #628 — `VectorCosine`) is dimension-agnostic
/// (as long as every vector uses one dimension — enforced by the
/// `embedding_meta` cutover, schema v15).
///
/// Two entry points:
/// - ``embeddingBlob(for:)`` — one vector for a **short query** string.
/// - ``chunkedEmbeddings(for:maxChunks:)`` — one vector per **chunk** of a
///   (possibly long) document, via ``TextChunker``. NLEmbedding is slow on long
///   input and throws an uncatchable `std::bad_alloc` above ~250k chars, so
///   documents are always chunked first (MiniLM truncates at 512 tokens instead).
public enum EmbeddingService {
    nonisolated(unsafe) private static var _embedder: (any Embedder)?
    private static let lock = NSLock()

    /// The MiniLM embedder's identifier (`"minilm-384"`). Kept in Core (not the
    /// MLX target) so `selectedEmbedderIdentifier` can reference it without
    /// linking MLX. The app-only `WikiFSMLX` target's `MiniLMEmbedder.identifier`
    /// MUST equal this.
    public static let miniLMIdentifier = "minilm-384"

    /// Factory that builds the MiniLM embedder from a bundled model directory.
    /// Installed by the app or daemon (`WikiFSMLX.EmbedderBootstrap`) at launch; `nil` in
    /// other contexts (the extension, `wikictl`, tests without the MLX target).
    /// An app caller can explicitly configure NLEmbedding when MiniLM is absent.
    /// Normal startup does not take that path. Core never imports MLX.
    public nonisolated(unsafe) static var miniLMFactory: (@Sendable (URL) async throws -> any Embedder)?

    /// The identifier of the embedder selected for the current bundle, WITHOUT
    /// loading the model. Cheap + safe to call synchronously from any context.
    /// Used by `GRDBWikiStore.ensureEmbedderConsistency()` for the
    /// `embedding_meta` cutover check.
    public static func selectedEmbedderIdentifier() -> String {
        #if os(macOS)
        guard isModelHostBundle(path: Bundle.main.bundlePath) else {
            return NLEmbedder.identifier  // test / CLI context: no model loads
        }
        if Bundle.main.url(forResource: "all-MiniLM-L6-v2", withExtension: nil) != nil {
            return miniLMIdentifier
        }
        return NLEmbedder.identifier
        #else
        // Linux: no NLEmbedder, no MiniLM — embeddings are unavailable.
        return "unavailable-linux"
        #endif
    }

    /// Async: load the selected embedder into memory. Call once from `WikiStoreModel`
    /// startup, before the search-index upgrade runs. Idempotent (a no-op once loaded).
    public static func configure() async {
        #if os(macOS)
        guard lock.withLock({ _embedder == nil }) else { return }
        guard isModelHostBundle(path: Bundle.main.bundlePath) else { return }

        let t0 = DispatchTime.now()
        let signpostState = DebugLog.signposter.beginInterval("embed.modelLoad")
        defer { DebugLog.signposter.endInterval("embed.modelLoad", signpostState) }

        if let modelDir = Bundle.main.url(forResource: "all-MiniLM-L6-v2", withExtension: nil),
           let factory = miniLMFactory {
            do {
                let embedder = try await factory(modelDir)
                lock.withLock { _embedder = embedder }
                let loadMs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
                DebugLog.store("embed.model LOAD \(String(format: "%.1f", loadMs)) ms minilm main=\(Thread.isMainThread) loaded=true")
            } catch {
                // MiniLM is bundled but failed to load — leave _embedder = nil.
                // IMPORTANT: do NOT fall back to NLEmbedder here. selectedEmbedderIdentifier()
                // already returned "minilm-384" (bundle present), so embedding_meta would be
                // written "minilm-384" while NLEmbedder produced 512-dim vectors → a dimension
                // mismatch on next launch. Leaving nil means isAvailable = false → the
                // upgrade no-ops; embedding_meta retains "minilm-384" so the next launch retries.
                DebugLog.store("EmbeddingService.configure: MiniLM load failed — \(error). Search-index upgrade disabled until the model loads.")
            }
        } else if Bundle.main.bundlePath.hasSuffix(".xpc") {
            // Daemon search can run off-main; NLEmbedding is not safe there.
            DebugLog.store("EmbeddingService.configure: daemon MiniLM model unavailable")
        } else {
            lock.withLock { _embedder = NLEmbedder() }
            let loadMs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
            DebugLog.store("embed.model LOAD \(String(format: "%.1f", loadMs)) ms nlembedder main=\(Thread.isMainThread) loaded=true")
        }
        #else
        // Linux: no NLEmbedder, no MiniLM — embeddings are permanently unavailable.
        // isAvailable stays false; the store handles this (cosine leg skipped, search
        // returns BM25-less results — acceptable per issue #754 acceptance).
        DebugLog.store("EmbeddingService.configure: no-op on Linux (embeddings unavailable)")
        #endif
    }

    /// True when the active embedder is loaded and usable.
    public static var isAvailable: Bool {
        let available = lock.withLock { _embedder } != nil
        DebugLog.debug("embed.isAvailable → \(available)")
        return available
    }

    /// The app and its bundled XPC daemon can load the same model resources.
    static func isModelHostBundle(path: String) -> Bool {
        return path.hasSuffix(".app") || path.hasSuffix(".xpc")
    }

    #if DEBUG
    /// Test-only hook: install a stub embedder so the Swift-side cosine path
    /// (`searchSimilar*`) can be exercised under `swift test` without the
    /// app-gated NLEmbedding/MiniLM. The caller is responsible for calling
    /// ``resetTestEmbedder`` to restore the default (nil) state afterwards.
    public static func installTestEmbedder(_ embedder: any Embedder) {
        lock.withLock { _embedder = embedder }
    }

    /// Test-only: clear any embedder installed via ``installTestEmbedder``.
    public static func resetTestEmbedder() {
        lock.withLock { _embedder = nil }
    }
    #endif

    /// One Float32 BLOB for a short string (a search query). Returns `nil` when the
    /// embedder is unavailable.
    public static func embeddingBlob(for text: String) -> Data? {
        let t0 = DispatchTime.now()
        guard let embedder = lock.withLock({ _embedder }) else {
            DebugLog.store("embed.blob nil (no embedder) len=\(text.count)")
            return nil
        }
        let signpostState = DebugLog.signposter.beginInterval("embed.infer")
        let floats = embedder.vector(for: text)
        DebugLog.signposter.endInterval("embed.infer", signpostState)
        guard let floats else {
            DebugLog.store("embed.blob nil (vector returned nil) len=\(text.count)")
            return nil
        }
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
        // Per-inference detail → `.debug` (not persisted by default). Flip on
        // with `log show --debug` when chasing who's hitting the embedder.
        DebugLog.debug("embed.call \(String(format: "%.1f", elapsedMs)) ms len=\(text.count) main=\(Thread.isMainThread)")
        // Caller chain, also `.debug`.
        let stack = Thread.callStackSymbols.dropFirst(2).prefix(5).joined(separator: " << ")
        DebugLog.debug("embed.STACK \(stack)")
        return floats.withUnsafeBytes { Data($0) }
    }

    /// Split text into embeddable chunks (capped + evenly sampled across the doc
    /// when very long), WITHOUT embedding.
    public static func chunks(for text: String, maxChunks: Int = 64) -> [String] {
        let c = evenlySample(TextChunker.chunk(text), max: maxChunks)
        DebugLog.debug("embed.chunks → \(c.count) chunk(s) from len=\(text.count)")
        return c
    }

    /// One Float32 BLOB per chunk of a (possibly long) document. The text is split
    /// by ``TextChunker`` so each embedder call stays small. Returns one blob per
    /// chunk in order; empty when the embedder is unavailable.
    ///
    /// `maxChunks` bounds the cost on huge documents: when a document yields more
    /// chunks than `maxChunks`, chunks are **evenly sampled across the whole
    /// document** (not just the prefix) so a passage deep in the file is still
    /// represented in the index.
    public static func chunkedEmbeddings(for text: String, maxChunks: Int = 64) -> [Data] {
        DebugLog.debug("embed.chunked ENTER len=\(text.count) maxChunks=\(maxChunks)")
        guard lock.withLock({ _embedder }) != nil else {
            DebugLog.debug("embed.chunked EXIT (no embedder)")
            return []
        }
        let chunks = evenlySample(TextChunker.chunk(text), max: maxChunks)
        let result = chunks.compactMap { embeddingBlob(for: $0) }
        DebugLog.debug("embed.chunked EXIT → \(result.count) blob(s) from \(chunks.count) chunk(s)")
        return result
    }

    /// Pick up to `max` elements evenly spaced across `items` (always including
    /// the first and last), preserving order. Bounds embedding cost on very long
    /// documents while keeping whole-document coverage.
    private static func evenlySample<T>(_ items: [T], max n: Int) -> [T] {
        guard items.count > n, n > 0 else { return items }
        var out: [T] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let idx = (items.count - 1) * i / Swift.max(1, n - 1)
            out.append(items[idx])
        }
        return out
    }
}
