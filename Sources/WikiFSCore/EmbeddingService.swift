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

    /// The identifier of the embedder selected for the current bundle, WITHOUT
    /// loading the model. Cheap + safe to call synchronously from any context.
    /// Used by `SQLiteWikiStore.ensureEmbedderConsistency()` for the
    /// `embedding_meta` cutover check.
    public static func selectedEmbedderIdentifier() -> String {
        guard Bundle.main.bundlePath.hasSuffix(".app") else {
            return NLEmbedder.identifier  // test / CLI context: no model loads
        }
        if Bundle.main.url(forResource: "all-MiniLM-L6-v2", withExtension: nil) != nil {
            return MiniLMEmbedder.identifier
        }
        return NLEmbedder.identifier
    }

    /// Async: load the selected embedder into memory. Call once from `WikiStoreModel`
    /// startup, before the backfill begins. Idempotent (a no-op once loaded).
    public static func configure() async {
        guard lock.withLock({ _embedder == nil }) else { return }
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return }

        if let modelDir = Bundle.main.url(forResource: "all-MiniLM-L6-v2", withExtension: nil) {
            do {
                let embedder = try await MiniLMEmbedder(modelDirectoryURL: modelDir)
                lock.withLock { _embedder = embedder }
            } catch {
                // MiniLM is bundled but failed to load — leave _embedder = nil.
                // IMPORTANT: do NOT fall back to NLEmbedder here. selectedEmbedderIdentifier()
                // already returned "minilm-384" (bundle present), so embedding_meta would be
                // written "minilm-384" while NLEmbedder produced 512-dim vectors → a dimension
                // mismatch on next launch. Leaving nil means isAvailable = false → backfill
                // no-ops; embedding_meta retains "minilm-384" so the next launch retries.
                DebugLog.store("EmbeddingService.configure: MiniLM load failed — \(error). Backfill disabled until the model loads.")
            }
        } else {
            lock.withLock { _embedder = NLEmbedder() }
        }
    }

    /// True when the active embedder is loaded and usable.
    public static var isAvailable: Bool {
        lock.withLock { _embedder } != nil
    }

    /// One Float32 BLOB for a short string (a search query). Returns `nil` when the
    /// embedder is unavailable.
    public static func embeddingBlob(for text: String) -> Data? {
        guard let embedder = lock.withLock({ _embedder }) else { return nil }
        guard let floats = embedder.vector(for: text) else { return nil }
        return floats.withUnsafeBytes { Data($0) }
    }

    /// Split text into embeddable chunks (capped + evenly sampled across the doc
    /// when very long), WITHOUT embedding.
    public static func chunks(for text: String, maxChunks: Int = 64) -> [String] {
        evenlySample(TextChunker.chunk(text), max: maxChunks)
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
        guard lock.withLock({ _embedder }) != nil else { return [] }
        return evenlySample(TextChunker.chunk(text), max: maxChunks).compactMap {
            embeddingBlob(for: $0)
        }
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
