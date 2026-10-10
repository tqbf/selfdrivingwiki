import Foundation
import WikiFSCore

// pattern: Imperative Shell

/// Failures of the best-effort transcript cleanup pass (issue #1379). The
/// extraction queue item NEVER fails because cleanup failed — the raw
/// transcript stays canonical — so these errors exist to be logged with a
/// precise reason, not surfaced as extraction failures.
public enum TranscriptCleanupError: Error, Equatable, Sendable {
    /// The model produced nothing usable (empty, preamble-only, or a failed
    /// turn). The raw transcript stays canonical.
    case emptyOutput
}

/// One-document-in, one-document-out cleanup agent for raw transcripts
/// (issue #1379). The seam that makes the auto-cleanup pass testable: tests
/// stub this protocol instead of spawning an agent. The production conformer
/// runs a SINGLE-PASS model call with the `transcript-cleanup` prompt file —
/// never the wiki-writing ingestion system prompt, never a workspace, never
/// a tool loop.
public protocol TranscriptCleanupAgent: Sendable {
    /// Cleans one raw transcript. Throws on failure; the caller treats every
    /// throw as "keep the raw transcript, log the reason".
    func clean(rawTranscript: String) async throws -> String
}

/// Production cleanup agent: a one-shot model call on the DEDICATED
/// transcript-cleanup stage with the bundled `transcript-cleanup` prompt as
/// the system prompt. The injected `AgentProviderServices` is shared with
/// every other agent lane, so the cleanup pass resolves its provider/model
/// from `stageProviderIds["transcriptCleanup"]` (falling back to the global
/// default provider) and runs in the same strictly-fenced single-turn
/// sandbox shape as the summarizer lane — but is configured and attributed
/// independently of chat summarization.
public struct ModelTranscriptCleanupAgent: TranscriptCleanupAgent {
    private let services: any AgentProviderServices

    public init(services: any AgentProviderServices) {
        self.services = services
    }

    public func clean(rawTranscript: String) async throws -> String {
        let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw TranscriptCleanupError.emptyOutput
        }
        // The cleanup lane's OWN stage (issue #1379): independently pinnable
        // (`stageProviderIds["transcriptCleanup"]`), never the chat
        // summarizer's configuration.
        let preparation = try await services.prepareTranscriptCleanup()
        // nil AND whitespace-only model results are both "nothing usable"
        // (the one-shot lane already folds a failed turn into nil).
        guard let cleaned = try await services.modelTransform(
            text: trimmed,
            systemPrompt: PublicPrompts.transcriptCleanup,
            preparation: preparation),
            cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            throw TranscriptCleanupError.emptyOutput
        }
        return cleaned
    }
}
