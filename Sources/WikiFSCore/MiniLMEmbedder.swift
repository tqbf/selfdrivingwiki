import Foundation
import Hub
import MLX
import MLXEmbedders
import MLXNN
import Tokenizers

/// On-device MiniLM embeddings via MLX (Metal/GPU).
///
/// Loads `all-MiniLM-L6-v2` (bf16) from a local model directory (downloaded by
/// `tools/minilm-prepare/download.py`, gitignored). Produces 384-dim, mean-pooled,
/// L2-normalized embeddings matching the `sentence-transformers` recipe.
///
/// Thread safety: MLX models are not safe for concurrent calls, so access is
/// serialized with an `NSLock`. This gives a synchronous `vector(for:)` (fitting
/// the `Embedder` protocol) while remaining safe off-main (Phase 3 backfill).
/// `@unchecked Sendable` because the lock provides the concurrency guarantee.
public final class MiniLMEmbedder: @unchecked Sendable {
    public static let identifier = "minilm-384"
    public let dimension = 384

    private let model: EmbeddingModel
    private let tokenizer: any Tokenizer
    private let pooler: Pooling
    private let lock = NSLock()

    /// Loads the model + tokenizer from a local model directory URL (no Hub download).
    public init(modelDirectoryURL: URL) async throws {
        // all-MiniLM-L6-v2 (sentence-transformers) = mean pool + L2 normalize.
        // The bf16 model dir lacks `1_Pooling/config.json`, so MLXEmbedders'
        // `loadModelContainer` would default the strategy to `.none`. Use the
        // lower-level `load()` and force `.mean` for sentence-transformers parity.
        let configuration = ModelConfiguration(directory: modelDirectoryURL)
        let (loadedModel, loadedTokenizer) = try await load(
            hub: HubApi(), configuration: configuration)
        self.model = loadedModel
        self.tokenizer = loadedTokenizer
        self.pooler = Pooling(strategy: .mean)
    }

    /// Returns a 384-dim L2-normalized embedding, or nil for empty input / failure.
    public func vector(for text: String) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }

        let tokens = tokenizer.encode(text: text, addSpecialTokens: true)
        guard !tokens.isEmpty else { return nil }

        let input = MLXArray(tokens).expandedDimensions(axis: 0)              // [1, seq]
        let mask = MLXArray(Array(repeating: 1, count: tokens.count))
            .expandedDimensions(axis: 0)                                      // [1, seq]
        let tokenTypes = MLXArray.zeros(like: input)

        let output = model(
            input, positionIds: nil, tokenTypeIds: tokenTypes, attentionMask: mask)
        let pooled = pooler(output, mask: mask, normalize: true, applyLayerNorm: false)
        pooled.eval()
        return pooled.asArray(Float.self)                                     // [384]
    }
}
