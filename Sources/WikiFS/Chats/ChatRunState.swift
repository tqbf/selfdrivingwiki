/// The daemon's run lifecycle for a single chat session, modeled as an
/// explicit state machine. Replaces the five independent boolean flags
/// (`isRunning`, `isGenerating`, `isAwaitingGenerationSlot`,
/// `isInteractiveSession`, `activeChatID`) that previously represented
/// this as a denormalized enum — and could represent impossible
/// combinations (e.g. "not live but running", the `markNotLive` bug).
///
/// The flags are hierarchical: the daemon never reports `isGenerating`
/// without `isRunning` (a session must be active to stream), so they map
/// cleanly to exclusive states via the `from(...)` factory.
public enum ChatRunState: Sendable, Equatable {
    /// No active run. The session is idle or the daemon has no live session.
    case idle
    /// The daemon reported `isAwaitingGenerationSlot` — a turn is queued
    /// waiting for the concurrency gate.
    case queued
    /// The agent is processing (`isRunning` true, not yet streaming).
    case thinking
    /// The agent is streaming tokens (`isGenerating` true; implies running).
    case generating

    /// Map from the daemon's flat boolean DTO to the most-specific state.
    /// `isGenerating` wins over `isRunning` (generating implies running),
    /// and `isRunning` wins over `isAwaitingGenerationSlot`.
    public static func from(
        isRunning: Bool, isGenerating: Bool, isAwaitingSlot: Bool
    ) -> ChatRunState {
        if isGenerating    { return .generating }
        if isRunning       { return .thinking }
        if isAwaitingSlot  { return .queued }
        return .idle
    }

    /// True while the daemon is actively working on this session
    /// (thinking or generating). Backs `isInteractiveSession` and
    /// `activeChatID != nil`.
    public var isActive: Bool { self == .thinking || self == .generating }
}
