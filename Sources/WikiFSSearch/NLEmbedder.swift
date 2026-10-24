import Foundation
#if os(macOS)
@preconcurrency import NaturalLanguage

/// Apple `NLEmbedding` behind the `Embedder` protocol (512-dim). This is the
/// legacy fallback embedder. An app caller must explicitly configure it when
/// MiniLM is absent; normal startup skips that path.
///
/// NLEmbedding/CoreNLP is **not** safe off the main thread
/// (`BNNSFilterApplyBatch` crashes). Any caller that opts into this fallback
/// must keep vector calls on the main actor. This wrapper loads the model and
/// returns its vectors.
public struct NLEmbedder: Embedder {
    public static let identifier = "nlembedding-512"
    public let dimension = 512

    nonisolated(unsafe) private static var _model: NLEmbedding?
    private static let lock = NSLock()

    private static func model() -> NLEmbedding? {
        lock.lock()
        defer { lock.unlock() }
        if let m = _model { return m }
        // Keep NLEmbedding in the app bundle. The daemon searches off-main,
        // so it uses MiniLM or keeps the cosine leg unavailable.
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
#endif // os(macOS)
