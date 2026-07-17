import Foundation
@preconcurrency import NaturalLanguage

/// Apple `NLEmbedding` behind the `Embedder` protocol (512-dim). This is the
/// **fallback** embedder, used when the MiniLM model is not bundled (e.g. dev
/// builds, fresh clones without the prepare step, test/CLI contexts).
///
/// NLEmbedding/CoreNLP is **not** safe off the main thread
/// (`BNNSFilterApplyBatch` crashes), so the Phase 3 backfill keeps the NLEmbedder
/// path on the main actor; this wrapper itself is just the lazy model load + the
/// vector call.
public struct NLEmbedder: Embedder {
    public static let identifier = "nlembedding-512"
    public let dimension = 512

    nonisolated(unsafe) private static var _model: NLEmbedding?
    private static let lock = NSLock()

    private static func model() -> NLEmbedding? {
        lock.lock()
        defer { lock.unlock() }
        if let m = _model { return m }
        // NLEmbedding only works in a real .app context; never touch it from
        // `swift test` / CLI (where Bundle.main is not an .app).
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return nil }
        guard #available(macOS 15, *) else { return nil }
        let m = NLEmbedding.sentenceEmbedding(for: .english)
        _model = m
        return m
    }

    public init() {}

    public func vector(for text: String) -> [Float]? {
        guard let m = NLEmbedder.model(), let doubles = m.vector(for: text) else { return nil }
        return doubles.map(Float.init)
    }
}
