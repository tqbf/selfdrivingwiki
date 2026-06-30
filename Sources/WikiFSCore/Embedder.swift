import Foundation

/// An embedder produces a fixed-dimension, L2-normalized Float32 vector for a
/// short text (a search query or a document chunk). The store depends on this
/// abstraction — not on any specific embedder (NLEmbedding vs MiniLM) — so the
/// active embedder can be swapped behind `EmbeddingService` without touching the
/// chunk index or the `vec_distance_cosine` queries (which are dimension-agnostic
/// as long as every vector uses one dimension).
public protocol Embedder: Sendable {
    /// Stable identifier for this embedder + its output dimension, e.g.
    /// `"nlembedding-512"`, `"minilm-384"`. Stored in `embedding_meta`; a mismatch
    /// with the stored value triggers the dimension-cutover wipe.
    static var identifier: String { get }

    /// Number of Float32 values in each output vector.
    var dimension: Int { get }

    /// An L2-normalized embedding, or `nil` when the model is unavailable or the
    /// input is empty.
    func vector(for text: String) -> [Float]?
}
