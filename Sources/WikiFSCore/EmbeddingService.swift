import Foundation
@preconcurrency import NaturalLanguage

/// Thin wrapper around Apple's `NLEmbedding` (macOS 15). Produces a 512‑dim
/// Float32 BLOB from a text string, suitable for `vec_distance_cosine`.
///
/// The model loads lazily (first call to embeddingBlob) and is guarded so
/// that test/CI environments never touch it.
public enum EmbeddingService {
    nonisolated(unsafe) private static var _model: NLEmbedding?
    private static let lock = NSLock()

    private static func model() -> NLEmbedding? {
        lock.lock()
        defer { lock.unlock() }
        if let m = _model { return m }
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return nil }
        guard #available(macOS 15, *) else { return nil }
        let m = NLEmbedding.sentenceEmbedding(for: .english)
        _model = m
        return m
    }

    public static func embeddingBlob(for text: String) -> Data? {
        guard let m = model() else { return nil }
        guard let doubles = m.vector(for: text) else { return nil }
        let floats = doubles.map { Float32($0) }
        return floats.withUnsafeBytes { Data($0) }
    }

    public static func embeddingBlob(title: String, body: String) -> Data? {
        let text = body.isEmpty ? title : "\(title)\n\n\(body)"
        return embeddingBlob(for: text)
    }
}
