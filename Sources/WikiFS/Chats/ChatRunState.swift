/// The daemon's run lifecycle for a single chat session, modeled as an
/// explicit state machine. Replaces the five independent boolean flags
/// (`isRunning`, `isGenerating`, `isAwaitingGenerationSlot`,
/// `isInteractiveSession`, `activeChatID`) that previously represented
/// this as a denormalized enum — and could represent impossible
/// combinations (e.g. "not live but running", the `markNotLive` bug).
///
/// ## Why the cases are what they are
///
/// The daemon's flags carry meanings that are easy to misread, and the first
/// version of this enum misread two of them:
///
/// * `isGenerating` is **not** "streaming tokens". `AgentLauncher.setGenerating(true)`
///   fires at *turn start* (`sendInteractiveMessage: turn start`), so it covers
///   the whole turn — thinking and streaming alike. It is the flag
///   `AgentLauncher` documents as the one "every UI spinner / Stop affordance
///   keys off".
/// * `isRunning` is **not** "a turn is in flight". For an interactive chat it
///   means the agent *process* is alive **across turns** (`AgentLauncher`:
///   "SPAWN COMMIT: process is alive. isRunning = true (process alive across
///   turns)"), so it stays true while the session sits idle between messages.
///
/// The previous mapping therefore lost information twice. It defined
/// `.thinking` as `isRunning && !isGenerating` — a combination that for an
/// interactive session *only ever* means "warm, between turns", never thinking
/// — and that misnomer is what led the sidebar to badge a warm session as
/// "responding…" for the rest of its life. It also tested `isRunning` **before**
/// `isAwaitingSlot`, so a turn queued on the generation gate (which has both
/// flags set) was reported as `.thinking` and `isAwaitingGenerationSlot` read
/// false exactly when it was true.
public enum ChatRunState: Sendable, Equatable {
    /// No live session on the daemon. The chat renders from persisted rows.
    case idle
    /// A turn has been submitted and is waiting for the shared concurrency
    /// gate (another session is answering). The session is live.
    case queued
    /// The session is alive with **no turn in flight** — the state a chat sits
    /// in between messages, holding its warm agent process. Live (its
    /// transcript is the mirror's), but emphatically *not* answering.
    case warm
    /// A turn is in flight: the agent is working on a reply, whether or not
    /// tokens have started arriving. This is the only state that means
    /// "responding…".
    case answering

    /// Map from the daemon's flat boolean DTO to the most-specific state.
    ///
    /// Precedence matters and is the reverse of the obvious reading: the
    /// *narrowest* claim wins. `isGenerating` (a turn is in flight) beats
    /// `isAwaitingSlot` (a turn is queued) beats `isRunning` (the process is
    /// merely alive), because each earlier flag implies the later ones.
    public static func from(
        isRunning: Bool, isGenerating: Bool, isAwaitingSlot: Bool
    ) -> ChatRunState {
        if isGenerating   { return .answering }
        if isAwaitingSlot { return .queued }
        if isRunning      { return .warm }
        return .idle
    }

    /// True while the daemon holds a session for this chat — so the chat
    /// surface should render the streaming mirror (`RemoteChatSession.displayTranscript`)
    /// rather than the persisted rows. Backs `isInteractiveSession` and
    /// `activeChatID != nil`.
    ///
    /// Deliberately *not* the same question as `isAnswering`: a warm session
    /// between turns is live (its transcript is authoritative) while nothing
    /// is running. Conflating the two is the bug this enum exists to prevent.
    public var isLive: Bool { self != .idle }

    /// True while a turn is actually in flight. **Every** spinner, "responding…"
    /// badge, and Stop affordance keys off this — never off `isLive`.
    public var isAnswering: Bool { self == .answering }
}
