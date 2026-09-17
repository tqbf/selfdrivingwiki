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

    /// Process-level shutdown for owners that CACHE a backend across
    /// operations (issue #1276): terminate the underlying subprocess without
    /// needing a session handle. Idempotent, and safe on a backend that never
    /// started. Backend owners MUST call this when retiring a cached backend —
    /// dropping the last reference does NOT terminate any process, and
    /// `cancel(_:)` is session-scoped. `AgentProviderRuntime` calls it during
    /// summarizer snapshot release, AFTER active summary/title leases drain
    /// and BEFORE the backend's scratch directory is removed.
    ///
    /// A protocol REQUIREMENT (not an extension default) on purpose: a new
    /// conformer that forgets the real termination path fails to compile
    /// instead of silently leaking a child process.
    func shutdown() async
}

/// Abstract per-mode/per-op configuration; each backend interprets it.
///
/// The launcher resolves app-level concerns (scratch dir, bundled `wikictl`
/// path, log layout) and passes them in here; `ACPBackend` reads `model`/
/// `providerHints` for routing and `cli`/`runContext` for the spawn
/// environment (`WIKI_DB`/`WIKICTL`/`PATH` are CONVENIENCES exported from
/// `runContext` — adapters may drop them; correctness flows from the absolute
/// paths injected into the operation prompt — see `CLIProfile`).
/// The execution access the application authorizes for an ACP session.
///
/// This is distinct from `PermissionPolicy`: it controls an agent's own
/// advertised session mode, while `PermissionPolicy` records and resolves ACP
/// tool permission requests.
public enum AgentExecutionAccess: Sendable, Equatable {
    /// Keep the ACP agent's default session mode.
    case standard
    /// Request the agent's advertised full-access mode before the first tool call.
    case fullAccess
}

public struct BackendProfile: Sendable {
    /// The model alias/name to pass to the agent (backend-interpreted).
    public var model: String?
    /// Backend-specific hints (e.g. provider routing). Opaque to the launcher.
    public var providerHints: [String: String]
    /// The per-run writable scratch directory (session `cwd`).
    public var scratchDirectory: URL?
    /// Gates Write/Edit tools — read-only interactive sessions pass `false`.
    public var isReadOnly: Bool
    /// The agent-session access level the application authorizes for this run.
    public var executionAccess: AgentExecutionAccess
    /// The env-var context `ACPBackend.start` reads to spawn the agent with
    /// `WIKI_DB`/`WIKICTL` visible. nil for sessions that don't
    /// need them (none today — every launcher call site sets it).
    public var cli: CLIProfile?
    /// The `debug/` folder URL under the scratch dir. When set, `ACPBackend`
    /// captures the complete ACP wire trace (session/new, per-turn
    /// prompt/updates/response, permissions, stderr) as machine-readable JSON
    /// files for post-hoc debugging — the verbose companion to the lightweight
    /// `run.jsonl`. nil = debug logging disabled.
    public var debugLogURL: URL?
    /// The resolved seatbelt confinement for this run (issue #1251). When
    /// non-nil, `ACPBackend.startProcess` wraps the agent spawn with
    /// `sandbox-exec` (writes fenced to the allowed subtree set; the resolved
    /// `pdf2md` script exec/read-denied) and FAILS CLOSED when
    /// `/usr/bin/sandbox-exec` is unusable.
    ///
    /// Every production constructor that can start an LLM child process MUST
    /// state its decision with an explicit non-nil `sandbox:` — a read-only
    /// `LLMSandboxScratch.sandbox` for extraction, summarization, and
    /// provider-model probes (issue #1276), or the launcher-resolved write
    /// invocation for Ingest/Edit/chat. Explicit `sandbox: nil` is reserved
    /// for profiles that never spawn a production LLM process (fake backends,
    /// low-level tests); `LLMSpawnSandboxExhaustivenessTests` audits the
    /// source and fails when a production constructor omits or nils it.
    public var sandbox: SandboxProfile.SandboxInvocation?
    /// The typed per-run capability context (`AgentRunContext`): canonical
    /// scratch, scratch-local temp roots, typed wiki id, trusted absolute
    /// `wikictl` path, and the effective PATH. The launcher sets it on every
    /// operation profile; `ACPBackend` exports its protected environment keys
    /// (over provider hints) and points the session cwd at the canonical
    /// scratch. nil only on legacy/internal profiles that never spawn an
    /// operation agent (e.g. the message summarizer, extraction clients).
    public var runContext: AgentRunContext?
    /// The snapshot-owned package-runner execution-staging directory
    /// (issue #1279) — TRUSTED launch data, deliberately NOT a `providerHints`
    /// entry, so untrusted provider configuration can never select or replace
    /// it. Present ONLY on strict summarizer profiles whose configured command
    /// is JS-adapter-shaped: for an EFFECTIVE `bun x` launch the plan exports
    /// this directory as the child's `TMPDIR` (bun stages + execs adapters
    /// under its temp root; the strict scratch stays W^X). A canonicalization
    /// that declines leaves the lease unused — the plan keeps the scratch
    /// temp — and snapshot teardown removes it. nil everywhere else
    /// (extraction, probes, chat: `<scratch>/.tmp` behavior unchanged).
    public var packageRunnerTempURL: URL?

    public init(
        model: String? = nil,
        providerHints: [String: String] = [:],
        scratchDirectory: URL? = nil,
        isReadOnly: Bool = false,
        executionAccess: AgentExecutionAccess = .standard,
        cli: CLIProfile? = nil,
        debugLogURL: URL? = nil,
        sandbox: SandboxProfile.SandboxInvocation? = nil,
        runContext: AgentRunContext? = nil,
        packageRunnerTempURL: URL? = nil
    ) {
        self.model = model
        self.providerHints = providerHints
        self.scratchDirectory = scratchDirectory
        self.isReadOnly = isReadOnly
        self.executionAccess = executionAccess
        self.cli = cli
        self.debugLogURL = debugLogURL
        self.sandbox = sandbox
        self.runContext = runContext
        self.packageRunnerTempURL = packageRunnerTempURL
    }
}

/// The env-var context `ACPBackend.start` needs when spawning the agent
/// subprocess (mirrors what the deleted CLI backend used to export). Carried
/// inside `BackendProfile.cli`.
public struct CLIProfile: Sendable {
    /// The staged operation (carries its own self-sufficient prompt + agents).
    public var operation: WikiOperation
    /// The wiki's live File Provider mount path (used for the task-prompt path (not exported as an env var by default, #441)).
    public var wikiRoot: String
    /// The active wiki's ULID (exported as `WIKI_DB`).
    public var wikiID: WikiID
    /// The directory holding the embedded `wikictl` binary (prepended to PATH).
    public var wikictlDirectory: String
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
        wikiID: WikiID,
        wikictlDirectory: String,
        onStdoutChunk: (@Sendable (String) -> Void)? = nil,
        onStderrChunk: (@Sendable (String) -> Void)? = nil
    ) {
        self.operation = operation
        self.wikiRoot = wikiRoot
        self.wikiID = wikiID
        self.wikictlDirectory = wikictlDirectory
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
