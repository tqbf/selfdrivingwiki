import Foundation

/// Embedding generation for semantic search. Holds the active `Embedder`,
/// selected at launch: `MiniLMEmbedder` (384-dim, Metal/GPU) when the model is
/// bundled, else `NLEmbedder` (512-dim) — the prior behavior.
///
/// The store depends on the `Embedder` abstraction, so swapping the embedder is a
/// behind-the-scenes change: the chunk index stores opaque Float32 BLOBs and the
/// `vec_distance_cosine` queries are dimension-agnostic (as long as every vector
/// uses one dimension — enforced by the `embedding_meta` cutover, schema v15).
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
    /// Installed by the app (`WikiFSMLX.EmbedderBootstrap`) at launch; `nil` in
    /// non-app contexts (the extension, `wikictl`, tests without the app target)
    /// → MiniLM unavailable, `NLEmbedder` fallback used. Core never imports MLX.
    public nonisolated(unsafe) static var miniLMFactory: (@Sendable (URL) async throws -> any Embedder)?

    /// The identifier of the embedder selected for the current bundle, WITHOUT
    /// loading the model. Cheap + safe to call synchronously from any context.
    /// Used by `SQLiteWikiStore.ensureEmbedderConsistency()` for the
    /// `embedding_meta` cutover check.
    public static func selectedEmbedderIdentifier() -> String {
        guard Bundle.main.bundlePath.hasSuffix(".app") else {
            return NLEmbedder.identifier  // test / CLI context: no model loads
        }
        if Bundle.main.url(forResource: "all-MiniLM-L6-v2", withExtension: nil) != nil {
            return miniLMIdentifier
        }
        return NLEmbedder.identifier
    }

    /// Async: load the selected embedder into memory. Call once from `WikiStoreModel`
    /// startup, before the search-index upgrade runs. Idempotent (a no-op once loaded).
    public static func configure() async {
        guard lock.withLock({ _embedder == nil }) else { return }
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return }

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
        } else {
            lock.withLock { _embedder = NLEmbedder() }
            let loadMs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
            DebugLog.store("embed.model LOAD \(String(format: "%.1f", loadMs)) ms nlembedder main=\(Thread.isMainThread) loaded=true")
        }
    }

    /// True when the active embedder is loaded and usable.
    public static var isAvailable: Bool {
        let available = lock.withLock { _embedder } != nil
        DebugLog.debug("embed.isAvailable → \(available)")
        return available
    }

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
