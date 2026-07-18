import Foundation

/// A presentation-layer bundle over a `SourceMarkdownVersion` carrying the
/// provenance the extraction compare UI (track C) needs: which backend produced
/// it (resolved from the PROV agent name → `ExtractionBackend.displayName`), the
/// model id, the body size, and whether it is the currently active HEAD.
///
/// Built by `GRDBWikiStore.processedMarkdownAlternatives(sourceID:)` from a
/// single joined query (smv → activity → agent), consolidating the old
/// two-call pattern (`processedMarkdownHistory` + `processedMarkdownAgentNames`).
/// `.version.content` is always the fully-resolved body (the resolved-body
/// invariant; see `SourceMarkdownVersion.content`).
public struct ExtractionAlternative: Identifiable, Hashable, Sendable {
    /// The version this alternative wraps.
    public let version: SourceMarkdownVersion
    /// User-facing backend label, e.g. "Claude (Anthropic API)". Falls back to a
    /// capitalized raw agent name for unknown/legacy agents (e.g. "Legacy").
    public let backendDisplayName: String
    /// The raw PROV agent name ("claude", "pdf2md", "legacy-extraction", …).
    public let agentName: String
    /// The model/tool version (`agents.version`), e.g. "claude-opus-4-…". nil
    /// for local/legacy extractions that record none.
    public let modelVersion: String?
    /// Character count of the resolved body (`version.content.count`).
    public let charCount: Int
    /// `true` when this version is the source's active HEAD (ref→else-MAX).
    public let isActive: Bool

    public var id: PageID { version.id }

    public init(
        version: SourceMarkdownVersion,
        backendDisplayName: String,
        agentName: String,
        modelVersion: String?,
        charCount: Int,
        isActive: Bool
    ) {
        self.version = version
        self.backendDisplayName = backendDisplayName
        self.agentName = agentName
        self.modelVersion = modelVersion
        self.charCount = charCount
        self.isActive = isActive
    }
}

extension ExtractionAlternative {
    /// Resolve the backend display name from a PROV agent name, with a graceful
    /// fallback for legacy/unknown agents. `"legacy-extraction"` → "Legacy";
    /// any other unknown name → the name capitalized.
    public static func backendDisplayName(agentName: String) -> String {
        if let backend = ExtractionBackend.from(agentName: agentName) {
            return backend.displayName
        }
        if agentName == ExtractionBackend.legacyAgentName { return "Legacy" }
        // Capitalize only the first character (predictable for hyphenated names
        // like "future-tool" → "Future-tool"; `.capitalized` would also upper
        // case after the hyphen).
        return agentName.prefix(1).uppercased() + agentName.dropFirst()
    }
}
