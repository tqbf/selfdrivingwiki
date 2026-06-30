import Foundation
@preconcurrency import NaturalLanguage

/// Embedding generation for semantic search. Wraps Apple's `NLEmbedding`
/// (macOS 15, 512-dim Float32 vectors).
///
/// Two entry points:
/// - ``embeddingBlob(for:)`` — one vector for a **short query** string.
/// - ``chunkedEmbeddings(for:maxChunks:)`` — one vector per **chunk** of a
///   (possibly long) document, via ``TextChunker``. This is the path the store
///   uses to index pages/sources: `NLEmbedding.vector(for:)` is slow on long
///   input and throws an **uncatchable C++ `std::bad_alloc`** above ~250k
///   chars, so documents are always chunked first.
///
/// The model loads lazily (first call) and is guarded so test/CLI environments
/// (where `Bundle.main` is not an `.app`) never touch it.
public enum EmbeddingService {
    nonisolated(unsafe) private static var _model: NLEmbedding?
    private static let lock = NSLock()

    private static func model() -> NLEmbedding? {
        lock.lock()
        defer { lock.unlock() }
        if let m = _model {
            DebugLog.store("embed.model cached hit")
            return m
        }
        guard Bundle.main.bundlePath.hasSuffix(".app") else {
            DebugLog.store("embed.model skip (not .app bundle)")
            return nil
        }
        guard #available(macOS 15, *) else {
            DebugLog.store("embed.model skip (macOS < 15)")
            return nil
        }
        let t0 = DispatchTime.now()
        let m = NLEmbedding.sentenceEmbedding(for: .english)
        let loadMs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
        _model = m
        DebugLog.store("embed.model LOAD \(String(format: "%.1f", loadMs)) ms main=\(Thread.isMainThread) loaded=\(m != nil)")
        return m
    }

    /// True when the `NLEmbedding` model is usable (app bundle + macOS 15+).
    /// NOTE: first call LOADS the model (~0.3 s on the main thread).
    public static var isAvailable: Bool {
        let available = model() != nil
        DebugLog.store("embed.isAvailable → \(available)")
        return available
    }

    /// One 512-dim Float32 BLOB for a short string (a search query). Returns
    /// `nil` when the model is unavailable.
    public static func embeddingBlob(for text: String) -> Data? {
        let t0 = DispatchTime.now()
        guard let m = model() else {
            DebugLog.store("embed.blob nil (no model) len=\(text.count)")
            return nil
        }
        guard let doubles = m.vector(for: text) else {
            DebugLog.store("embed.blob nil (vector returned nil) len=\(text.count)")
            return nil
        }
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
        // Diagnostic: log every NLEmbedding inference with its cost + input size.
        DebugLog.store("embed.call \(String(format: "%.1f", elapsedMs)) ms len=\(text.count) main=\(Thread.isMainThread)")
        // Log a concise caller chain for every call so we can identify the
        // trigger when filtered by time (e.g. a page click).
        let stack = Thread.callStackSymbols.dropFirst(2).prefix(5).joined(separator: " << ")
        DebugLog.store("embed.STACK \(stack)")
        let floats = doubles.map { Float32($0) }
        return floats.withUnsafeBytes { Data($0) }
    }

    /// Split text into embeddable chunks (capped + evenly sampled across the doc
    /// when very long), WITHOUT embedding. Lets a caller embed each chunk itself
    /// on the main actor (NLEmbedding/BNNS is **not** safe off-main) while
    /// yielding between chunks to keep the UI responsive.
    public static func chunks(for text: String, maxChunks: Int = 64) -> [String] {
        var c = TextChunker.chunk(text)
        if c.count > maxChunks { c = evenlySample(c, max: maxChunks) }
        DebugLog.store("embed.chunks → \(c.count) chunk(s) from len=\(text.count)")
        return c
    }

    /// One 512-dim Float32 BLOB per chunk of a (possibly long) document. The
    /// text is split by ``TextChunker`` so each `NLEmbedding` call stays small
    /// (fast + crash-free). Returns one blob per chunk in order; empty when the
    /// model is unavailable.
    ///
    /// `maxChunks` bounds the cost on huge documents: when a document yields
    /// more chunks than `maxChunks`, chunks are **evenly sampled across the whole
    /// document** (not just the prefix) so a passage deep in the file is still
    /// represented in the index.
    public static func chunkedEmbeddings(for text: String, maxChunks: Int = 64) -> [Data] {
        DebugLog.store("embed.chunked ENTER len=\(text.count) maxChunks=\(maxChunks)")
        guard model() != nil else {
            DebugLog.store("embed.chunked EXIT (no model)")
            return []
        }
        var chunks = TextChunker.chunk(text)
        if chunks.count > maxChunks {
            chunks = evenlySample(chunks, max: maxChunks)
        }
        let result = chunks.compactMap { embeddingBlob(for: $0) }
        DebugLog.store("embed.chunked EXIT → \(result.count) blob(s) from \(chunks.count) chunk(s)")
        return result
    }

    /// Pick up to `max` elements evenly spaced across `items` (always including
    /// the first and last), preserving order. Used to bound embedding cost on
    /// very long documents while keeping whole-document coverage.
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
