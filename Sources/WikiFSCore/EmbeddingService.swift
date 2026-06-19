import Foundation
@preconcurrency import NaturalLanguage

/// Thin wrapper around Apple's `NLEmbedding` (macOS 15). Produces a 512‑dim
/// Float32 BLOB from a text string, suitable for `vec_distance_cosine`.
///
/// `NLEmbedding.sentenceEmbedding(for:)` loads ~2 GB of CoreML model on first
/// use; the lazy `model` property defers that cost to the first embed call
/// rather than app launch.
public enum EmbeddingService {
    /// NLEmbedding is not Sendable (NSObject subclass). We hold it in a static
    /// that is only ever read on @MainActor or behind a lock — in practice
    /// `vector(for:)` is documented as thread-safe. `nonisolated(unsafe)` tells
    /// Swift 6 we accept responsibility for static initialization ordering.
    nonisolated(unsafe) private static let model: NLEmbedding? = {
        guard #available(macOS 15, *) else { return nil }
        return NLEmbedding.sentenceEmbedding(for: .english)
    }()

    // MARK: - Public

    /// Return a 512 × Float32 BLOB for `text`, or nil if the model is
    /// unavailable or the text cannot be embedded (e.g. empty / whitespace).
    public static func embeddingBlob(for text: String) -> Data? {
        guard let model else { return nil }
        guard let doubles = model.vector(for: text) else { return nil }
        // NLEmbedding returns [Double]; compact to Float32 for 50 % storage
        // savings (2048 B vs 4096 B per page).
        let floats = doubles.map { Float32($0) }
        return floats.withUnsafeBytes { Data($0) }
    }

    /// Convenience: embed the concatenated title + body of a page. Falls back
    /// to title-only if the body is empty. Returns nil if the resulting text
    /// cannot be embedded.
    public static func embeddingBlob(title: String, body: String) -> Data? {
        let text = body.isEmpty ? title : "\(title)\n\n\(body)"
        return embeddingBlob(for: text)
    }
}
