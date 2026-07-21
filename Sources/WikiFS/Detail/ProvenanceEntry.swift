import Foundation

/// A display-model projection of a single provenance entry — the shared
/// representation used by ``ProvenancePanel`` to render both page and source
/// history without depending on the concrete `PageOrigin` / `SourceOrigin`
/// types. Both origins convert to this via their `.provenanceEntry` computed
/// property.
///
/// Keeps the provenance UI DRY: the date-first layout, operation badge,
/// agent label, and clickable-row behavior are identical for pages and
/// sources — only the store accessors + origin types differ, and those are
/// resolved by the caller before constructing a `ProvenanceEntry`.
public struct ProvenanceEntry: Sendable, Equatable, Identifiable {
    public let versionID: String
    public let agentName: String
    /// The agent's structured kind (`chat` / `agent` / `human` / `model` /
    /// `software`). Used by the agent label to pick the right icon.
    public let agentKind: String
    public let activityKind: String
    public let plan: String?
    public let externalRef: String?
    /// A human-readable run name resolved from the provenance payload (#745).
    /// For `chat:<id>` agents this is the chat's display title; `nil` for
    /// other agent kinds or when the chat has been deleted.
    public let runTitle: String?
    public let savedAt: Date

    public var id: String { versionID }

    public init(
        versionID: String,
        agentName: String,
        agentKind: String,
        activityKind: String,
        plan: String?,
        externalRef: String?,
        runTitle: String?,
        savedAt: Date
    ) {
        self.versionID = versionID
        self.agentName = agentName
        self.agentKind = agentKind
        self.activityKind = activityKind
        self.plan = plan
        self.externalRef = externalRef
        self.runTitle = runTitle
        self.savedAt = savedAt
    }
}
