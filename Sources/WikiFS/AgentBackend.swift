import Foundation
import WikiFSCore

/// Backend-agnostic agent contract. UI, persistence, and conversation
/// management depend only on this + `AgentEvent` — never a wire format.
///
/// Phase 0 of the agent-backend port (`plans/chat-and-persistence.md`): today's
/// Claude-CLI/stream-json code lives behind `ClaudeCLIBackend`; a future backend
/// (ACP, Polytoken) is a new conforming type. The launcher holds an
/// `AgentBackend` and consumes per-turn `AsyncStream<AgentEvent>` — it never
/// touches a `Process` or a wire format directly.
///
/// **Turn-boundary contract:** every backend impl MUST yield `.messageStop` at
/// each turn end. The launcher keys its generation-gate release, edit-lock
/// release, and transcript flush off `AgentEvent.endsGeneration` (true for
/// `.result` and `.messageStop`). A backend that fails to synthesize
/// `.messageStop` strands the edit lock and the spinner.
public protocol AgentBackend: Sendable {
    /// Start a fresh session. `onExit` fires exactly once when the underlying
    /// process/agent terminates, carrying its exit status — the completion
    /// channel the launcher's watchdog reconciles against (replaces direct
    /// `Process` introspection).
    ///
    /// For a one-shot run the session's per-turn stream carries the single
    /// run's events and finishes at `.result`; the process exits and `onExit`
    /// fires. For an interactive session the process stays alive across turns;
    /// each `send` returns a stream that finishes at `.messageStop`, and
    /// `onExit` fires only at session end.
    func start(
        profile: BackendProfile,
        systemPrompt: String,
        onExit: @escaping @Sendable (Int) -> Void
    ) async throws -> SessionHandle

    /// Send one user turn. Returns the streamed events for THIS turn; the
    /// stream finishes at the turn boundary (`.messageStop` for interactive,
    /// `.result` for a one-shot run's single turn). The session (e.g. the CLI
    /// `Process`) persists across turns via `SessionHandle`.
    func send(_ turn: TurnInput, into session: SessionHandle) async -> AsyncStream<AgentEvent>

    /// Continue a prior session by its opaque id. nil if this backend cannot
    /// resume (id unknown / GC'd / unsupported). Whether the model can change
    /// on resume is a backend capability — see "Model switching" in the port
    /// spec. Phase 0 does NOT implement resume; the default returns nil.
    func resume(
        sessionID: String,
        profile: BackendProfile
    ) async throws -> SessionHandle?

    /// Stop the session and release resources. Idempotent. For an interactive
    /// session this terminates the underlying process; the launcher's
    /// cancellation path (cancelling the `for await` consumer) also bridges
    /// here via the stream's `onTermination`.
    func cancel(_ session: SessionHandle) async
}

/// Abstract per-mode/per-op configuration; each backend interprets it.
///
/// The launcher resolves app-level concerns (scratch dir, sandbox, bundled
/// `wikictl` path, log layout, agent command config) and passes them in here;
/// the backend interprets the rest. For the CLI backend, `cli` carries the
/// `OperationCommand`-building inputs. A future Polytoken/ACP backend ignores
/// `cli` and reads `model`/`providerHints` instead.
public struct BackendProfile: Sendable {
    /// The model alias/name to pass to the agent (backend-interpreted).
    public var model: String?
    /// Backend-specific hints (e.g. provider routing). Opaque to the launcher.
    public var providerHints: [String: String]
    /// The per-run writable scratch directory (cwd for the CLI backend).
    public var scratchDirectory: URL?
    /// Gates Write/Edit tools — read-only interactive sessions pass `false`.
    public var isReadOnly: Bool
    /// CLI-backend-specific context. nil for non-CLI backends. The launcher
    /// populates this for `ClaudeCLIBackend`; other backends ignore it.
    public var cli: CLIProfile?

    public init(
        model: String? = nil,
        providerHints: [String: String] = [:],
        scratchDirectory: URL? = nil,
        isReadOnly: Bool = false,
        cli: CLIProfile? = nil
    ) {
        self.model = model
        self.providerHints = providerHints
        self.scratchDirectory = scratchDirectory
        self.isReadOnly = isReadOnly
        self.cli = cli
    }
}

/// The inputs `ClaudeCLIBackend` needs to assemble an `OperationCommand`.
/// Carried inside `BackendProfile.cli` so the launcher can build the profile
/// without knowing CLI flag details — it just forwards the resolved app-level
/// values; the backend owns `OperationCommand.build`.
public struct CLIProfile: Sendable {
    /// The staged operation (carries its own self-sufficient prompt + agents).
    public var operation: WikiOperation
    /// The wiki's live File Provider mount path (exported as `WIKI_ROOT`).
    public var wikiRoot: String
    /// The active wiki's ULID (exported as `WIKI_DB`).
    public var wikiID: String
    /// The directory holding the embedded `wikictl` binary (prepended to PATH).
    public var wikictlDirectory: String
    /// The PATH-resolved executable path (preflight already done by the launcher).
    public var resolvedExecutable: String
    /// The loaded agent command config (prefix args, model override, extra env).
    public var command: AgentCommandConfig
    /// The resolved seatbelt sandbox invocation, or nil for un-sandboxed.
    public var sandbox: SandboxProfile.SandboxInvocation?
    /// Raw stdout chunk callback (fires on the pipe's background queue). The
    /// launcher uses this to mirror `rawTranscript` and write `run.jsonl`.
    /// nil when raw mirroring is not needed (e.g. no log files opened).
    public var onStdoutChunk: (@Sendable (String) -> Void)?
    /// Raw stderr chunk callback (fires on the pipe's background queue). The
    /// launcher uses this to mirror `stderr`/`rawTranscript` and write
    /// `run.stderr.log`.
    public var onStderrChunk: (@Sendable (String) -> Void)?

    public init(
        operation: WikiOperation,
        wikiRoot: String,
        wikiID: String,
        wikictlDirectory: String,
        resolvedExecutable: String,
        command: AgentCommandConfig,
        sandbox: SandboxProfile.SandboxInvocation? = nil,
        onStdoutChunk: (@Sendable (String) -> Void)? = nil,
        onStderrChunk: (@Sendable (String) -> Void)? = nil
    ) {
        self.operation = operation
        self.wikiRoot = wikiRoot
        self.wikiID = wikiID
        self.wikictlDirectory = wikictlDirectory
        self.resolvedExecutable = resolvedExecutable
        self.command = command
        self.sandbox = sandbox
        self.onStdoutChunk = onStdoutChunk
        self.onStderrChunk = onStderrChunk
    }
}

/// Opaque, backend-neutral session token. Persisted on the chat row as
/// `session_id` (+ `backend_kind`) so a future continue targets the right
/// backend. Does NOT wrap `Process` (which is not Sendable).
public struct SessionHandle: Sendable, Hashable {
    /// Opaque; backend-defined. For the CLI backend this is a UUID mapping to
    /// an internal session record holding the live `Process` + stdin handle.
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

/// One user turn sent into an interactive session.
public struct TurnInput: Sendable {
    public var userText: String

    public init(userText: String) {
        self.userText = userText
    }
}
