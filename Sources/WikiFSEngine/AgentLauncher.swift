import Foundation
import Observation
import WikiFSCore
import ACPModel

/// Runs the three ACP agent operations — Ingest / Query / Lint — against the
/// currently-selected wiki, streaming a live activity feed back into the app
/// (`plans/llm-wiki.md` Phase C). Generalizes the v0 agent launcher: instead of a
/// free-form shell command, it spawns a scoped ACP agent invocation built by the
/// pure `OperationCommand.build(...)` seam, now with `--output-format stream-json`
/// so the run is visible as it happens instead of silent until the final result.
///
/// Allowed because the app is **un-sandboxed** (`WikiFS/WikiFS.entitlements` — no
/// `com.apple.security.app-sandbox`); a sandboxed app could not `Process`-spawn.
///
/// `@MainActor @Observable`: the view binds `events`, `isRunning`, `exitStatus`,
/// `preflightError`, and `logFileURL`. State is mutated on the main actor from the
/// pipe `readabilityHandler`s — we NEVER block on `waitUntilExit`; completion
/// arrives via `terminationHandler`, which is also where the per-wiki
/// agent-run lifecycle ref-count is decremented.
@MainActor
@Observable
public final class AgentLauncher {
    /// The live, ordered activity feed for the current/last run: typed events parsed
    /// from the stream-json NDJSON. The UI renders these as tool-call rows, prose,
    /// and a final result. Appended on the main actor as lines arrive.
    ///
    /// Exposed without `private(set)` so tests can simulate "a transcript is
    /// visible" via `@testable import WikiFS`, without requiring a real spawned
    /// process.
    public var events: [AgentEvent] = []
    /// Wall-clock timestamps parallel to `events` — when each row was first
    /// appended (for streamed rows, the first delta's arrival; replaced rows
    /// update to the finalization time). Used to render the "Worked for Xs"
    /// footer under assistant responses (issue #285). `nil`-safe: callers that
    /// don't need timing ignore this array.
    public private(set) var eventTimestamps: [Date] = []

    /// Per-event callback set by the queue ingestion provider before calling
    /// `launcher.run(...)`. Fires once per typed agent event that is appended
    /// to `events` via `mergeOrAppend`, so the queue's Activity tracker can
    /// build a per-item transcript for the Activity window — decoupled from
    /// the launcher instance (which may be in a different wiki window).
    /// `nil` for interactive chat paths (the chat transcript is rendered
    /// inline via `events`). Cleared in `finish()`.
    @ObservationIgnored public var onAgentEvent: (@Sendable (AgentEvent) -> Void)?
    /// Per-run callback invoked on each `usage_update` notification during a
    /// run (#544 live progress). Receives the in-progress `SessionUsage`
    /// snapshot (cumulative token totals + context window + cost + model id
    /// at the moment of the update). Installed in `run(...)` after
    /// `resetRunArtifacts()` — same lifecycle as `onAgentEvent`. The provider
    /// runs the agent off-main; this callback hops to the main actor in
    /// `AppQueueIngestionProvider` before emitting to the queue. Cleared in
    /// `finish()` and `resetRunArtifacts()`.
    ///
    /// Note: the backend's `sessionUsage(for:)` does NOT set `providerLabel`
    /// (the configured provider name like "Claude"). The launcher enriches
    /// each snapshot with `liveUsageProviderLabel` before invoking this.
    @ObservationIgnored public var onLiveUsage: (@Sendable (SessionUsage) -> Void)?
    /// The configured provider label for the current run, attached to each
    /// live-usage snapshot so the Activity window can show "Claude · Sonnet 4".
    /// Set in `run(...)` from the resolved provider; cleared in `finish()` and
    /// `resetRunArtifacts()`. Nil for runs without ACP backend usage data.
    @ObservationIgnored private var liveUsageProviderLabel: String?

    /// #608: per-run callback invoked whenever the launcher surfaces or clears
    /// a pending always-ask permission request. Receives the first pending
    /// `PendingPermission` (ACP agents gate one write at a time, so there is
    /// at most one) or `nil` when the prior request resolved (approve/reject)
    /// or auto-rejected via the S1 timer. Mirrors `onAgentEvent` / `onLiveUsage`
    /// lifecycle: installed in `run(...)` AFTER `resetRunArtifacts()` and
    /// cleared in `finish()` and `resetRunArtifacts()` so a stale callback
    /// from a prior run can't receive a new run's permission updates. Fired
    /// from `refreshPendingPermissions()` whenever the snapshot actually
    /// changes — the existing `pendingPollTask` already polls at 150ms while a
    /// request is pending (300ms idle), so this just adds the Activity window
    /// as a second consumer of the same poll (the first is `ChatView`).
    @ObservationIgnored public var onPendingPermission: (@Sendable (PendingPermission?) -> Void)?

    /// Receives the per-turn token/cost delta for an interactive (Ask/Edit)
    /// chat session. The app layer installs this so the menu bar's "Today:
    /// X tokens" daily total includes interactive chat, not just queue-based
    /// ingest/lint runs. The delta is computed against the last snapshot read
    /// for THIS session (the backend reports cumulative session totals), so
    /// accumulating into `DailyUsage.add` doesn't double-count across turns.
    /// `nil` (no-op) when the app hasn't wired it — interactive usage is
    /// simply untracked. Set/cleared in `resetRunArtifacts()` / `finish()`.
    @ObservationIgnored public var onInteractiveUsage: (@MainActor (SessionUsage) -> Void)?
    /// The raw combined transcript (raw stream-json stdout + stderr) kept alongside
    /// the typed `events`, so the UI / a debugger can see exactly what the CLI
    /// emitted. This is the in-memory mirror of the on-disk `run.jsonl`.
    ///
    /// Exposed without `private(set)` so tests can simulate pre-existing transcript
    /// state via `@testable import WikiFS`.
    var rawTranscript = ""
    /// stderr captured separately (claude's diagnostics): a failed start, a flag
    /// error, an auth prompt. Surfaced prominently in the UI rather than swallowed.
    ///
    /// Exposed without `private(set)` so tests can simulate pre-existing stderr
    /// state via `@testable import WikiFS`.
    public var stderr = ""
    /// The ingested-file ids whose **agent run** is in flight — set only once the
    /// claude spawn is actually committed (around `onLock`), and cleared in
    /// `finish()`. Drives the per-file "Ingesting…" row label and the cross-file
    /// `isAnySourceIngesting` Ingest-button greyout.
    public var ingestingSourceIDs: Set<PageID> = []
    /// The in-flight ingest operation Task (set by `IngestSheetView`). Cancelling
    /// it aborts a running `pdf2md` conversion (via its task-cancellation handler).
    /// Held here so `stop()` can cancel the conversion phase, not just the agent
    /// process. Self-clears when done.
    /// True while a spawned agent process is alive (one-shot runs: from spawn
    /// to finish; interactive sessions: from spawn to session end, across all turns).
    /// Set at spawn commit in `run()` and `startInteractiveQuery()`; cleared in
    /// `finish()`. This is NOT coupled to the generation gate — the gate serializes
    /// ACTIVE GENERATION (a turn in flight), not process lifetime. An interactive
    /// session's process is alive between turns without holding the gate.
    ///
    /// Exposed without `private(set)` so tests can simulate "process alive" state
    /// via `@testable import WikiFS`, without requiring a real spawned process.
    public var isRunning = false
    /// True only while the agent is actively producing output. For one-shot runs
    /// (ingest/lint/query) this mirrors `isRunning` for the run's duration. For an
    /// interactive query session it tracks the *current turn*: set when a message is
    /// sent, cleared when the terminal `.result` or `.messageStop` event arrives —
    /// so an open-but-idle session does not show a perpetual spinner. Every UI
    /// spinner / Stop affordance keys off this rather than the raw `isRunning`.
    public private(set) var isGenerating = false
    /// True while an interactive session is queued waiting to acquire the shared
    /// generation gate (another launcher is currently generating). Cleared when the
    /// slot is acquired, when the wait is cancelled, or when the session ends.
    /// Published so the UI can show a "Waiting for the other session to finish…"
    /// hint and keep `canSend` false — the message is NOT silently dropped.
    public private(set) var isAwaitingGenerationSlot = false
    /// Exit status of the last finished process, or nil if none finished / one is
    /// running.
    ///
    /// Exposed without `private(set)` so tests can simulate pre-existing exit
    /// status via `@testable import WikiFS`.
    public var exitStatus: Int32?
    /// Set when the PATH preflight fails (claude not resolvable) or the spawn
    /// itself throws; shown in the UI instead of spawning. Cleared on the next
    /// successful run. Settable from `AgentOperationRunner` for silent-failure
    /// paths where no agent process is spawned.
    public var preflightError: String?
    /// The kind of the operation currently running (drives the UI title / spinner).
    ///
    /// Exposed without `private(set)` so tests can simulate "a non-query run is
    /// active" (e.g. `.ingest`) via `@testable import WikiFS`, without requiring a
    /// real spawned process.
    public var runningKind: WikiOperation.Kind?
    /// The per-run `run.jsonl` backend log on disk (raw JSON-RPC notifications
    /// in the ACP path; was raw stream-json in the old CLI path). Its sibling
    /// `run.stderr.log` holds the agent's stderr. The UI offers a "Reveal Log"
    /// affordance via `logFileURL`.
    public private(set) var logFileURL: URL?
    /// The per-run `debug/` folder URL (verbose, complete ACP wire trace).
    /// The companion to `logFileURL`: where `logFileURL` is the lightweight
    /// `run.jsonl`, `debugFolderURL` is the full `session/new` +
    /// per-turn `turn-N-prompt.json` / `turn-N-updates.jsonl` /
    /// `turn-N-response.json` + `permissions.jsonl` + `stderr.log` +
    /// `summary.json` folder a user can zip and share for debugging. nil
    /// when no run has started or the folder couldn't be created. Survives
    /// `finish()` so the UI can reveal it after the run completes.
    public private(set) var debugFolderURL: URL?
    /// The wall-clock start time of the current/last run, captured at spawn
    /// commit so `summary.json`'s duration is accurate even if `runStartedAt`
    /// (set inside `setGenerating(true)`) is reset.nil when no run has started.
    private var runCommitedAt: Date?
    /// The provider label/id for the current/last run — captured at spawn commit
    /// so `finish()` can write it to `summary.json`. nil when no run has started.
    private var runProviderLabel: String?
    /// The model id the current/last run's session used — captured after
    /// `backend.start` (from the ACP session's advertised models) so `finish()`
    /// can write it to `summary.json`. nil when not yet resolved.
    private var runModelId: String?
    /// Wall-clock start time for the current/last run. Used by the UI to show a
    /// heartbeat instead of a context-free spinner.
    public private(set) var runStartedAt: Date?
    /// Last time stdout/stderr produced bytes, or the run state changed. A live
    /// process with an old `lastActivityAt` is not necessarily dead, but the UI can
    /// name that it is quiet.
    public private(set) var lastActivityAt: Date?
    /// The current ingestion phase ("planner", "executor[filename]", "finalizer"),
    /// or nil when not ingesting or between phases. Surfaced so the UI and the
    /// heartbeat watchdog can name *what* is running when page creation takes a
    /// long time — beyond a context-free spinner.
    public private(set) var currentIngestPhase: String?
    /// The spawned process ID while running, useful context when a run looks quiet.
    public private(set) var currentProcessID: Int32?

    /// Builds the login-shell PATH-resolved `claude` path. Injected so tests can
    /// stub it; the app uses the real login-shell preflight.
    @ObservationIgnored var resolveClaude: () -> PathPreflight.Result = {
        PathPreflight.resolveOnLoginShell(executable: "claude")
    }

    /// The App Group container directory the provider config is loaded from.
    /// When nil (the default), resolved via
    /// `DatabaseLocation.appGroupContainerDirectory()` at spawn time. Injected
    /// for tests; existing `AgentLauncher()` call sites are unchanged.
    var containerDirectory: URL? = nil

    /// The agent backend. Constructed PER-SESSION at spawn time from the
    /// selected provider's permission policy, via `AgentBackendFactory`. The app
    /// is ACP-only, so this is always an `ACPBackend`. Injectable so tests can
    /// substitute a stub backend.
    @ObservationIgnored var backend: AgentBackend = ACPBackend()

    /// Factory closure that constructs the backend for a session. Called at
    /// spawn time in `run()` / `startInteractiveQuery()` so a fresh backend is
    /// built per session with the current permission policy + the operation's
    /// auto-reject budget (#606). Injectable so tests can substitute a stub
    /// backend that survives the `self.backend = ...` assignment in `run()`
    /// (setting `backend` directly is overwritten).
    ///
    /// #606: second parameter is the deferred-permission budget — nil = no
    /// timer (interactive chat), non-nil = auto-reject after this `Duration`.
    /// Ingest/lint pass `.seconds(60)`; chat passes `nil`.
    ///
    /// #609: third parameter is the turn ceiling — `TurnLivenessPolicy.ceiling(for:)`
    /// decides per kind: `.chat` → 1800s (interactive default), `.ingest`/`.lint`
    /// → 600s (unattended pipelines must not burn 30 minutes on a stall).
    @ObservationIgnored var resolveBackend: (PermissionPolicy, Duration?, TimeInterval) -> AgentBackend = {
        AgentBackendFactory.makeBackend(policy: $0, budget: $1, turnCeilingTimeout: $2)
    }

    /// The permission policy, resolved per operation kind. #607: previously one
    /// shared `agentPermissionMode` key was fed to chat + ingest + lint, so a
    /// user who correctly chose `alwaysAsk` for interactive chat got the same
    /// gating applied to an unattended ingest/lint — guaranteeing a stall on
    /// the first prompt needing a permission. Now three independent keys:
    /// `chatPermissionMode` / `ingestPermissionMode` / `lintPermissionMode`.
    /// Extraction is intentionally NOT a kind here — see `plans/acp-permissions.md`
    /// §5.1 (extraction keeps its `.bypass` default on `ACPExtractionClient`).
    @ObservationIgnored var resolvePermissionMode: (PermissionOperationKind) -> PermissionPolicy = { op in
        let key: String
        let fallback: PermissionPolicy
        switch op {
        case .chat:   key = PermissionModeKey.chat;   fallback = .bypass
        case .ingest: key = PermissionModeKey.ingest; fallback = .bypass
        case .lint:   key = PermissionModeKey.lint;   fallback = .bypass
        }
        let raw = UserDefaults.standard.string(forKey: key) ?? ""
        return PermissionPolicy(rawValue: raw) ?? fallback
    }

    /// The Keychain-backed store for the ACP agent's API key. Injectable so
    /// tests can substitute an in-memory store. The key NEVER touches
    /// UserDefaults or a plaintext file.
    @ObservationIgnored var acpCredentialStore: any ACPCredentialStore = KeychainACPCredentialStore()

    /// Provider selection (#324): resolves the configured providers from
    /// `agent-providers.json` (App Group container) and returns the provider the
    /// launcher should use this session. Read fresh at spawn time so Settings
    /// changes apply on the next session. Injectable for tests.
    @ObservationIgnored var resolveSelectedProvider: () -> AgentProvider = {
        let dir = (try? DatabaseLocation.appGroupContainerDirectory())
            ?? FileManager.default.temporaryDirectory
        return AgentProvidersConfig.loadOrSeed(from: dir).selectedProvider()
    }

    /// The resolved App Group container directory the provider config is loaded
    /// from + saved to. Same resolution `resolveSelectedProvider` uses: the
    /// injected `containerDirectory` if set, else `DatabaseLocation`'s App
    /// Group container at call time, else the temp directory (tests). Kept as a
    /// function (not a stored URL) so a Settings change to the container path
    /// takes effect without a restart, mirroring `resolveSelectedProvider`.
    @ObservationIgnored var resolveProvidersContainerDirectory: () -> URL = {
        (try? DatabaseLocation.appGroupContainerDirectory())
            ?? FileManager.default.temporaryDirectory
    }

    /// Resolve the bundled `pdf2md` script path to deny in the agent seatbelt,
    /// or nil if no script is resolvable. Injected because `PdfExtractionService`
    /// (which probes `Bundle.main`) lives in the app target. The app passes a
    /// closure delegating to `PdfExtractionService.resolveScript()` at wiring
    /// time; tests/the daemon default to nil (no deny rule emitted).
    @ObservationIgnored public var pdf2mdScriptPathResolver: () -> String? = { nil }

    /// Returns the chat's most-recent run's debug-folder URL by resolving from
    /// disk: `<Caches>/Self Driving Wiki-agent/<chatULID>/runs/<latest>/debug/`.
    /// Pure — no in-memory state — so the path resolves correctly across app
    /// restarts. Previously a chatID→folder map was kept in memory and cleared
    /// on relaunch, leaving chats with no way to find their on-disk debug logs
    /// after a restart. Run timestamps are RFC 3339 (UTC, milliseconds), so
    /// lexicographic sort = chronological order — "latest" is `max(runNames)`.
    /// Returns nil when the chat has never run here, or its `runs/` directory
    /// is empty / missing. Mirrors `QueueActivityTracker.debugURL(for:)`.
    public func debugFolderURL(forChat id: String) -> URL? {
        guard let latest = Self.latestRunDirectory(for: id) else { return nil }
        return latest.appendingPathComponent("debug", isDirectory: true)
    }

    /// Returns the chat's most-recent run's `run.jsonl` log file by resolving
    /// from disk: `<Caches>/Self Driving Wiki-agent/<chatULID>/runs/<latest>/run.jsonl`.
    /// Pure — companion to `debugFolderURL(forChat:)`.
    public func logFileURL(forChat id: String) -> URL? {
        guard let latest = Self.latestRunDirectory(for: id) else { return nil }
        return latest.appendingPathComponent("run.jsonl", isDirectory: false)
    }

    /// Resolve `<Caches>/Self Driving Wiki-agent/<chatULID>/runs/`. Returns nil
    /// only if the Caches directory itself can't be resolved (very rare). The
    /// `runs/` subdirectory may or may not exist on disk yet — callers handle
    /// the not-yet-spawned case via `contentsOfDirectory` returning nil.
    private static func chatRunsDirectory(for chatID: String) -> URL? {
        guard let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base
            .appendingPathComponent("Self Driving Wiki-agent", isDirectory: true)
            .appendingPathComponent(chatID, isDirectory: true)
            .appendingPathComponent("runs", isDirectory: true)
    }

    /// Resolve the most-recent timestamped run subfolder under
    /// `<chatULID>/runs/`, or nil if no runs exist. RFC 3339 timestamps sort
    /// lexicographically, so "latest" is `max(runNames)`. `try?` is correct
    /// here — a non-existent `runs/` directory simply means the chat has never
    /// run, which is the nil case the callers already handle.
    private static func latestRunDirectory(for chatID: String) -> URL? {
        guard let runsDir = chatRunsDirectory(for: chatID),
              let runNames = try? FileManager.default.contentsOfDirectory(atPath: runsDir.path),
              !runNames.isEmpty else {
            return nil
        }
        let latest = runNames.sorted().last!
        return runsDir.appendingPathComponent(latest, isDirectory: true)
    }

    /// Read the persisted provider config (loads + seeds on first run). The
    /// composer's provider selector binds to this for the providers list + the
    /// current default. Refreshed on demand (not @Observable state) so a fresh
    /// selection — from Settings OR the composer — is visible next read.
    /// `@MainActor` to match the rest of the launcher's observable surface.
    public func providersConfig() -> AgentProvidersConfig {
        AgentProvidersConfig.loadOrSeed(from: resolveProvidersContainerDirectory())
    }

    /// Set + persist the default provider, then return the new config so the
    /// caller (the composer selector) can update its bound state in one step.
    /// Enforces the single-default invariant via `settingDefault(id:)`. The
    /// next `resolveSelectedProvider()` call reads this, so the next chat
    /// session uses the chosen provider with no launcher change.
    @discardableResult
    public func setDefaultProvider(id: String) -> AgentProvidersConfig {
        let dir = resolveProvidersContainerDirectory()
        let updated = providersConfig().settingDefault(id: id)
        do {
            try updated.save(to: dir)
        } catch {
            // #475/#492: persisting the default-provider choice is a mutation;
            // swallowing the throw silently reverts the choice on next launch.
            DebugLog.store("AgentLauncher.setDefaultProvider save failed (provider=\(id)): \(error)")
        }
        return updated
    }

    // MARK: - Per-provider model cache + selection (#329)

    /// Persist `models` (captured from the agent's `session/new`) as provider
    /// `providerId`'s cached model list. Secrets-free. Called by
    /// `startInteractiveQuery` / `run` right after `backend.start` succeeds so
    /// the model picker has the agent's advertised list on the next read.
    /// `@MainActor`; no return — the picker reads the cache next load.
    public func cacheDiscoveredModels(_ models: [CachedModelInfo], forProvider providerId: String) {
        guard !models.isEmpty else { return }
        let dir = resolveProvidersContainerDirectory()
        let updated = providersConfig().settingCachedModels(models, forProvider: providerId)
        DebugLog.store("cacheDiscoveredModels: provider=\(providerId) count=\(models.count) → save")
        do {
            try updated.save(to: dir)
        } catch {
            // #475/#492: the cached model list silently disappears on next launch
            // if this write throws; log so it's visible in Console.app.
            DebugLog.store("AgentLauncher.cacheDiscoveredModels save failed (provider=\(providerId)): \(error)")
        }
    }

    /// Set + persist the user's model selection for `providerId`, then return
    /// the new config so the composer picker can update its bound state. A
    /// nil/empty `modelId` clears the selection ("use the agent's default").
    @discardableResult
    public func setSelectedModel(_ modelId: String?, forProvider providerId: String) -> AgentProvidersConfig {
        let dir = resolveProvidersContainerDirectory()
        let updated = providersConfig().settingSelectedModel(modelId, forProvider: providerId)
        DebugLog.store("setSelectedModel: provider=\(providerId) modelId=\(modelId ?? "nil") → save")
        do {
            try updated.save(to: dir)
        } catch {
            // #475/#492: the user's model selection silently reverts on next
            // launch if this write throws; log so it's visible in Console.app.
            DebugLog.store("AgentLauncher.setSelectedModel save failed (provider=\(providerId) modelId=\(modelId ?? "nil")): \(error)")
        }
        return updated
    }

    // MARK: - Per-operation provider assignment (per-op-provider)

    /// Atomically set the default provider AND a per-provider model selection
    /// in ONE load→mutate→save cycle (no race between two separate writes).
    /// This is the composer's "pick a model" path: choosing a model implies
    /// choosing its provider (paseo's two-step), and both must land together.
    /// Returns the post-write config for the selector's bound state.
    @discardableResult
    public func setSelectedModelAndDefault(
        _ modelId: String?, provider: AgentProvider
    ) -> AgentProvidersConfig {
        let dir = resolveProvidersContainerDirectory()
        DebugLog.store("setSelectedModelAndDefault: provider=\(provider.id) modelId=\(modelId ?? "nil") → save")
        let updated = providersConfig()
            .settingDefault(id: provider.id)
            .settingSelectedModel(modelId, forProvider: provider.id)
        do {
            try updated.save(to: dir)
        } catch {
            // #475/#492: provider+model selection must land together; swallowing
            // the throw silently reverts both on next launch.
            DebugLog.store("AgentLauncher.setSelectedModelAndDefault save failed (provider=\(provider.id) modelId=\(modelId ?? "nil")): \(error)")
        }
        return updated
    }

    /// The user's persisted model selection for `providerId` (nil = "use the
    /// agent's default"). Read at spawn time so `ACPBackend.start` can call
    /// `session/set_model`. PURE-ish (one config load); `@MainActor`.
    public func selectedModelId(forProvider providerId: String) -> String? {
        providersConfig().selectedModelId(forProvider: providerId)
    }

    /// Toggle + persist a model's favorite state for `providerId`, then return
    /// the new config so the composer picker can update its bound state. A
    /// display-only preference (favorites sort to the top of the picker); no
    /// effect on which model actually launches.
    @discardableResult
    public func toggleFavoriteModel(_ modelId: String, forProvider providerId: String) -> AgentProvidersConfig {
        let dir = resolveProvidersContainerDirectory()
        let updated = providersConfig().togglingFavoriteModel(modelId, forProvider: providerId)
        do {
            try updated.save(to: dir)
        } catch {
            // #475/#492: the favorite toggle silently reverts if this write
            // throws; log so it's visible in Console.app.
            DebugLog.store("AgentLauncher.toggleFavoriteModel save failed (provider=\(providerId) model=\(modelId)): \(error)")
        }
        return updated
    }

    /// After a successful `backend.start`, if it was an ACP backend, read the
    /// models it advertised and cache them per-provider for the picker. Cheap
    /// (one actor hop + one secrets-free file write) and non-blocking: runs as
    /// a detached `@MainActor` Task so it never delays the first turn.
    public func captureAndCacheModels(provider: AgentProvider, session: SessionHandle) {
        guard let acp = backend as? ACPBackend else {
            DebugLog.agent("captureAndCacheModels: skip (provider=\(provider.id) backend not ACP)")
            return
        }
        DebugLog.agent("captureAndCacheModels: enter provider=\(provider.id) session=\(session.id)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let models = await acp.availableModels(for: session)
            guard !models.isEmpty else {
                DebugLog.agent("captureAndCacheModels: no models discovered for provider=\(provider.id)")
                return
            }
            let cached = models.map {
                CachedModelInfo(modelId: $0.modelId, name: $0.name, description: $0.description)
            }
            DebugLog.agent("captureAndCacheModels: captured \(cached.count) model(s) for provider=\(provider.id) ids=\(cached.map(\.modelId))")
            self.cacheDiscoveredModels(cached, forProvider: provider.id)
        }
    }

    /// After a successful `backend.start`, if it was an ACP backend, read the
    /// process identifier and assign `currentProcessID` (SDK fork Fix 4). Lets
    /// the watchdog `kill(pgid)` a stuck agent after cancel fails. Non-blocking:
    /// runs as a detached `@MainActor` Task.
    public func captureProcessID(session: SessionHandle) {
        guard let acp = backend as? ACPBackend else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let pid = await acp.processIdentifier(for: session)
            if let pid {
                self.currentProcessID = pid
                DebugLog.agent("captureProcessID: pid=\(pid)")
            }
        }
    }

    /// #566: After a successful `backend.start`, mirror the agent-advertised
    /// config options into `thinkingOption` so the chat toolbar can render a
    /// "Thinking" dropdown. Non-blocking: runs as a detached `@MainActor` Task.
    /// Sets `thinkingOption` to `nil` when the agent advertises no
    /// `thought_level` select (capability detection → the toolbar hides the
    /// affordance). Mirrors `captureAndCacheModels` / `captureProcessID`.
    public func captureThinkingOption(session: SessionHandle) {
        guard let acp = backend as? ACPBackend else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let options = await acp.sessionConfigOptions(for: session)
            self.thinkingOption = ThinkingEffortOption.from(configOptions: options)
        }
    }

    /// #566: Set the `thought_level` config option on the live ACP session.
    /// Called by the chat toolbar's "Thinking" dropdown. No-op when no session
    /// is live or the backend isn't ACP. Errors are logged (not surfaced) —
    /// the dropdown optimistically flips and a `config_option_update` confirms
    /// or reverts; surfacing a modal on every error is heavier than warranted.
    public func setThinkingEffort(_ value: String) {
        guard let acp = backend as? ACPBackend,
              let handle = sessionHandle,
              let option = thinkingOption else { return }
        DebugLog.agent("setThinkingEffort: value=\(value) configId=\(option.configId)")
        // Optimistic local flip — the backend also patches its snapshot, but
        // updating here keeps the dropdown snappy before the actor hop returns.
        thinkingOption = option.withCurrentValue(value)
        Task { @MainActor [weak self] in
            do {
                try await acp.setConfigOption(
                    sessionHandle: handle,
                    configId: option.configId,
                    value: value)
            } catch {
                DebugLog.agent("setThinkingEffort: failed value=\(value) \(error.localizedDescription)")
                // Revert the optimistic flip on failure.
                self?.thinkingOption = option
            }
        }
    }

    /// The currently-pending write-permission requests surfaced from the backend
    /// (always-ask mode). When non-empty AND this surface is the live chat, the
    /// UI renders an inline Approve/Reject affordance (slice 2). Mirrors how
    /// streamed `AgentEvent`s flow: `ACPBackend` → launcher refresh → `@Observable`
    /// state → `ChatView`. Refreshed by `pendingPollTask` while a turn generates.
    /// Empty for the CLI backend (no permission channel) and while idle.
    public var pendingPermissions: [PendingPermission] = []

    /// #566: the live thinking-effort config option for the current ACP
    /// session, mirrored from `ACPBackend.sessionConfigOptions(for:)`. The
    /// chat toolbar's "Thinking" dropdown binds to this — it's `nil` when no
    /// session is live OR the agent doesn't advertise a `thought_level`
    /// option (capability detection: only show UI when present). Refreshed
    /// after `backend.start` and (future) on `config_option_update`.
    public var thinkingOption: ThinkingEffortOption?

    /// Backstop poller that refreshes `pendingPermissions` from the backend while
    /// a turn is generating (always-ask blocks the turn until resolved, so no
    /// `AgentEvent`s flow while a request is pending — the poller is the only
    /// channel that surfaces it). Armed in `setGenerating(true)`, disarmed in
    /// `setGenerating(false)` / `finish()` / `resetRunArtifacts()`.
    @ObservationIgnored private var pendingPollTask: Task<Void, Never>?

    /// #607: per-operation permission-mode UserDefaults keys. Replaces the single
    /// shared `permissionModeKey = "agentPermissionMode"` that fed chat + ingest +
    /// lint from one store — a user who chose `alwaysAsk` for chat got the same
    /// gating applied to an unattended ingest/lint, guaranteeing a stall on the
    /// first prompt needing a permission. These are UserDefaults string keys; the
    /// `@AppStorage(PermissionModeKey.<x>)` bindings in Settings + ChatView + the
    /// `resolvePermissionMode(for:)` closure here all read/write them.
    ///
    /// Extraction is intentionally NOT a kind in this PR — see `plans/acp-permissions.md`
    /// §5.1 (extraction keeps its `.bypass` default on `ACPExtractionClient`).
    public enum PermissionModeKey {
        /// Interactive chat permission mode. Default `.bypass`.
        public static let chat = "chatPermissionMode"
        /// Multi-phase ingest permission mode (planner + executors + finalizer).
        /// Default `.bypass` — the sandbox already confines writes; an unattended
        /// pipeline can't use `alwaysAsk` productively.
        public static let ingest = "ingestPermissionMode"
        /// Lint permission mode (the `run()` single-session path for `.lint` /
        /// `.lintPage`). Default `.bypass` — same unattended-pipeline rationale.
        public static let lint = "lintPermissionMode"
    }
    /// The active session handle (nil when no session is live). Replaces the
    /// old `process: Process?` — the launcher never touches a `Process` directly.
    @ObservationIgnored private var sessionHandle: SessionHandle?

    /// Cumulative token/cost usage across ALL ACP phases in the current run
    /// (#528 spike). Accumulated from each phase's `sessionUsage(for:)` before
    /// the phase session is closed (since `closeSession` removes the usage
    /// state). Read by `AppQueueIngestionProvider` after `run(...)` returns.
    /// nil when no usage has been captured (non-ACP backend or empty run).
    @ObservationIgnored private(set) public var runTotalUsage: SessionUsage?

    /// The cumulative usage snapshot last emitted for the interactive
    /// session, used to compute the per-turn delta. The backend's
    /// `sessionUsage(for:)` returns cumulative session totals (tokens across
    /// all turns); emitting those after each turn would double-count when
    /// accumulated by `DailyUsage.add`. Reset in `resetRunArtifacts()` so
    /// each interactive session starts fresh.
    @ObservationIgnored private var lastInteractiveUsageSnapshot: SessionUsage?

    /// The planner session handle kept alive during the executor phase so it
    /// can be forked (Phase 3, `plans/acp-session-efficiency.md` §4). nil unless
    /// we're in the planner-executors ingest flow AND the planner session is
    /// still alive (not yet closed). Cleared in `finish()` and `stopAgent()`.
    @ObservationIgnored private var plannerSessionHandle: SessionHandle?
    /// Per-session token: `onExit` captures the token current at session start
    /// and only calls `finish` if it's STILL current. Prevents a stale `onExit`
    /// (a prior session terminating after a new one started — e.g. D3's
    /// `continueChat` takeover: `stopAgent` → `startInteractiveQuery`)
    /// from tearing down the new session. `finish`'s `isRunning` guard alone
    /// can't tell the sessions apart.
    @ObservationIgnored private var currentRunToken: UUID?
    /// The agent-run-lifecycle release closure for the current run (nil when no run is active).
    /// Stored so `finish()` — and thus the completion watchdog — can decrement
    /// the run counter even when the process's `terminationHandler` never fires.
    /// Without this, a process that dies unreconciled strands the sidebar
    /// without its final reload.
    @ObservationIgnored private var onUnlockHandler: (@MainActor @Sendable () -> Void)?
    /// Persistence callback for an interactive query chat (issue #119).
    /// Receives the not-yet-persisted TAIL of `events` at each turn boundary and
    /// once more at `finish()` — never the full array, so repeated flushes stay
    /// cheap. The sink's owner (`AgentOperationRunner`) is what actually writes to
    /// the store; the launcher only knows "hand this slice somewhere." `nil` for
    /// one-shot runs and whenever no chat has been created for the session (e.g.
    /// `store.startChat` failed). Cleared in `finish()` and `resetRunArtifacts()`.
    @ObservationIgnored private var transcriptSink: (@MainActor ([AgentEvent]) -> Void)?
    /// Summary sink (issue #411): called once in `finish()` after the final
    /// `flushTranscript()`, receiving (chatID, summary) so the store can
    /// persist the one-line model-response summary. `nil` when no chat is
    /// active (one-shot runs, or the session was never assigned a chatID).
    /// Cleared in `finish()` and `resetRunArtifacts()` for hygiene.
    @ObservationIgnored private var summarySink: (@MainActor (PageID, String) -> Void)?
    /// One-shot guard so the summary is generated only once per session
    /// (after the first assistant turn completes), not on every turn.
    /// Reset in `resetRunArtifacts()`.
    @ObservationIgnored private var summaryGenerated = false
    /// Cursor into `events`: the count already handed to `transcriptSink`. Makes
    /// `flushTranscript()` incremental — each call only sends events appended since
    /// the last flush — and idempotent when nothing new arrived since the last call.
    private var persistedEventCount = 0
    /// One-shot: true when the first user message of this session was already
    /// persisted at chat-creation time (by `WikiStoreModel.startChat`). The first
    /// `sendInteractiveMessage` consumes it — after appending `.userText` to
    /// `events` for live display, it bumps `persistedEventCount` past it so the
    /// next `flushTranscript()` skips it (no duplicate `chat_messages` row).
    /// Reset by `resetRunArtifacts()`. Only set on the fresh-chat path; the
    /// continue path (D3) leaves it false (no seeding for an existing chat).
    private var firstMessagePrePersisted = false
    /// True when `startInteractiveQuery` has already appended the first
    /// `.userText` to `events` (so the user sees their message immediately,
    /// before the ~4s backend startup). `sendInteractiveMessage` consumes +
    /// clears this to avoid a double-append.
    private var firstMessagePreDisplayed = false
    /// Backstop poller that reconciles the UI if the process `terminationHandler`
    /// is ever missed (see `startCompletionWatchdog`). Cancelled on teardown.
    private var watchdogTask: Task<Void, Never>?
    /// True once the "still working" check-in has fired for the current quiet
    /// period. Reset when activity resumes or in `resetRunArtifacts()`.
    private var watchdogHasWarned = false
    /// True while the last row in `events` is an in-progress `.assistantText` row
    /// being grown by streamed `.assistantTextDelta` chunks (issue #121). Reset by
    /// any other event (a tool call, a turn boundary, …) so unrelated `.assistantText`
    /// rows are never merged together.
    private var isStreamingAssistantRow = false
    /// True while the last row in `events` is an in-progress `.thinking` row
    /// being grown by streamed `.thinkingDelta` chunks (issue #391). Mirrors
    /// `isStreamingAssistantRow` — reset by any other event so unrelated
    /// `.thinking` rows are never merged together.
    private var isStreamingThinkingRow = false
    /// Append-only handle to the per-run `run.jsonl` (raw stream-json).
    private var logHandle: FileHandle?
    /// Append-only handle to the per-run `run.stderr.log`.
    private var stderrLogHandle: FileHandle?
    /// True when the running process is waiting for user turns over stdin.
    public private(set) var isInteractiveSession = false
    /// The chat row the current live interactive session is writing to (D2).
    /// Set by the runner when it installs the transcript sink — this is the chat
    /// whose `.chat(id)` tab is live-streaming. `ChatView` uses it as the
    /// source-of-truth switch: when `activeChatID == chatID`, render
    /// `launcher.events` (in-memory, streaming); otherwise render the persisted
    /// `store.chatMessages(chatID:)`. Cleared in `startNewChat()` (retarget
    /// back to draft) and in `finish()` AFTER the final turn-boundary flush has
    /// committed — clearing it too early re-sources the view from the store before
    /// the tail lands, producing a transient truncated transcript (D2 flip-timing).
    public var activeChatID: String?
    /// Stored, cancellable Task for the current interactive send (which waits for
    /// the generation gate before writing to stdin). Cancelled by `stopAgent()` and
    /// `finish()` so an in-flight gate wait doesn't outlive the session.
    @ObservationIgnored private var interactiveSendTask: Task<Void, Never>?

    /// Pure predicate for the Query page's debug cluster (spinner / Stop / Activity
    /// menu): the cluster is visible only while a QUERY turn is actively generating.
    /// Extracted as a pure static function so it is unit-testable without driving
    /// launcher state. The View calls this with its `launcher` state.
    static func showsQueryDebugControls(
        isGenerating: Bool, runningKind: WikiOperation.Kind?
    ) -> Bool {
        isGenerating && runningKind == .query
    }

    /// Centralize EVERY `isGenerating` transition through this one method so the
    /// per-turn callback fires from a single place and redundant transitions (no
    /// real change) are skipped. This is the single owner of the `isGenerating`
    /// invariant: the lock toggles exactly once per real transition, never on a
    /// no-op reassignment. Routing through a method (not a `didSet`) avoids
    /// Observation-macro interaction pitfalls.
    ///
    /// Slice 2: this is also where the pending-permission poller arms/disarms.
    /// always-ask blocks the turn (no `AgentEvent`s flow while a request is
    /// pending), so the poller is the only channel that surfaces pending requests
    /// to `pendingPermissions` for the UI. Armed on a real `true`; disarmed + a
    /// final refresh (to clear stale pending) on a real `false`.
    private func setGenerating(_ value: Bool) {
        guard isGenerating != value else { return }
        isGenerating = value
        if value {
            // Anchor the thinking timer at the start of each generation phase
            // (each interactive turn, one-shot run, etc.) so the timer resets
            // to 0s per turn rather than accumulating across the session
            // (issue #405).
            runStartedAt = Date()
            startPendingPermissionPoller()
        } else {
            runStartedAt = nil
            stopPendingPermissionPoller()
        }
    }

    /// Per-turn generation-gate release policy. Interactive sessions release the
    /// gate at EACH turn boundary (`.messageStop`/`.result`) so a peer launcher or
    /// ingest run can generate between turns. One-shot runs (ingest/lint/query) do
    /// NOT release per-turn — they hold the gate through `finish()`. Releasing in
    /// a one-shot would double-release with `finish()`, but `releaseGenerationSlot`
    /// is idempotent, so the real invariant being encoded is: one-shot runs must
    /// hold the gate for their full duration so no peer generation interleaves.
    /// Extracted as a pure static so the policy is unit-testable without driving
    /// launcher state.
    static func releasesGenerationSlotPerTurn(isInteractiveSession: Bool) -> Bool {
        isInteractiveSession
    }

    // MARK: - Pending-permission surfacing (slice 2: always-ask)

    /// Arm the backstop poller that refreshes `pendingPermissions` from the
    /// backend while a turn generates. The poller hops to the main actor, reads
    /// the backend's pending snapshot (downcast to `PermissionResolving` — a
    /// no-op for the CLI backend, which doesn't conform), and updates the
    /// observable array only on a real change (avoiding redundant view diffs).
    /// Polls faster (150ms) while a request is pending so Approve/Reject feels
    /// responsive, slower (300ms) otherwise. Cancelled on teardown.
    private func startPendingPermissionPoller() {
        pendingPollTask?.cancel()
        pendingPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refreshPendingPermissions()
                let interval = (self?.pendingPermissions.isEmpty ?? true)
                    ? UInt64(300_000_000)   // 300ms idle
                    : UInt64(150_000_000)   // 150ms while a request is pending
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    /// Cancel the poller and clear any surfaced pending requests (the turn ended
    /// or the session tore down). A final refresh runs to drain any last pending
    /// that arrived in the gap; if none remain the array clears.
    private func stopPendingPermissionPoller() {
        pendingPollTask?.cancel()
        pendingPollTask = nil
    }

    /// Pull the current pending-permission snapshot from the backend into
    /// `pendingPermissions` (main actor). No-op for the CLI backend (no
    /// `PermissionResolving` conformance) and when no session is live.
    public func refreshPendingPermissions() async {
        guard let handle = sessionHandle,
              let permBackend = backend as? PermissionResolving else {
            if !pendingPermissions.isEmpty { pendingPermissions = [] }
            return
        }
        let snapshot = await permBackend.pendingPermissions(sessionHandle: handle)
        if snapshot != pendingPermissions {
            pendingPermissions = snapshot
            // #608: surface the change to the Activity window via the per-run
            // callback (installed in `run(...)` for ingestion/lint). ACP agents
            // gate one write at a time, so we forward the first pending
            // request (or `nil` to clear the row once the continuation
            // resolves). `ChatView` continues to read `pendingPermissions`
            // directly via `@Observable` for its inline Approve/Reject chip —
            // this callback is the parallel channel for the Activity window's
            // per-item yellow row. No-op when the caller didn't install one
            // (interactive chat passes nil).
            onPendingPermission?(snapshot.first)
        }
    }

    /// Resolve a pending permission request by its option id — the Approve/Reject
    /// UI calls this with the chosen option's id. Resumes the backend's blocked
    /// continuation, unblocking the agent. Idempotent-ish: a no-op if the option
    /// isn't offered by any pending request.
    public func resolvePendingPermission(optionId: String) async {
        guard let handle = sessionHandle,
              let permBackend = backend as? PermissionResolving else { return }
        let resolved = await permBackend.resolvePermission(sessionHandle: handle, optionId: optionId)
        if resolved {
            await refreshPendingPermissions()
        }
    }

    // MARK: - Three independent mechanisms (relationship)

    /// The launcher coordinates three INDEPENDENT mechanisms. They never touch each
    /// other's state; understanding the boundaries is what keeps extraction from
    /// blocking the user.
    ///
    /// 1. **Generation gate** (`generationGate` / `awaitGenerationSlot` /
    ///    `releaseGenerationSlot`, per-launcher `holdsGenerationSlot` tracks THIS
    ///    launcher's gate state): serializes ACTIVE GENERATION globally across all
    ///    launchers sharing the same `GenerationGate` instance. One active generation
    ///    at a time across ingest / ask / edit / lint, regardless of which launcher
    ///    initiates it. CRITICALLY, "active generation" is scoped differently per path:
    ///    - One-shot runs (ingest/lint/query): hold the gate for the whole run.
    ///    - Interactive sessions (ask/edit): hold the gate only for ONE TURN (from
    ///      send to `messageStop`/`result`). The process itself stays alive between
    ///      turns WITHOUT holding the gate, so both Ask and Edit sessions can coexist
    ///      simultaneously; only one generates at a time.
    ///    `isRunning` is per-instance: it means "THIS launcher has a claude process
    ///    alive." It is NOT coupled to gate ownership — an interactive session's
    ///    `isRunning` stays true across idle turns when the gate is free.
    ///
    /// 2. **Agent-run lifecycle** (`store.agentRunCount`, ref-counted via
    ///    `onLock`/`onUnlock` around the spawn): tracks how many `claude`
    ///    processes are writing to this wiki. When the last run ends, the model
    ///    reloads from the store so the sidebar reflects the agent's writes.
    ///    No edit lock — CAS (page versions, W0) prevents data races, so
    ///    concurrent agent runs and in-app edits are fine. `save()` catches
    ///    `PageConflictError` and surfaces a "Page Was Updated" dialog.
    ///
    /// 3. **Extraction slot** (`extractionWaiters` / `awaitExtractionSlot` /
    ///    `releaseExtractionSlot`, held ↔ `isExtractionSlotBusy`): serializes ONLY
    ///    `pdf2md` conversions against each other (the VLM pipeline is heavy; one
    ///    conversion at a time on a single local machine). Acquiring it does NOT set
    ///    `isRunning`, does NOT set `isExtracting`, and does NOT fire `onLock`. A
    ///    `claude` query run starting during an extraction still runs immediately —
    ///    it takes the generation gate, which the extraction lock never holds.
    ///
    /// The phase flags `extractingSourceIDs` (extraction phase) and
    /// `ingestingSourceIDs` (agent phase, set at spawn commit) are the UI-facing
    /// projection of which lock/phase a file is in; they are kept separate so a
    /// pure extraction is never labeled "Ingesting…" and never greys out a peer's
    /// Ingest button.

    // MARK: - Shared generation gate

    /// The shared gate that serializes all ACTIVE GENERATION. All launchers sharing
    /// the same `GenerationGate` instance contend on a single FIFO queue — ingest,
    /// ask-turn, edit-turn, and lint never generate simultaneously. Each instance
    /// has its own `isRunning` flag (process alive) and `holdsGenerationSlot` flag
    /// (currently generating), which are now DECOUPLED — an interactive session's
    /// process can be alive without holding the gate (between turns).
    let generationGate: GenerationGate

    /// The number of generation requests currently queued for the slot (test seam).
    /// Delegates to the shared gate so single-launcher tests observe the same
    /// count as before.
    var generationSlotWaiterCount: Int { generationGate.waiterCount }

    /// True while this launcher holds the generation gate. For one-shot runs: held
    /// from slot acquire to `finish()`. For interactive sessions: held only while a
    /// turn is in flight (from `sendInteractiveMessage`'s send to `ingestStdout`'s
    /// `endsGeneration` event). Private — observable externally via `isGenerating`.
    @ObservationIgnored private var holdsGenerationSlot = false

    /// Which lane this launcher acquired (for lane-aware release, Phase 2).
    /// Set at acquire time so `releaseGenerationSlot()` doesn't need callers
    /// to pass the lane — it's called from multiple sites (finish, interactive
    /// turn boundaries) and the lane is always the same within a run.
    @ObservationIgnored private var acquiredLane: GenerationGate.GenerationLane?

    public let extractionCoordinator: ExtractionCoordinator

    public init(generationGate: GenerationGate = GenerationGate(),
         extractionCoordinator: ExtractionCoordinator = ExtractionCoordinator(
            containerDirectory: FileManager.default.temporaryDirectory,
            localExtractorFactory: { UnavailablePdf2MarkdownExtractor() })) {
        self.generationGate = generationGate
        self.extractionCoordinator = extractionCoordinator
    }

    /// Wait for the shared generation gate on the given lane, returning `true`
    /// iff this caller acquired it (and `holdsGenerationSlot` is now `true`).
    /// Returns `false` if the wait was cancelled before the slot was handed over
    /// — in that case the caller owns nothing and must simply return (no
    /// release). Cancellation-safe: a cancelled waiter self-removes from the
    /// gate's queue and is never handed the slot. See `GenerationGate` for the
    /// full FIFO + cancellation protocol.
    ///
    /// NOTE: this does NOT touch `isRunning`. Process lifetime (`isRunning`) is
    /// decoupled from generation serialization (`holdsGenerationSlot`).
    func awaitGenerationSlot(for lane: GenerationGate.GenerationLane = .interactive) async -> Bool {
        let ok = await generationGate.acquire(lane)
        if ok {
            holdsGenerationSlot = true
            acquiredLane = lane
        }
        return ok
    }

    /// Release the generation gate, handing it to the next live waiter (FIFO) or
    /// freeing it. Idempotent: guarded by `holdsGenerationSlot` so double-calls
    /// (e.g. from `finish()` racing an interactive turn's `endsGeneration` release)
    /// are safe. Does NOT touch `isRunning`.
    func releaseGenerationSlot() {
        guard holdsGenerationSlot else { return }
        holdsGenerationSlot = false
        let lane = acquiredLane ?? .interactive
        acquiredLane = nil
        generationGate.release(lane)
    }

    /// Run an operation `request` against one wiki. Serializes on the generation gate:
    /// if another agent run is generating, this `await`s until it finishes (or
    /// this task is cancelled). Returns without spawning if cancelled while queued.
    ///
    /// The launcher OWNS the per-run scratch dir, so it also owns STAGING: it creates
    /// scratch, writes `WIKI_STATE.md` (and, for Ingest, `source.<ext>`) from the
    /// bytes the caller read from SQLite, then finalizes the `WikiOperation` with the
    /// resulting absolute scratch paths so the `-p` prompt points the agent at
    /// reliable local disk — never the ~5s-laggy read-only mount.
    ///
    /// - `request` carries the per-op intent + the source bytes/state text gathered
    ///   at click time.
    /// - `wikiID`/`wikiRoot`/`systemPrompt` come from the active wiki at click time
    ///   (`wikiRoot` resolved from the FP manager — never hardcoded).
    /// - `wikictlDirectory` is the dir holding the embedded `wikictl`
    ///   (`Self Driving Wiki.app/Contents/Helpers`), prepended to the child's PATH so the
    ///   agent's `wikictl` calls resolve.
    /// - `onLock`/`onUnlock` are the edit-lock callbacks: `onLock` fires before the
    ///   spawn, `onUnlock` from `finish()` (so a killed agent, or one whose
    ///   `terminationHandler` was missed and is reconciled by the watchdog, still
    ///   releases). Both run on the main actor.
    /// - `ingestingSourceIDs` is the **agent phase** flag for THIS run: the ids whose
    ///   ingest is now committing. The launcher assigns it to `self.ingestingSourceIDs`
    ///   at spawn commit (around `onLock`) — NOT while queued for the slot — so a
    ///   pure extraction or a queued ingest never sets it. Empty for query/lint
    ///   runs (the default), which keeps the flag clear and the cross-file Ingest
    ///   greyout unblocked. Cleared in `finish()`.
    /// - `onEvent` is the per-event transcript callback for THIS run (Activity
    ///   window). It MUST be passed here — not assigned to `onAgentEvent`
    ///   before calling — because `resetRunArtifacts()` clears the property at
    ///   the top of every run; the launcher installs it after the reset.
    /// - `onLiveUsage` is the per-`usage_update` callback for THIS run (#544
    ///   live progress). Same lifecycle/install rule as `onEvent` — passed
    ///   here, installed after `resetRunArtifacts()`. `nil` for callers that
    ///   don't need live-progress display. May never fire if the backend
    ///   doesn't stream usage updates.
    /// - `onPendingPermission` is the per-pending-permission-change callback
    ///   for THIS run (#608 Activity-window surfacing). Same lifecycle/install
    ///   rule as `onEvent`/`onLiveUsage` — passed here, installed after
    ///   `resetRunArtifacts()`. `nil` for callers that don't surface
    ///   permission stalls (e.g. interactive chat reads `pendingPermissions`
    ///   directly via `@Observable`). May never fire if the agent isn't
    ///   configured for `always-ask`.
    /// - `providerLabel` is the configured provider's display label (e.g.
    ///   "Claude") for the run — attached to each live-usage snapshot so the
    ///   Activity window can show "Claude · Sonnet 4". The backend's
    ///   `sessionUsage(for:)` does NOT know this; the launcher enriches with
    ///   it. Nil is fine (the model id alone still shows).
    public func run(
        request: OperationRequest,
        wikiID: String,
        wikiRoot: String,
        systemPrompt: String,
        wikictlDirectory: String,
        ingestingSourceIDs: Set<PageID> = [],
        workspaceID: String? = nil,
        queueItemID: String? = nil,
        onEvent: (@Sendable (AgentEvent) -> Void)? = nil,
        onLiveUsage: (@Sendable (SessionUsage) -> Void)? = nil,
        onPendingPermission: (@Sendable (PendingPermission?) -> Void)? = nil,
        providerLabel: String? = nil,
        onLock: @escaping @MainActor () -> Void,
        onUnlock: @escaping @MainActor @Sendable () -> Void
    ) async {
        // Serialize on the shared generation gate (Phase 2: lane-aware).
        // The lane is derived from the request kind: ingest-class (ingest,
        // lint, lintPage) → .ingest lane; query/chat → .interactive lane.
        let lane = request.generationLane
        let acquired = await awaitGenerationSlot(for: lane)
        guard acquired, !Task.isCancelled else {
            // Cancelled while queued (self-removed; gate not acquired) — bail without
            // touching the gate. If we were handed the gate then cancelled (race),
            // give it back so a queued peer isn't stranded.
            if acquired { releaseGenerationSlot() }
            if Task.isCancelled {
                preflightError = "Run cancelled before starting."
            } else {
                preflightError = "Another operation is already running. Wait for it to finish and try again."
            }
            return
        }

        // Set isRunning NOW (gate acquired = this run is committed). This is the
        // explicit assignment that decouples process lifetime from gate ownership.
        isRunning = true

        // PREFLIGHT + STAGING run AFTER the gate is acquired, so any early-return
        // below must `isRunning = false` + `releaseGenerationSlot()` to hand the gate
        // to the next waiter (or free it). The agent-run lifecycle (`onLock`)
        // fires only on a successful spawn, so a preflight/staging failure
        // does not increment the run counter.
        resetRunArtifacts()

        // Install the per-run transcript callback AFTER the reset (which nils
        // the property to keep a stale callback from receiving a new run's
        // events).
        onAgentEvent = onEvent
        // #544 live progress: install the per-run live-usage callback + the
        // provider label used to enrich each snapshot. Same lifecycle as
        // `onAgentEvent` — installed after the reset, cleared in
        // `finish()`/`resetRunArtifacts()`.
        self.onLiveUsage = onLiveUsage
        self.liveUsageProviderLabel = providerLabel
        // #608: install the per-run pending-permission callback so the
        // Activity window can surface "Permission pending: <cmd>" while a
        // run is parked on an always-ask prompt. Same lifecycle/install rule
        // as `onAgentEvent`/`onLiveUsage`. `refreshPendingPermissions()`
        // fires it on every real change of `pendingPermissions`.
        self.onPendingPermission = onPendingPermission

        // Resolved fresh at spawn time so Settings changes apply without a
        // restart.
        let dir = containerDirectory ?? (try? DatabaseLocation.appGroupContainerDirectory()) ?? FileManager.default.temporaryDirectory

        // #607: per-operation permission policy. The kind is known from the
        // `request` parameter (the staged `WikiOperation` isn't built yet, but
        // the enum cases map 1:1 — `.ingest` → `.ingest`, `.lint`/`.lintPage`
        // → `.lint`, else `.chat`). Pre-#607 a single shared key fed all
        // three, so a user who chose `alwaysAsk` for chat got the same gating
        // on an unattended ingest/lint — guaranteeing a stall (#606).
        let permissionKind: PermissionOperationKind = {
            switch request {
            case .ingest: return .ingest
            case .lint, .lintPage: return .lint
            case .query: return .chat
            }
        }()
        let policy: PermissionPolicy = resolvePermissionMode(permissionKind)
        // #606: chat is interactive (unbounded — the UI chip is the release
        // valve); ingest/lint are unattended and MUST auto-reject so a stuck
        // permission can't burn the 1800s ceiling.
        let permissionBudget: Duration? = (permissionKind == .chat) ? nil : .seconds(60)
        // #609: queued-ingestion ceiling is tighter than the interactive
        // default so a stalled ingest/lint turn burns 10 minutes, not 30.
        // `runACPIngestPlannerExecutors` (large-source ingest) reuses this
        // `self.backend` — so the ceiling chosen here is the ceiling that
        // planner/executor/finalizer phases run under.
        let turnCeiling = TurnLivenessPolicy.ceiling(for: permissionKind)

        // #324: the launcher reads `agent-providers.json`, picks the default
        // (or selected) provider, and resolves its PATH command + Keychain key
        // into providerHints. The app is ACP-only.
        //
        // per-stage-model-selection (#704 removed): there is no per-operation
        // provider pin anymore — every operation (chat / ingest / lint)
        // resolves ONE provider via `selectedProvider()`. Per-stage MODEL
        // selection (planner / executor / finalizer) varies the model id
        // within that ONE provider's catalog; see
        // `runACPIngestPlannerExecutors` and `AgentProvidersConfig.modelId(
        // forStage:fallbackProvider:)`. `permissionKind` is still computed
        // above to drive permission policy + turn ceiling choices, NOT to
        // pick a provider.
        let config = providersConfig()
        let provider = config.selectedProvider()
        self.backend = resolveBackend(policy, permissionBudget, turnCeiling)

        // Resolve the provider's spawn command (PATH-resolved because the
        // swift-acp SDK's launch() does NOT do PATH lookup) + the Keychain-backed
        // API key (keyed by provider id).
        guard let spawn = resolveACPProviderSpawn(provider) else {
            isRunning = false
            releaseGenerationSlot()
            return
        }
        let resolvedACPCommand = spawn.command
        let acpAPIKey = spawn.apiKey
        let resolvedPath = resolvedACPCommand[0]
        preflightError = nil

        guard let scratch = makeScratchDirectory(id: queueItemID) else {
            preflightError = "Could not create a scratch working directory for the agent."
            isRunning = false
            releaseGenerationSlot()
            return
        }

        // Stage inputs into scratch from reliable local disk, then finalize the
        // operation with the staged absolute paths. A staging failure aborts the run
        // (a run that couldn't stage would fall back to probing the laggy mount).
        let operation: WikiOperation
        do {
            operation = try request.stage(into: scratch)
        } catch {
            preflightError = "Could not stage the agent's inputs: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: scratch)
            isRunning = false
            releaseGenerationSlot()
            return
        }

        let pdf2mdScriptPath = resolvePdf2mdScriptPath()
        let sandbox = resolveSandboxInvocation(
            wikiID: wikiID, scratch: scratch, dir: dir, pdf2mdScriptPath: pdf2mdScriptPath)
        if sandbox != nil { createSandboxTmpDir(in: scratch) }

        // RESERVE per-run metadata. isRunning is already `true` (set above).
        // Note: runStartedAt is set inside setGenerating(true) below.
        let now = Date()
        runningKind = operation.kind
        lastActivityAt = now
        runCommitedAt = now
        runProviderLabel = provider.id
        openLogFiles(in: scratch)
        // A one-shot run is "generating" for its whole duration. The edit lock
        // for one-shot runs is owned by `onLock`/`onUnlock` around the spawn.
        setGenerating(true)
        // SPAWN COMMIT: the agent phase now begins. Assign the agent-phase flag
        // (`ingestingSourceIDs`) here — NOT while queued for the gate — so the
        // "Ingesting…" label and the cross-file Ingest greyout activate only once
        // the spawn is actually committed. For query/lint this is empty (default),
        // which clears any stale flag. See `extractingSourceIDs` for the separate
        // extraction-phase flag, which the runner manages around the pdf2md block.
        self.ingestingSourceIDs = ingestingSourceIDs
        onLock()
        onUnlockHandler = onUnlock

        // Multi-phase ACP ingest: for large sources, sub-agents (the Sonnet
        // `source-reader` digester) don't work — ACP has no custom agent types
        // and background agents can't complete within a single turn. Replace
        // the one-shot spawn with sequential single-turn sessions: planner →
        // executors → finalizer. Tiny sources (< 4 KB) use the existing
        // single-session path below.
        if case .ingest(_, _, _, let plan) = operation, plan.isLargeSource {
            await runACPIngestPlannerExecutors(
                scratch: scratch,
                operation: operation,
                wikiRoot: wikiRoot,
                wikiID: wikiID,
                systemPrompt: systemPrompt,
                wikictlDirectory: wikictlDirectory
            )
            return
        }

        // Build the backend profile. The launcher resolves app-level concerns
        // (scratch dir, wikictl env); `ACPBackend` owns the spawn + session.
        let cli = CLIProfile(
            operation: operation,
            wikiRoot: wikiRoot,
            wikiID: wikiID,
            wikictlDirectory: wikictlDirectory,
            onStdoutChunk: { [weak self] chunk in
                Task { @MainActor [weak self] in self?.ingestRawStdout(chunk) }
            },
            onStderrChunk: { [weak self] chunk in
                Task { @MainActor [weak self] in self?.ingestStderr(chunk) }
            })
        var providerHints = AgentBackendFactory.providerHints(
                provider: provider,
                resolvedCommand: resolvedACPCommand,
                apiKey: acpAPIKey,
                selectedModelId: providersConfig().selectedModelId(forProvider: provider.id))
        if let wsID = workspaceID {
            providerHints[HintKey.env("WIKI_WORKSPACE")] = wsID
        }
        // #397: inject the author provenance into the child env so agent-written
        // pages carry created_by/last_edited_by "for free" — no agent action needed.
        // The launcher resolves it from the operation kind (one-shot runs) or the
        // chatID (interactive runs). An explicit `--author` on wikictl still wins.
        providerHints[HintKey.env("WIKI_AUTHOR")] = Self.authorForRun(kind: operation.kind, chatID: nil)
        let profile = BackendProfile(
            providerHints: providerHints,
            scratchDirectory: scratch,
            isReadOnly: false,
            cli: cli,
            debugLogURL: debugFolderURL)

        do {
            DebugLog.agent("run: spawning kind=\(operation.kind.rawValue) wikiID=\(wikiID) exe=\(resolvedPath)")
            let runToken = UUID()
            let session = try await backend.start(
                profile: profile,
                systemPrompt: systemPrompt,
                onExit: { [weak self] status in
                    Task { @MainActor [weak self] in
                        // Only finish if THIS session is still current — a stale
                        // onExit (a prior session terminating after a new one
                        // started) must not tear down the new session.
                        guard let self, self.currentRunToken == runToken else { return }
                        self.finish(status: Int32(status))
                    }
                })
            sessionHandle = session
            currentRunToken = runToken
            // #329: cache the agent's advertised models per-provider for the
            // picker (ACP only; the CLI backend has no model discovery).
            captureAndCacheModels(provider: provider, session: session)
            captureProcessID(session: session)
            startCompletionWatchdog()

            // Consume the per-turn stream INLINE so run() does not return until
            // the turn completes. The queue worker awaits run() to decide when
            // the item is done — a fire-and-forget Task here marks it completed
            // while the agent is still streaming (#475). Mirrors the pattern in
            // sendInteractiveMessage. The @MainActor await suspends per event;
            // it does not block the main actor.
            let generationGateReleasesPerTurn = Self.releasesGenerationSlotPerTurn(
                isInteractiveSession: isInteractiveSession)
            // The prompt is sent via `send()`. The sub-agent plan (source-reader
            // digester agents) doesn't work over ACP — no custom agent types,
            // and background agents can't complete within a single turn. Append
            // an instruction to do everything directly.
            var promptText = operation.prompt(wikiRoot: wikiRoot)
            promptText += "\n\nIMPORTANT: Do NOT dispatch sub-agents, background tasks, or async agents. Do NOT use sleep or ScheduleWakeup. Read all sources, process them, and write all wiki pages directly in THIS session — everything must complete before you stop."
            let stream = await self.backend.send(
                TurnInput(userText: promptText), into: session)
            for await event in stream {
                self.lastActivityAt = Date()
                self.mergeOrAppend(event)
                if AgentEvent.endsGeneration(event) {
                    self.setGenerating(false)
                    self.flushTranscript()
                    if generationGateReleasesPerTurn {
                        self.releaseGenerationSlot()
                    }
                }
            }
            // Stream ended (turn done or process died). If onExit hasn't fired
            // yet (finish() not called), ensure teardown happens before run()
            // returns so callers see post-finish state: gate released, run
            // lifecycle decremented, onAgentEvent cleared. finish() is idempotent
            // (isRunning guard), so a later onExit-triggered finish() is a no-op.
            //
            // #528 spike: capture per-session usage before finish() nils the
            // session handle. The ACPBackend retains the usage state until the
            // session is closed/cancelled, but finish() drops our handle ref.
            if isRunning, let handle = sessionHandle {
                await capturePhaseUsage(backend: self.backend, session: handle, providerLabel: provider.label)
            }
            if isRunning {
                finish(status: exitStatus ?? 0)
            }
        } catch {
            DebugLog.agent("run: spawn FAILED: \(error.localizedDescription)")
            preflightError = "Failed to launch claude: \(error.localizedDescription)"
            closeLogFiles()
            try? FileManager.default.removeItem(at: scratch)
            runningKind = nil
            currentProcessID = nil
            lastActivityAt = Date()
            // Clear the agent-phase ingest flag so spawn failure doesn't strand
            // the "Ingesting…" row label or the cross-file Ingest greyout. finish()
            // is not called on this path, so we clear explicitly here.
            self.ingestingSourceIDs = []
            releaseRunLifecycle()
            // Release the generation gate so a queued peer isn't stranded.
            // Also clear isRunning (set above at gate acquire; spawn failed).
            isRunning = false
            releaseGenerationSlot()
        }
    }

    // MARK: - Multi-phase ACP ingestion (planner → executors → finalizer)

    /// Replace the broken single-session ACP ingestion (which relies on Claude's
    /// in-process sub-agents that don't work over ACP) with a multi-process
    /// architecture: a **Planner** session reads sources and produces a page plan
    /// (`plan.json`), then **Executor** sessions each write their assigned pages
    /// directly via `wikictl`, and a **Finalizer** session writes `index.md` + log
    /// entries. Each phase is a clean, independent single-turn ACP session — no
    /// sub-agents, no background dispatch, no sleep.
    ///
    /// **Lifecycle ownership:** This method is a structural replacement for
    /// `run()`'s spawn-commit block for ACP large ingest. It is called AFTER
    /// `run()` has acquired the generation gate, fired `onLock`, opened log files,
    /// and set `isRunning`/`setGenerating(true)`/`ingestingSourceIDs`. It MUST:
    /// - Pass a phase-tracking `onExit` to each phase (does NOT call `finish()`).
    /// - Update `sessionHandle`/`currentRunToken` per phase so `stopAgent()` and
    ///   the watchdog track the live phase.
    /// - Call `finish()` exactly once at the end (success or unrecoverable failure).
    ///
    /// #604: per-stage provider/model assignment was removed — every stage
    /// (planner/executor/finalizer) now uses the **app default provider** + its
    /// `selectedModelId`, identical to the single-session `run()` path.
    /// `run()` at :954 has ALREADY assigned `self.backend = resolveBackend(...)`
    /// before delegating here at :1022. This method resolves the (provider,
    /// modelId, spawn, providerHints) ONCE at the top — re-deriving them is
    /// cheap (no actor construction), and REUSES `self.backend` rather than
    /// calling `resolveBackend` again (which would orphan the `ACPBackend`
    /// actor `run()` already built). All three phases share that one backend
    /// instance + one provider resolution. The fork-from-planner optimization
    /// and `runParallelExecutors`/`runPhase`/`closePlannerSession` lifecycle
    /// are unchanged.
    private func runACPIngestPlannerExecutors(
        scratch: URL,
        operation: WikiOperation,
        wikiRoot: String,
        wikiID: String,
        systemPrompt: String,
        wikictlDirectory: String
    ) async {
        // Safety net: if any code path exits without calling finish() (e.g. an
        // unexpected throw from a future adding await between phases), ensure the
        // generation gate + agent-run lifecycle are released. finish() is
        // idempotent (guards isRunning), so this is a no-op when finish() was
        // already called.
        defer {
            if isRunning { finish(status: -1) }
        }

        startCompletionWatchdog()

        guard case .ingest(let sourcePaths, let stagedSourcePaths, let stateFilePath, _) = operation else {
            DebugLog.agent("runACPIngest: not an ingest operation — aborting")
            finish(status: -1)
            return
        }
        let sourceIDs = sourcePaths.map { WikiOperation.sourceID(fromPath: $0) }
        let sourceFileNames = stagedSourcePaths.map { ($0 as NSString).lastPathComponent }

        // #324 + #604: the launcher reads `agent-providers.json`, picks the
        // default (or selected) provider, and resolves its PATH command +
        // Keychain key into providerHints. The app is ACP-only. Per #604
        // (per-stage routing removal), the SAME resolution drives
        // planner/executor/finalizer — exactly the same pattern the
        // single-session `run()` path uses at :950-965.
        //
        // #607: ingest policy reads its OWN `ingestPermissionMode` key (NOT
        // the chat key) — a user who chose `alwaysAsk` for chat no longer
        // stalls an unattended ingest. #606: a deferred ingest permission
        // auto-rejects after `.seconds(60)` so even a misconfigured ingest
        // can't burn the 1800s ceiling (the sandbox already confines writes —
        // `bypass` is the correct default for an unattended pipeline). Note
        // the policy + budget values themselves are read + consumed by
        // `run()` at :944-948 when it builds `self.backend` via
        // `resolveBackend(policy, permissionBudget)` BEFORE delegating here
        // at :1022 — we REUSE `self.backend`, never call `resolveBackend`
        // again (which would orphan the ACPBackend actor `run()` built).

        // Resolve the ONE provider + spawn all three phases will share.
        //
        // per-stage-model-selection (#704 removed): there is no per-operation
        // provider pin anymore — ingest resolves ONE provider via
        // `selectedProvider()`, and per-stage MODEL selection varies the model
        // id within that provider's catalog (planner / executor / finalizer
        // can pick `glm-5.2` / `glm-5.2-fast` / `glm-5.2-short`). The stage
        // model ids are resolved + applied per-phase below; this top-level
        // resolution stays ONE provider so the warm subprocess is reused
        // across planner/executor/finalizer.
        let provider = providersConfig().selectedProvider()
        let plannerModel = providersConfig().modelId(forStage: ACPIngestStage.planner.rawValue, fallbackProvider: provider.id)
        let executorModel = providersConfig().modelId(forStage: ACPIngestStage.executor.rawValue, fallbackProvider: provider.id)
        let finalizerModel = providersConfig().modelId(forStage: ACPIngestStage.finalizer.rawValue, fallbackProvider: provider.id)
        guard let spawn = resolveACPProviderSpawn(provider) else {
            DebugLog.agent("runACPIngest: ACP exe missing for provider=\(provider.id) — aborting")
            preflightError = "The agent executable for ‘\(provider.label)’ was not found on your PATH."
            finish(status: -1)
            return
        }
        // Refuse to spawn without an explicit model on EVERY stage (#704 + this
        // plan's §6). Without this, the ACP subprocess silently falls through
        // to its own first-listed upstream model (e.g. `opencode/big-pickle`,
        // a free model nobody chose) — the diagnosed 2026-07-18 ingestion-stall
        // root cause #6. Per-stage validation: a missing *executor* model (with
        // planner/finalizer set) now produces a phase-named refusal, not a
        // silent spawn. See `tmp/ingestion-stall-diagnosis.md` and
        // `SpawnModelGuard.swift`.
        let stageValidations: [(ACPIngestStage, String?)] = [
            (.planner, plannerModel),
            (.executor, executorModel),
            (.finalizer, finalizerModel)
        ]
        for (stage, stageModelId) in stageValidations {
            if let msg = SpawnModelGuard.validate(provider: provider, modelId: stageModelId, stageName: stage.label) {
                preflightError = msg
                finish(status: -1)
                return
            }
        }
        // Base spawn config WITHOUT a model — model is per-phase (§4.3 of
        // plans/per-stage-model-selection.md). Each phase injects its OWN
        // resolved stage model id (planner/executor/finalizer) into a fresh
        // hint dict, so `createSession`/`applyModelIfNeeded` apply the right
        // model per phase. Keeping the provider/spawn identical across phases
        // means `self.backend` (the warm `ACPBackend` actor `run()` already
        // built at :954) is reused unchanged — no new subprocess.
        let baseHints = AgentBackendFactory.providerHints(
            provider: provider,
            resolvedCommand: spawn.command,
            apiKey: spawn.apiKey,
            selectedModelId: nil)
        // Per-phase hint dict: base + the stage's resolved model id. The
        // orchestrator resolved all three stage ids up top (§4.3) —
        // `plannerModel` is the load-bearing baseline for the fork path's
        // `applyModelIfNeeded` (§4.5, HIGH #2 — NOT the stale stored
        // `modelsInfo.currentModelId`).
        func hints(for stage: ACPIngestStage) -> [String: String] {
            var h = baseHints
            let m: String? = {
                switch stage {
                case .planner:   return plannerModel
                case .executor:  return executorModel
                case .finalizer: return finalizerModel
                }
            }()
            if let m, !m.isEmpty {
                h[HintKey.acpSelectedModelId.rawValue] = m
            }
            return h
        }
        // `self.backend` was assigned by `run()` at :954 before delegating
        // here — there is always an instance. Read it into a local so the
        // phases below capture a stable Sendable reference (AgentBackend is
        // Sendable; `self.backend` is `@ObservationIgnored var`).
        let backend = self.backend

        // Build a shared CLI profile closure (sets the env vars `ACPBackend`
        // reads: WIKI_DB, WIKICTL, PATH).
        let makeCLIProfile = { (op: WikiOperation) in
            CLIProfile(
                operation: op,
                wikiRoot: wikiRoot,
                wikiID: wikiID,
                wikictlDirectory: wikictlDirectory)
        }

        // --- Phase 1: Planner ---
        DebugLog.agent("runACPIngest: Phase 1 — Planner (model=\(plannerModel ?? "nil"))")
        currentIngestPhase = "planner"
        let plannerHints = hints(for: .planner)
        let plannerProfile = BackendProfile(
            providerHints: plannerHints,
            scratchDirectory: scratch,
            isReadOnly: false,
            cli: makeCLIProfile(operation), debugLogURL: debugFolderURL)
        let plannerPrompt = ACPIngestPrompts.plannerPrompt(
            stateFilePath: stateFilePath,
            stagedSourcePaths: stagedSourcePaths,
            sourceIDs: sourceIDs)

        guard let plannerSession = await runPhase(
            backend: backend,
            profile: plannerProfile,
            systemPrompt: systemPrompt,
            prompt: plannerPrompt,
            phaseName: "planner",
            stage: .planner,
            baselineModelId: nil  // planner uses createSession — baseline from newSession (fresh)
        ) else {
            // Planner failed — fall back to single-session ACP ingest on the
            // same resolution (the #604 collapsed default provider).
            DebugLog.agent("runACPIngest: planner failed — falling back to single-session")
            await runACPIngestFallback(
                operation: operation,
                wikiRoot: wikiRoot,
                scratch: scratch,
                systemPrompt: systemPrompt,
                makeCLIProfile: makeCLIProfile,
                backend: backend,
                provider: provider,
                providerHints: plannerHints)
            return
        }

        // Capture models (provider-level, not phase-level).
        captureAndCacheModels(provider: provider, session: plannerSession)
        captureProcessID(session: plannerSession)
        // Phase 3: keep the planner session ALIVE through the executor phase so
        // it can be forked — the forked executor inherits the planner's
        // understanding of the source layout without the reasoning noise. The
        // session is closed after all executors are done.
        // (Pre-Phase-3: the session was closed here immediately. Now we store the
        // handle and close it later — see `closePlannerSession()`)
        plannerSessionHandle = plannerSession

        // Check for cancellation (user hit Stop during planner).
        guard isRunning else {
            DebugLog.agent("runACPIngest: cancelled after planner phase")
            return  // finish() already called by stopAgent()
        }

        // Read the plan the planner wrote.
        guard let plan = ACPIngestPlan.load(from: scratch) else {
            // No valid plan.json — fall back to single-session.
            DebugLog.agent("runACPIngest: no valid plan.json — falling back to single-session")
            await runACPIngestFallback(
                operation: operation,
                wikiRoot: wikiRoot,
                scratch: scratch,
                systemPrompt: systemPrompt,
                makeCLIProfile: makeCLIProfile,
                backend: backend,
                provider: provider,
                providerHints: plannerHints)
            return
        }
        DebugLog.agent("runACPIngest: plan loaded — \(plan.pages.count) pages across \(plan.distinctSourceFiles.count) source file(s)")

        // --- Phase 2: Executors (one per source file) ---
        // All executors share the SAME `.executor` stage model id — no per-file
        // differentiation. The per-session `applyModelIfNeeded` call after each
        // fork (§4.5, HIGH #2) handles the `setModel` uniformly. Baseline is
        // `plannerModel` (the planner's RESOLVED model — NOT the stale inherited
        // `modelsInfo.currentModelId`).
        let executorHints = hints(for: .executor)
        let executorProfile = BackendProfile(
            providerHints: executorHints,
            scratchDirectory: scratch,
            isReadOnly: false,
            cli: makeCLIProfile(operation), debugLogURL: debugFolderURL)
        let maxConcurrent = await (backend as? ACPBackend)?.maxConcurrentExecutorCount() ?? 1

        if maxConcurrent > 1 && plan.distinctSourceFiles.count > 1 {
            // Phase 4: parallel executors via withTaskGroup. N source files
            // are processed concurrently on N forked sessions of the same
            // subprocess. Events are buffered per-session and flushed to the
            // main actor as batches on each turn-end (avoiding interleaved
            // streaming deltas that would garble the transcript).
            DebugLog.agent("runACPIngest: Phase 2 — Parallel executors (maxConcurrent=\(maxConcurrent), \(plan.distinctSourceFiles.count) source file(s), model=\(executorModel ?? "nil"))")
            currentIngestPhase = "executor[parallel]"
            await runParallelExecutors(
                backend: backend,
                provider: provider,
                executorProfile: executorProfile,
                plan: plan,
                stateFilePath: stateFilePath,
                sourceIDs: sourceIDs,
                systemPrompt: systemPrompt,
                maxConcurrent: maxConcurrent,
                executorModel: executorModel,
                plannerModel: plannerModel)
        } else {
            // Serial executors (Phase 3 behavior — current).
            for sourceFile in plan.distinctSourceFiles {
                guard isRunning else { break }  // cancelled
                let assignments = plan.assignments(forSource: sourceFile)
                guard !assignments.isEmpty else { continue }
                let executorProfile = BackendProfile(
                    providerHints: executorHints,
                    scratchDirectory: scratch,
                    isReadOnly: false,
                    cli: makeCLIProfile(operation), debugLogURL: debugFolderURL)
                let executorPrompt = ACPIngestPrompts.executorPrompt(
                    stateFilePath: stateFilePath,
                    assignments: assignments,
                    allPageTitles: plan.allPageTitles,
                    sourceIDs: sourceIDs)
                DebugLog.agent("runACPIngest: Phase 2 — Executor[\(sourceFile)] (\(assignments.count) page(s))")
                currentIngestPhase = "executor[\(sourceFile)]"
                // Partial failure: log and continue to next executor.
                // Phase 3: if the planner session is still alive, try to fork it
                // so the executor inherits the planner's source context. If fork
                // is unsupported (or the planner session was already closed), the
                // runPhase helper falls back to a fresh `backend.start()`.
                let forkFrom = (backend as? ACPBackend != nil) ? plannerSessionHandle : nil
                if let session = await runPhase(
                    backend: backend,
                    profile: executorProfile,
                    systemPrompt: systemPrompt,
                    prompt: executorPrompt,
                    phaseName: "executor[\(sourceFile)]",
                    stage: .executor,
                    baselineModelId: plannerModel,  // §4.5 HIGH #2 — planner's RESOLVED model, NOT stale stored
                    forkFrom: forkFrom
                ) {
                    await capturePhaseUsage(backend: backend, session: session, providerLabel: provider.label)
                    if let acp = backend as? ACPBackend {
                        await acp.closeSession(session)
                    } else {
                        await backend.cancel(session)
                    }
                } else {
                    DebugLog.agent("runACPIngest: executor[\(sourceFile)] FAILED — skipping (partial failure)")
                }
            }
        }

        // Phase 3: all executor forks are done — close the planner session now.
        // It has served its purpose as the fork source. If it was never kept
        // alive (e.g., the planner failed early and we fell back), this is nil.
        if let plannerSession = plannerSessionHandle {
            DebugLog.agent("runACPIngest: closing planner session (all forks done)")
            await capturePhaseUsage(backend: backend, session: plannerSession, providerLabel: provider.label)
            if let acp = backend as? ACPBackend {
                await acp.closeSession(plannerSession)
            } else {
                await backend.cancel(plannerSession)
            }
            plannerSessionHandle = nil
        }

        // Check for cancellation before finalizer.
        guard isRunning else {
            DebugLog.agent("runACPIngest: cancelled after executor phases")
            return
        }

        // --- Phase 3: Finalizer ---
        let finalizerHints = hints(for: .finalizer)
        let finalizerProfile = BackendProfile(
            providerHints: finalizerHints,
            scratchDirectory: scratch,
            isReadOnly: false,
            cli: makeCLIProfile(operation), debugLogURL: debugFolderURL)
        let finalizerPrompt = ACPIngestPrompts.finalizerPrompt(
            stateFilePath: stateFilePath,
            sourceFileNames: sourceFileNames,
            sourceIDs: sourceIDs)
        DebugLog.agent("runACPIngest: Phase 3 — Finalizer (model=\(finalizerModel ?? "nil"))")
        currentIngestPhase = "finalizer"
        if let session = await runPhase(
            backend: backend,
            profile: finalizerProfile,
            systemPrompt: systemPrompt,
            prompt: finalizerPrompt,
            phaseName: "finalizer",
            stage: .finalizer,
            baselineModelId: nil  // finalizer uses createSession — baseline from newSession (fresh)
        ) {
            await capturePhaseUsage(backend: backend, session: session, providerLabel: provider.label)
            if let acp = backend as? ACPBackend {
                await acp.closeSession(session)
            } else {
                await backend.cancel(session)
            }
        }

        // Phase 1: terminate the warm subprocess now that all phases are done.
        // (`closeSession` freed the session contexts but keeps the subprocess
        // alive; `cancel()` tears it down even after the session record is
        // gone — we pass a dummy SessionHandle because cancel() targets
        // `warmProcess` independently of the session map.)
        await backend.cancel(SessionHandle(id: ""))

        finish(status: 0)
    }

    // MARK: - Phase 4: Parallel executor dispatch

    /// Run N executor sessions concurrently via `withTaskGroup` (Phase 4,
    /// `plans/acp-session-efficiency.md` §5). Each source file is processed on
    /// its own forked (or fresh) session. Events are buffered per-session and
    /// flushed to the main actor as batches on each turn-end — this avoids
    /// interleaved streaming deltas (`.assistantTextDelta`) from different
    /// sessions that would garble the transcript's streaming-merge logic
    /// (`mergeOrAppend`).
    ///
    /// **Concurrency model:**
    /// - `ACPBackend` is an actor — `forkSession`/`send`/`closeSession` calls
    ///   are serialized at the actor level, but the agent's prompt processing
    ///   runs concurrently on different sessions (each `send()` returns an
    ///   `AsyncStream` with its own continuation + prompt task).
    /// - `AgentLauncher` is `@MainActor` — all state mutations
    ///   (`mergeOrAppend`, `flushTranscript`, `setGenerating`) happen on the
    ///   main actor via `await` hops from child tasks.
    /// - `stopAgent()` cancels via `backend.cancel()` which terminates the
    ///   entire subprocess, killing all parallel sessions. Their streams end,
    ///   child tasks complete, and the task group returns.
    /// - The generation gate holds one slot for the whole run — no gate change.
    private func runParallelExecutors(
        backend: AgentBackend,
        provider: AgentProvider,
        executorProfile: BackendProfile,
        plan: ACPIngestPlan,
        stateFilePath: String,
        sourceIDs: [String],
        systemPrompt: String,
        maxConcurrent: Int,
        executorModel: String?,
        plannerModel: String?
    ) async {
        let backend = backend                         // Sendable (AgentBackend: Sendable)
        let acp = backend as? ACPBackend             // Sendable (actor)
        let profile = executorProfile                // Sendable
        let allPageTitles = plan.allPageTitles      // [String] — Sendable
        // Fork from the planner session if the backend is ACP (Phase 3).
        let forkFrom = (acp != nil) ? plannerSessionHandle : nil
        // Set backend + a session reference so stopAgent() can cancel.
        self.backend = backend
        // #544 live progress: install the live-usage callback so usage_updates
        // from the parallel executors stream to the Activity window.
        await installLiveUsageCallback(on: backend)
        self.sessionHandle = forkFrom ?? SessionHandle(id: "parallel-executors")

        setGenerating(true)

        // Filter to source files that actually have assignments.
        let sourceFiles = plan.distinctSourceFiles.filter {
            !plan.assignments(forSource: $0).isEmpty
        }

        // Each child task returns (buffered events, session handle) or nil on
        // failure. The events are flushed to the main actor in batch by the
        // child task itself on turn-end (not collected at the end) — this gives
        // near-real-time transcript updates while keeping per-session event
        // ordering intact.
        struct ExecutorResult: Sendable {
            let session: SessionHandle?
        }

        await withTaskGroup(of: ExecutorResult.self) { group in
            var active = 0
            for sourceFile in sourceFiles {
                guard isRunning else { break }

                // Throttle: if at capacity, wait for one to finish before
                // dispatching the next.
                if active >= maxConcurrent {
                    if let result = await group.next() {
                        if let session = result.session {
                            await capturePhaseUsage(backend: backend, session: session, providerLabel: provider.label)
                            if let acp { await acp.closeSession(session) }
                            else { await backend.cancel(session) }
                        }
                        active -= 1
                    }
                }

                let assignments = plan.assignments(forSource: sourceFile)
                let executorPrompt = ACPIngestPrompts.executorPrompt(
                    stateFilePath: stateFilePath,
                    assignments: assignments,
                    allPageTitles: allPageTitles,
                    sourceIDs: sourceIDs)
                let phaseName = "executor[\(sourceFile)]"
                let workDir = profile.scratchDirectory?.path
                let parentHandle = forkFrom
                let sysPrompt = systemPrompt
                // per-stage-model-selection §4.6: every parallel executor is
                // the SAME stage (`.executor`) and shares one executor model
                // id. The planner's RESOLVED model is the baseline for the
                // fork-path `applyModelIfNeeded` (§4.5, HIGH #2 — NOT the stale
                // inherited modelsInfo.currentModelId).
                let stageExecutorModel = executorModel
                let stageBaseline = plannerModel

                group.addTask { [weak self] in
                    guard let self else { return ExecutorResult(session: nil) }

                    // --- Fork or create session (ACPBackend actor call) ---
                    let session: SessionHandle
                    if let parentHandle = parentHandle, let acp = acp {
                        DebugLog.agent("runACPIngest[\(phaseName)]: attempting fork from parent session")
                        if let forked = try? await acp.forkSession(from: parentHandle, cwd: workDir) {
                            DebugLog.agent("runACPIngest[\(phaseName)]: fork succeeded")
                            session = forked
                            // §4.5: apply the executor's stage model with the
                            // planner's RESOLVED model as the baseline.
                            let advertisedIds = await acp.availableModels(for: session).map(\.modelId)
                            await acp.applyModelIfNeeded(
                                session: session,
                                selectedModelId: stageExecutorModel,
                                stage: .executor,
                                baselineCurrentModelId: stageBaseline,
                                advertisedModelIds: advertisedIds)
                        } else {
                            DebugLog.agent("runACPIngest[\(phaseName)]: fork unsupported/failed, falling back to fresh start")
                            do {
                                session = try await backend.start(
                                    profile: profile,
                                    systemPrompt: sysPrompt,
                                    onExit: { status in
                                        DebugLog.agent("runACPIngest[\(phaseName)]: onExit status=\(status) (phase-tracked)")
                                    })
                            } catch {
                                DebugLog.agent("runACPIngest[\(phaseName)]: FAILED: \(error.localizedDescription)")
                                return ExecutorResult(session: nil)
                            }
                        }
                    } else {
                        DebugLog.agent("runACPIngest[\(phaseName)]: starting (no fork)")
                        do {
                            session = try await backend.start(
                                profile: profile,
                                systemPrompt: sysPrompt,
                                onExit: { status in
                                    DebugLog.agent("runACPIngest[\(phaseName)]: onExit status=\(status) (phase-tracked)")
                                })
                        } catch {
                            DebugLog.agent("runACPIngest[\(phaseName)]: FAILED: \(error.localizedDescription)")
                            return ExecutorResult(session: nil)
                        }
                    }

                    // --- Send prompt + drain stream ---
                    // Events are buffered per-session and flushed to the main
                    // actor as a batch on turn-end. This preserves the streaming
                    // merge logic (events within a batch are from one session, in
                    // order) while allowing concurrent agent processing.
                    DebugLog.agent("runACPIngest[\(phaseName)]: sending executor prompt")
                    let stream = await backend.send(TurnInput(userText: executorPrompt), into: session)
                    var batch: [AgentEvent] = []
                    for await event in stream {
                        batch.append(event)
                        if AgentEvent.endsGeneration(event) {
                            // Flush this session's accumulated batch to the main
                            // actor. mergeOrAppend + flushTranscript are
                            // @MainActor-isolated — the await hops to the main
                            // actor, serializing concurrent flushes.
                            await self.mergeParallelExecutorEvents(batch)
                            batch.removeAll(keepingCapacity: true)
                        }
                    }
                    // Flush any remaining events (e.g. turnFailed without
                    // .endsGeneration).
                    if !batch.isEmpty {
                        await self.mergeParallelExecutorEvents(batch)
                    }
                    DebugLog.agent("runACPIngest[\(phaseName)]: stream drained")
                    return ExecutorResult(session: session)
                }
                active += 1
            }

            // Drain remaining in-flight tasks.
            for await result in group {
                if let session = result.session, isRunning {
                    await capturePhaseUsage(backend: backend, session: session, providerLabel: provider.label)
                    if let acp { await acp.closeSession(session) }
                    else { await backend.cancel(session) }
                } else if let session = result.session {
                    // Not running (cancelled) — still clean up the session.
                    if let acp { await acp.closeSession(session) }
                    else { await backend.cancel(session) }
                }
                active -= 1
            }
        }

        setGenerating(false)
    }

    /// Merge a batch of events from one parallel executor session into the
    /// transcript. Called from a task-group child task via `await` (hops to the
    /// main actor). Within a batch, events are from a single session and in
    /// order, so the streaming-merge logic in `mergeOrAppend` works correctly.
    /// `flushTranscript` sends the new tail to the transcript sink for
    /// persistence.
    private func mergeParallelExecutorEvents(_ batch: [AgentEvent]) {
        lastActivityAt = Date()
        for event in batch {
            onAgentEvent?(event)
            mergeOrAppend(event)
        }
        flushTranscript()
    }

    /// Run one ACP phase on the given `backend`: start a session, send the
    /// prompt, drain to `.messageStop`/`.result`, then return the session
    /// (caller cancels). Sets `self.backend` to `backend` so `stopAgent()`, the
    /// watchdog, and `PermissionResolving` downcasts (`captureAndCacheModels`,
    /// `captureProcessID`, permission polling) target the phase's actual backend.
    /// The `onExit` closure is phase-tracking only — it logs but does NOT call
    /// `finish()`. That is the critical lifecycle invariant: `finish()` is called
    /// exactly once by `runACPIngestPlannerExecutors()` at the very end.
    ///
    /// Updates `sessionHandle` + `currentRunToken` so `stopAgent()` and the
    /// watchdog target the live phase. Returns `nil` if `backend.start` throws.
    ///
    /// Phase 3 (`plans/acp-session-efficiency.md` §4): when `forkFrom` is non-nil,
    /// the method tries `forkSession(from:forkFrom)` FIRST. If fork succeeds, the
    /// forked session inherits the parent's context — no `backend.start()` call
    /// is needed. If fork returns nil (unsupported), falls back to `backend.start()`
    /// (fresh session, current behavior).
    private func runPhase(
        backend: AgentBackend,
        profile: BackendProfile,
        systemPrompt: String,
        prompt: String,
        phaseName: String,
        stage: ACPIngestStage,
        baselineModelId: String?,
        forkFrom: SessionHandle? = nil
    ) async -> SessionHandle? {
        self.backend = backend
        // #544 live progress: install the live-usage callback on this phase's
        // backend so usage_updates stream to the Activity window during the
        // run. Idempotent for ACP backends; no-op for non-ACP / no-callback.
        await installLiveUsageCallback(on: backend)
        let runToken = UUID()
        do {
            // Phase 3: try to fork the planner session so the executor inherits
            // the planner's source-layout understanding without the reasoning
            // noise. If fork is unsupported (returns nil), fall back to a fresh
            // `backend.start()` — current pre-Phase-3 behavior.
            //
            // per-stage-model-selection §4.5 (HIGH #2): on the FORK path,
            // `ACPBackend.forkSession` inherits the planner's `modelsInfo`
            // WITHOUT calling `setModel` — so the inherited
            // `modelsInfo.currentModelId` is the agent's *advertised default*,
            // NOT the planner's *actually-applied* stage model. The resolver's
            // "already current → no-op" guard would misfire on the stale value,
            // so we explicitly pass `baselineModelId = plannerModel` (the
            // planner's RESOLVED stage model) into `applyModelIfNeeded`. On the
            // fresh-start path (`createSession`), the baseline is read FRESH
            // from `newSession` inside `ACPBackend.applyModelIfNeeded` (no need
            // for a parameter — `baselineModelId` is ignored for fresh starts).
            let session: SessionHandle
            if let parentHandle = forkFrom, let acp = backend as? ACPBackend {
                DebugLog.agent("runACPIngest[\(phaseName)]: attempting fork from parent session")
                let workingDir = profile.scratchDirectory?.path
                if let forked = try? await acp.forkSession(from: parentHandle, cwd: workingDir) {
                    DebugLog.agent("runACPIngest[\(phaseName)]: fork succeeded, using forked session")
                    session = forked
                    // §4.5: apply the executor's stage model with the planner's
                    // RESOLVED model as the baseline (NOT the stale inherited
                    // modelsInfo.currentModelId). The advertised model ids come
                    // from the forked session's inherited modelsInfo.
                    let advertisedIds = await acp.availableModels(for: session).map(\.modelId)
                    await acp.applyModelIfNeeded(
                        session: session,
                        selectedModelId: profile.providerHints[HintKey.acpSelectedModelId.rawValue],
                        stage: stage,
                        baselineCurrentModelId: baselineModelId,
                        advertisedModelIds: advertisedIds)
                } else {
                    DebugLog.agent("runACPIngest[\(phaseName)]: fork unsupported/failed, falling back to fresh start")
                    session = try await backend.start(
                        profile: profile,
                        systemPrompt: systemPrompt,
                        onExit: { status in
                            DebugLog.agent("runACPIngest[\(phaseName)]: onExit status=\(status) (phase-tracked)")
                        })
                }
            } else {
                DebugLog.agent("runACPIngest[\(phaseName)]: starting")
                session = try await backend.start(
                    profile: profile,
                    systemPrompt: systemPrompt,
                    onExit: { status in
                        // Phase tracker: does NOT call finish(). The orchestrator
                        // owns finish(); a per-phase exit is just telemetry.
                        DebugLog.agent("runACPIngest[\(phaseName)]: onExit status=\(status) (phase-tracked)")
                    })
            }
            sessionHandle = session
            currentRunToken = runToken

            setGenerating(true)
            let stream = await backend.send(TurnInput(userText: prompt), into: session)
            for await event in stream {
                lastActivityAt = Date()
                mergeOrAppend(event)
                if AgentEvent.endsGeneration(event) {
                    setGenerating(false)
                    flushTranscript()
                    // One-shot runs do NOT release the generation gate per turn —
                    // the gate is held across all phases and released by finish().
                }
            }
            DebugLog.agent("runACPIngest[\(phaseName)]: stream drained")
            return session
        } catch {
            DebugLog.agent("runACPIngest[\(phaseName)]: FAILED: \(error.localizedDescription)")
            return nil
        }
    }

    /// Fallback: single-session ACP ingest when the planner fails or produces no
    /// valid `plan.json`. Sends the original one-shot ingest prompt (with the
    /// "no sub-agents" instruction) in one session, then calls `finish()`. Keeps
    /// using the SAME collapsed (#604) resolution `runACPIngestPlannerExecutors`
    /// already resolved at its top — the fallback never re-resolves a backend
    /// (re-resolving would orphan the `ACPBackend` actor `run()` built).
    private func runACPIngestFallback(
        operation: WikiOperation,
        wikiRoot: String,
        scratch: URL,
        systemPrompt: String,
        makeCLIProfile: (WikiOperation) -> CLIProfile,
        backend: AgentBackend,
        provider: AgentProvider,
        providerHints: [String: String]
    ) async {
        currentIngestPhase = "fallback-single"
        let profile = BackendProfile(
            providerHints: providerHints,
            scratchDirectory: scratch,
            isReadOnly: false,
            cli: makeCLIProfile(operation), debugLogURL: debugFolderURL)
        var promptText = operation.prompt(wikiRoot: wikiRoot)
        promptText += "\n\nIMPORTANT: Do NOT dispatch sub-agents, background tasks, or async agents. Do NOT use sleep or ScheduleWakeup. Read all sources, process them, and write all wiki pages directly in THIS session — everything must complete before you stop."

        if let session = await runPhase(
            backend: backend,
            profile: profile,
            systemPrompt: systemPrompt,
            prompt: promptText,
            phaseName: "fallback-single",
            stage: .planner,             // semantically: the fallback IS a single-session ingest's "planner+executor+finalizer" — use .planner for the artifact
            baselineModelId: nil
        ) {
            captureAndCacheModels(provider: provider, session: session)
            captureProcessID(session: session)
            await capturePhaseUsage(backend: backend, session: session, providerLabel: provider.label)
            await backend.cancel(session)
            finish(status: 0)
        } else {
            finish(status: -1)
        }
    }

    // MARK: - Usage accumulation (#528 spike)

    /// Read per-session usage from an `ACPBackend` phase and merge it into
    /// `runTotalUsage`. MUST be called BEFORE `closeSession`/`cancel` — once
    /// the session is closed, the usage state is removed from the backend.
    /// Non-ACP backends are a silent no-op (no usage data available).
    ///
    /// `providerLabel` and `phaseModelId` are display metadata attached to the
    /// merged usage so the Activity window can show "Claude · Sonnet 4" etc.
    /// The backend's `sessionUsage(for:)` already sets `modelId` from the
    /// session's `currentModelId`; the provider label supplied here overrides
    /// nil (latest non-nil wins on merge).
    private func capturePhaseUsage(
        backend: AgentBackend,
        session: SessionHandle,
        providerLabel: String? = nil
    ) async {
        guard let acp = backend as? ACPBackend else { return }
        guard let usage = await acp.sessionUsage(for: session) else { return }
        // Attach the configured provider label (the backend doesn't know it).
        let enriched: SessionUsage
        if let providerLabel {
            enriched = SessionUsage(
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                totalTokens: usage.totalTokens,
                cachedReadTokens: usage.cachedReadTokens,
                thoughtTokens: usage.thoughtTokens,
                cost: usage.cost,
                currency: usage.currency,
                contextUsed: usage.contextUsed,
                contextSize: usage.contextSize,
                providerLabel: providerLabel,
                modelId: usage.modelId,
                modelName: usage.modelName,
                thinkingLevel: usage.thinkingLevel)
        } else {
            enriched = usage
        }
        runTotalUsage = SessionUsage.merging(runTotalUsage, enriched)
        DebugLog.agent("runTotalUsage: captured phase usage in=\(usage.inputTokens) out=\(usage.outputTokens) cost=\(usage.cost ?? 0) model=\(usage.modelId ?? "nil") provider=\(providerLabel ?? "nil")")
    }

    /// #544 live progress: install the live-usage callback on an ACP backend so
    /// every `usage_update` notification during the run is forwarded to the
    /// queue's Activity window. Enriches the raw backend snapshot (which
    /// carries token totals + context window + cost but no display metadata)
    /// with the configured provider label + the session's current model id
    /// before invoking `onLiveUsage`. The thinking-effort level is omitted
    /// (it's not exposed per-session publicly; the final `.usage` event at
    /// completion carries it). Non-ACP backends and runs with no `onLiveUsage`
    /// are a silent no-op.
    ///
    /// The enrichment reads `modelId` via an async hop to the actor
    /// (`currentModelId(for:)`) so it stays in sync with the latest
    /// `session/update`. `providerLabel` is known synchronously
    /// (`liveUsageProviderLabel`, set in `run(...)`).
    func installLiveUsageCallback(on backend: AgentBackend) async {
        guard let acp = backend as? ACPBackend, let onLiveUsage else { return }
        let providerLabel = liveUsageProviderLabel
        await acp.setLiveUsageCallback { handle, snapshot in
            Task { @MainActor in
                let modelId = await acp.currentModelId(for: handle)
                let enriched = SessionUsage(
                    inputTokens: snapshot.inputTokens,
                    outputTokens: snapshot.outputTokens,
                    totalTokens: snapshot.totalTokens,
                    cachedReadTokens: snapshot.cachedReadTokens,
                    thoughtTokens: snapshot.thoughtTokens,
                    cost: snapshot.cost,
                    currency: snapshot.currency,
                    contextUsed: snapshot.contextUsed,
                    contextSize: snapshot.contextSize,
                    providerLabel: providerLabel,
                    modelId: modelId,
                    thinkingLevel: nil)
                onLiveUsage(enriched)
            }
        }
    }

    /// Read the interactive session's cumulative usage after a turn finishes
    /// (the turn stream drained at `.messageStop`/`.result`) and emit the
    /// per-turn DELTA via `onInteractiveUsage`. MUST be called while the
    /// session is still alive (before `cancel`/`closeSession`) — the backend
    /// removes usage state on close.
    ///
    /// The backend's `sessionUsage(for:)` returns cumulative session totals
    /// (tokens across all turns). Accumulating those directly via
    /// `DailyUsage.add` would double-count on every turn after the first, so
    /// we emit `SessionUsage.delta(from: lastInteractiveUsageSnapshot, to:)`.
    /// Non-ACP backends or a missing/nil callback are silent no-ops (no usage
    /// data, nothing to forward). The configured `runProviderLabel` is
    /// attached so the daily summary can show "Claude" etc. — the backend
    /// doesn't know the provider.
    private func captureInteractiveUsage() async {
        guard onInteractiveUsage != nil else { return }
        guard let acp = backend as? ACPBackend, let session = sessionHandle else { return }
        guard let current = await acp.sessionUsage(for: session) else {
            DebugLog.agent("captureInteractiveUsage: no usage snapshot for session (nil)")
            return
        }
        // Attach the configured provider label (set at spawn-commit). The
        // backend's snapshot has providerLabel == nil (it doesn't know it).
        let enriched: SessionUsage
        if let providerLabel = runProviderLabel {
            enriched = SessionUsage(
                inputTokens: current.inputTokens,
                outputTokens: current.outputTokens,
                totalTokens: current.totalTokens,
                cachedReadTokens: current.cachedReadTokens,
                thoughtTokens: current.thoughtTokens,
                cost: current.cost,
                currency: current.currency,
                contextUsed: current.contextUsed,
                contextSize: current.contextSize,
                providerLabel: providerLabel,
                modelId: current.modelId,
                thinkingLevel: current.thinkingLevel)
        } else {
            enriched = current
        }
        let delta = SessionUsage.delta(from: lastInteractiveUsageSnapshot, to: enriched)
        lastInteractiveUsageSnapshot = enriched
        // Only forward when there's something to count — avoids noise on a
        // turn that produced no usage yet.
        guard delta.totalTokens > 0 || delta.cost != nil else { return }
        onInteractiveUsage?(delta)
        DebugLog.agent("captureInteractiveUsage: emitted delta in=\(delta.inputTokens) out=\(delta.outputTokens) cost=\(delta.cost ?? 0) model=\(delta.modelId ?? "nil") provider=\(delta.providerLabel ?? "nil") (cumulative session in=\(enriched.inputTokens) out=\(enriched.outputTokens))")
    }

    /// Resolve the path to a binary bundled in `Contents/Helpers/`, or nil if
    /// not present or not executable.
    ///
    /// `Bundle.url(forAuxiliaryExecutable:)` does NOT search `Contents/Helpers/`
    /// (it only looks in `Contents/MacOS/` and `Contents/Resources/`), so we
    /// construct the path manually. This is the fix for "bun not found on your
    /// path" — bun was correctly bundled in Helpers but the old API call never
    /// found it.
    public static nonisolated func bundledHelperPath(_ name: String) -> String? {
        let path = Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Helpers")
            .appendingPathComponent(name)
            .path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// A quick readiness probe for an agent provider — checks whether
    /// `provider.command[0]` is resolvable on the login-shell PATH (or is the
    /// bundled bun helper). Returns `nil` when ready, or a user-facing message
    /// explaining what to fix and pointing at Settings → Agents.
    ///
    /// PURE + injectable (the `resolveCommand` closure) so this can be called
    /// from a headless queue worker AND unit-tested without spawning a
    /// subprocess or a login-shell hop. Mirrors
    /// `ACPExtractionClient.resolveProvider`'s `resolveCommand` seam.
    ///
    /// `bun` is given special treatment: if the bundled bun helper exists
    /// (`Contents/Helpers/bun`), it is preferred over a PATH lookup — so the
    /// app works without a system-wide bun install. This matches
    /// `resolveACPProviderSpawn` and `ACPExtractionClient.resolveCommand`.
    ///
    /// #440 — replaces the cryptic `"bun: not found"` spawn error with
    /// actionable guidance. The returned message is shown verbatim in the
    /// Activity window (and carries a CTA to open Settings → Agents).
    public static nonisolated func readinessMessage(
        for provider: AgentProvider,
        resolveCommand: ((AgentProvider) -> [String]?)? = nil
    ) -> String? {
        let resolver = resolveCommand ?? { provider in
            guard let command = provider.command, let exe = command.first else {
                return nil
            }
            if exe == "bun", let bundled = Self.bundledHelperPath("bun") {
                return [bundled] + Array(command.dropFirst())
            }
            switch PathPreflight.resolveOnLoginShell(executable: ShellArgv.expandTilde(exe)) {
            case .found(let path):
                return [path] + Array(command.dropFirst())
            case .missing:
                return nil
            }
        }
        guard let command = provider.command, let exe = command.first else {
            return "Provider ‘\(provider.label)’ has no command configured. Open Settings → Agents to fix it."
        }
        guard resolver(provider) != nil else {
            // The binary wasn't found on the login-shell PATH (and no bundled
            // helper matched). Give the user the actionable guidance.
            var msg = "‘\(exe)’ was not found on your PATH. "
            if exe == "bun" {
                msg += "Install bun (bun.sh) or configure a different agent provider."
            } else {
                msg += "Install ‘\(exe)’ and make sure it is on your login shell PATH, or configure a different agent provider."
            }
            msg += " Open Settings → Agents to configure one."
            return msg
        }
        return nil
    }

    /// Resolve a `.acp` provider's spawn command (PATH-resolved, since the
    /// swift-acp SDK's `launch()` does no PATH lookup itself) + its
    /// Keychain-backed API key. `bun` prefers the helper bundled in
    /// `Contents/Helpers/` over a PATH lookup so the app works without a
    /// system-wide bun install. Sets `preflightError` and returns `nil` on
    /// failure — callers must bail out (`isRunning = false` +
    /// `releaseGenerationSlot()`) when this returns `nil`.
    func resolveACPProviderSpawn(_ provider: AgentProvider) -> (command: [String], apiKey: String?)? {
        guard let command = provider.command, let exe = command.first else {
            preflightError = "Provider ‘\(provider.label)’ has no command configured."
            return nil
        }
        let resolvedCommand: [String]
        if exe == "bun", let bundled = Self.bundledHelperPath("bun") {
            resolvedCommand = [bundled] + Array(command.dropFirst())
        } else {
            switch PathPreflight.resolveOnLoginShell(executable: ShellArgv.expandTilde(exe)) {
            case .found(let path):
                resolvedCommand = [path] + Array(command.dropFirst())
            case .missing(let reason):
                preflightError = reason
                return nil
            }
        }
        return (resolvedCommand, acpCredentialStore.apiKey(forProvider: provider.id))
    }

    /// Warning threshold for the "still working" check-in. When the agent has
    /// been idle (no notifications) for this long, the heartbeat logs a
    /// prominent "still working" check-in so the operator (and Console.app)
    /// can see that page creation is taking a long time. This does NOT kill
    /// the process — it's observability only. The idle stall was removed
    /// because ACP agents produce notifications for every activity, so a
    /// silent agent is either dead (caught by `sendPrompt` throwing) or
    /// genuinely working on something long.
    nonisolated static let watchdogWarningThreshold: TimeInterval = 120

    /// Watchdog heartbeat poll interval (seconds). The loop sleeps this long
    /// between checks.
    nonisolated static let watchdogPollInterval: TimeInterval = 3

    /// Heartbeat logger — observability only. The backend's `onExit` callback
    /// is the sole completion signal: it fires exactly once from
    /// `terminationHandler` and drives `finish()`.
    ///
    /// This loop logs phase, idle time, and elapsed time every `pollInterval`
    /// seconds, and emits a "still working" check-in when idle exceeds the
    /// warning threshold. It does NOT kill the process for inactivity — the
    /// idle stall was removed because ACP agents emit notifications for every
    /// activity (thinking, tool calls, sub-agent lifecycle), so a live agent
    /// is almost never truly idle. Process death is detected by `sendPrompt`
    /// throwing; the turn ceiling (30 min) is the remaining hard backstop.
    private func startCompletionWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.watchdogPollInterval))
                guard let self, self.isRunning else { return }
                let pid = self.currentProcessID ?? -1
                let idle = self.lastActivityAt.map { Date().timeIntervalSince($0) } ?? -1
                let phase = self.currentIngestPhase ?? "running"
                let elapsed = self.runStartedAt.map { Date().timeIntervalSince($0) } ?? -1
                DebugLog.agent(
                    "heartbeat pid=\(pid) phase=\(phase) isRunning=\(self.isRunning) "
                    + "events=\(self.events.count) idleSec=\(String(format: "%.1f", idle)) "
                    + "elapsedSec=\(String(format: "%.1f", elapsed))")

                // "Still working" check-in: idle has exceeded the warning
                // threshold. Page creation can legitimately take minutes of
                // reasoning — this assures the operator the process is alive
                // and names which phase is long.
                if idle >= Self.watchdogWarningThreshold && !self.watchdogHasWarned {
                    self.watchdogHasWarned = true
                    DebugLog.agent(
                        "heartbeat: CHECK-IN — phase=\(phase) has been quiet for \(Int(idle))s "
                        + "(elapsed \(Int(elapsed))s). Still working — page creation "
                        + "may take several minutes.")
                }
                // Reset the warning flag when activity resumes so the check-in
                // can fire again on the next long pause.
                if idle < Self.watchdogWarningThreshold {
                    self.watchdogHasWarned = false
                }
            }
        }
    }

    /// Resolve the `created_by`/`last_edited_by` provenance string stamped on
    /// agent-written pages (#397). Chat-driven writes get `chat:<chatID>` so the
    /// provenance links back to the originating conversation; standalone one-shot
    /// runs (ingest/lint/query) get `agent:<kind>`. The `WIKI_AUTHOR` env var
    /// carries this into `wikictl`, where an explicit `--author` flag overrides it.
    static func authorForRun(kind: WikiOperation.Kind, chatID: String?) -> String {
        if let chatID { return "\(ResourceKind.chat.linkPrefix!)\(chatID)" }
        return "agent:\(kind.rawValue)"
    }

    /// Start a stdin-backed query chat. The first user message is sent
    /// immediately after the process launches (via `sendInteractiveMessage`, which
    /// acquires the generation gate for that first turn). Later turns use
    /// `sendInteractiveMessage` as well — each acquires the gate for its duration.
    ///
    /// IMPORTANT: this function does NOT acquire the generation gate for the session.
    /// The process stays alive between turns without holding the gate, allowing
    /// another launcher's process to coexist. The gate is held only per-turn.
    ///
    /// - Parameter onTranscript: persistence sink (issue #119). Receives the
    ///   not-yet-persisted tail of `events` at each turn boundary and once more at
    ///   `finish()`. `nil` (the default) when the caller has no chat to persist
    ///   into (e.g. `store.startChat` failed) — the session simply runs unpersisted.
    public func startInteractiveQuery(
        firstMessage: String,
        firstMessageDisplay: String? = nil,
        stateMarkdown: String,
        wikiID: String,
        wikiRoot: String,
        systemPrompt: String,
        wikictlDirectory: String,
        chatID: String? = nil,
        firstMessagePrePersisted: Bool = false,
        historySeed: [AgentEvent] = [],
        onLock: @escaping @MainActor () -> Void,
        onUnlock: @escaping @MainActor @Sendable () -> Void,
        onTranscript: (@MainActor ([AgentEvent]) -> Void)? = nil,
        onSummary: (@MainActor (PageID, String) -> Void)? = nil
    ) async {
        // No gate acquisition here — the interactive session does NOT hold the gate
        // for its lifetime, only per-turn (via sendInteractiveMessage). Two sessions
        // can coexist as processes; only one generates at a time via the gate.

        // Preflight (no gate held — early returns here don't need gate release).
        resetRunArtifacts()
        // Seed `events` with the persisted chat history so a continued chat
        // shows its full transcript during the live session (the view sources
        // from `launcher.events` when `isLiveChat`). `persistedEventCount` is
        // set so `flushTranscript` never re-persisted the already-stored rows.
        if !historySeed.isEmpty {
            events = historySeed
            persistedEventCount = historySeed.count
        }
        DebugLog.agent("startInteractiveQuery: enter firstMsg=\"\(firstMessage.prefix(80))\" chatID=\(chatID ?? "nil") wikiID=\(wikiID) historySeed=\(historySeed.count)")
        // Consumed by the first `sendInteractiveMessage` to skip re-persisting
        // the user message the model already seeded at chat creation.
        self.firstMessagePrePersisted = firstMessagePrePersisted

        // Resolved fresh at spawn time.
        let dir = containerDirectory ?? (try? DatabaseLocation.appGroupContainerDirectory()) ?? FileManager.default.temporaryDirectory

        // The chat's permission policy (default yolo). The ACP agent spawn is
        // threaded into providerHints below.
        //
        // #607: chat reads its OWN `chatPermissionMode` key — independent of
        // ingest/lint. #606: chat is interactive, so no auto-reject budget —
        // the UI chip is the release valve, preserving the prior indefinite-
        // suspend behavior. (`nil` budget ⇒ no timer on `deferPermission`.)
        // #609: chat uses the interactive 1800s ceiling — long reasoning
        // chains are legitimate in a user-attended session, and the user can
        // cancel via the UI chip.
        let policy: PermissionPolicy = resolvePermissionMode(.chat)
        let permissionBudget: Duration? = nil
        let turnCeiling = TurnLivenessPolicy.ceiling(for: .chat)
        DebugLog.agent("startInteractiveQuery: permissionPolicy=\(policy) budget=nil (interactive) ceiling=\(turnCeiling)s")

        // #324: the launcher reads `agent-providers.json` and picks the
        // default (or selected) provider. The app is ACP-only.
        //
        // per-stage-model-selection (#704 removed): there is no per-operation
        // provider pin anymore — chat resolves ONE provider via
        // `selectedProvider()`. Per-stage MODEL selection is an ingest-only
        // concern (planner / executor / finalizer); chat is always a single
        // session with one model.
        let provider = providersConfig().selectedProvider()
        let resolvedSelectedModel = providersConfig().selectedModelId(forProvider: provider.id)
        DebugLog.agent("startInteractiveQuery: provider=\(provider.id) selectedModel=\(resolvedSelectedModel ?? "nil")")

        // Refuse to spawn without an explicit `selectedModelId`. Mirrors the
        // ingest path's `SpawnModelGuard` guard (now at the top of
        // `runACPIngestPlannerExecutors` after #604 collapsed per-stage routing).
        // Without this, chat silently falls through to the ACP subprocess's
        // first-listed upstream model. See `tmp/ingestion-stall-diagnosis.md`
        // and `SpawnModelGuard.swift`.
        //
        // State contract: this early-return site is in the PREFLIGHT section
        // (the comment at the top of this function — "no gate held — early
        // returns here don't need gate release"). Mirror `resolveACPProviderSpawn`'s
        // existing failure two lines below: set `preflightError` and bare
        // `return`. Do NOT touch `isRunning` or `releaseGenerationSlot()` —
        // neither is held here (unlike the one-shot `run()` path's preflight
        // at line ~890, which DOES hold both, and that's why that path does
        // the cleanup). Placed BEFORE the PATH-preflight so the missing-model
        // message wins when both are wrong (we want the user to fix the model
        // selection even before we attempt to resolve the executable).
        if let msg = SpawnModelGuard.validate(provider: provider, modelId: resolvedSelectedModel) {
            preflightError = msg
            return
        }

        self.backend = resolveBackend(policy, permissionBudget, turnCeiling)

        // Resolve the provider's spawn command (PATH-resolved) + the
        // Keychain-backed API key (keyed by provider id).
        guard let spawn = resolveACPProviderSpawn(provider) else {
            DebugLog.agent("startInteractiveQuery: ACP exe missing — \(preflightError ?? "?")")
            return
        }
        let resolvedACPCommand = spawn.command
        let acpAPIKey = spawn.apiKey
        let resolvedPath = resolvedACPCommand[0]
        preflightError = nil

        guard let scratch = makeScratchDirectory(id: chatID) else {
            preflightError = "Could not create a scratch working directory for the agent."
            return
        }

        let stateFilePath: String
        do {
            stateFilePath = try AgentStaging.stageStateFile(stateMarkdown, in: scratch)
        } catch {
            preflightError = "Could not stage the agent's inputs: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: scratch)
            return
        }

        let operation = WikiOperation.queryChat(
            stateFilePath: stateFilePath)
        // Chats are always write-capable now — use the write (opt-in) sandbox
        // behavior (which may itself be `nil`, i.e. fail-open un-sandboxed),
        // resolved the same way as Ingest/Lint. The read-only seatbelt
        // (SandboxProfile.readOnlyInvocation) is retained in-tree but no longer
        // wired to the chat path.
        let pdf2mdScriptPath = resolvePdf2mdScriptPath()
        let sandbox = resolveSandboxInvocation(
            wikiID: wikiID, scratch: scratch, dir: dir, pdf2mdScriptPath: pdf2mdScriptPath)
        if sandbox != nil { createSandboxTmpDir(in: scratch) }

        // RESERVE per-run metadata. isRunning will be set at spawn commit below
        // (after backend.start succeeds). runStartedAt is set inside
        // setGenerating(true) at spawn commit.
        let now = Date()
        runningKind = operation.kind
        lastActivityAt = now
        runCommitedAt = now
        runProviderLabel = provider.id
        openLogFiles(in: scratch)
        // SPAWN COMMIT: a query chat never ingests, so the agent-phase flag
        // is empty — clearing any stale value (mirrors `run`'s spawn-commit).
        self.ingestingSourceIDs = []
        onLock()
        onUnlockHandler = onUnlock
        // Install the transcript sink alongside the per-turn callback (issue #119):
        // both are per-session callbacks assigned once resetRunArtifacts() has run
        // (which clears any stale sink from a prior run).
        transcriptSink = onTranscript
        summarySink = onSummary
        // D2: record the chat row this live session is writing to. This is the
        // source-of-truth switch for ChatView — when it matches a tab's
        // chatID, that tab renders `launcher.events` (streaming) instead of the
        // persisted store. Set here (after resetRunArtifacts cleared any prior
        // value) so the flip is live from the first streamed token.
        activeChatID = chatID
        // #681: the chat's debug-folder path is now DERIVED from chatID at read
        // time (`debugFolderURL(forChat:)` resolves `<chatULID>/runs/<latest>/`),
        // so no in-memory map needs to be captured here. The pure function works
        // for in-progress, just-finished, and reopened-from-history chats alike —
        // including after an app restart.
        // Pre-display the user's message so it appears instantly — don't make
        // the user wait ~4s for backend.start (spawn + initialize + newSession)
        // before seeing their own text. `sendInteractiveMessage` will skip its
        // own append when `firstMessagePreDisplayed` is set.
        let preDisplay = (firstMessageDisplay ?? firstMessage)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !preDisplay.isEmpty {
            events.append(.userText(preDisplay))
            eventTimestamps.append(Date())
            firstMessagePreDisplayed = true
        }
        // NOTE: do NOT `setGenerating(true)` here. The first turn's transition is
        // owned by `sendInteractiveMessage(firstMessage)` below (after the gate is
        // acquired). If we set it here, `sendInteractiveMessage`'s gate-guard would
        // see `isGenerating == true` and bail — claude would block on stdin forever.

        // Build the backend profile (`ACPBackend` owns the spawn + session).
        let cli = CLIProfile(
            operation: operation,
            wikiRoot: wikiRoot,
            wikiID: wikiID,
            wikictlDirectory: wikictlDirectory,
            onStdoutChunk: { [weak self] chunk in
                Task { @MainActor [weak self] in self?.ingestRawStdout(chunk) }
            },
            onStderrChunk: { [weak self] chunk in
                Task { @MainActor [weak self] in self?.ingestStderr(chunk) }
            })
        let profile = BackendProfile(
            providerHints: {
                var hints = AgentBackendFactory.providerHints(
                    provider: provider,
                    resolvedCommand: resolvedACPCommand,
                    apiKey: acpAPIKey,
                    selectedModelId: providersConfig().selectedModelId(forProvider: provider.id))
                // #397: chat-driven writes carry `chat:<chatID>` as their author
                // provenance so created_by/last_edited_by points back to the
                // originating conversation (resolvable via [[chat:…]]). An explicit
                // `--author` on `wikictl page add` overrides this.
                if let chatID {
                    hints[HintKey.env("WIKI_AUTHOR")] = "\(ResourceKind.chat.linkPrefix!)\(chatID)"
                }
                return hints
            }(),
            scratchDirectory: scratch,
            isReadOnly: false,
            cli: cli,
            debugLogURL: debugFolderURL)
        DebugLog.agent("startInteractiveQuery: profile built providerHints keys=\(profile.providerHints.keys.sorted()) scratch=\(scratch.lastPathComponent)")

        do {
            DebugLog.agent("startInteractiveQuery: backend.start provider=\(provider.id) exe=\(resolvedPath) args=\(provider.command ?? [])")
            let runToken = UUID()
            let session = try await backend.start(
                profile: profile,
                systemPrompt: systemPrompt,
                onExit: { [weak self] status in
                    Task { @MainActor [weak self] in
                        // Only finish if THIS session is still current — a stale
                        // onExit (a prior session terminating after a new one
                        // started, e.g. D3's continueChat takeover:
                        // stopAgent → startInteractiveQuery) must not tear down
                        // the new session.
                        guard let self, self.currentRunToken == runToken else { return }
                        self.finish(status: Int32(status))
                    }
                })
            sessionHandle = session
            currentRunToken = runToken
            // SPAWN COMMIT: process is alive. isRunning = true (process alive across turns).
            isInteractiveSession = true
            isRunning = true
            DebugLog.agent("startInteractiveQuery: spawn-commit session=\(session.id) isInteractive=true")
            // #329: cache the agent's advertised models per-provider for the
            // picker. Done here (after spawn commit) so the session record is
            // populated; it runs as a detached task and never blocks the first
            // turn.
            captureAndCacheModels(provider: provider, session: session)
            captureProcessID(session: session)
            // #566: mirror the agent-advertised config options (e.g. the
            // `thought_level` select) so the chat toolbar can render a
            // "Thinking" dropdown. No-op for agents that advertise none.
            captureThinkingOption(session: session)
            DebugLog.agent("startInteractiveQuery: spawned")
            // Start the first turn — this acquires the generation gate for turn 1.
            // Compose the full task prompt (chat.md, write rules, citation rules,
            // don't-rediscover directive) + the user's message — same composition
            // the non-interactive path uses via `operation.prompt(wikiRoot:)`.
            // Without this, the first turn is the raw user message with no task
            // steering, and the agent defaults to its built-in behavior (e.g.
            // websearch before wikictl). The `displayText` stays as the user's
            // raw message so the transcript shows what the user typed.
            let taskPrompt = operation.prompt(wikiRoot: wikiRoot)
            let composedFirstMessage = "\(taskPrompt)\n\n# USER MESSAGE\n\(firstMessage)"
            sendInteractiveMessage(composedFirstMessage, displayText: firstMessageDisplay ?? firstMessage)
            // Mirror `run()`: arm the completion watchdog so a process that exits
            // without a reconciling `onExit` still clears `isRunning`.
            // Interactive sessions stay alive between turns; the watchdog only acts
            // when the OS reports the process gone, so a live idle session is safe.
            startCompletionWatchdog()
        } catch {
            DebugLog.agent("startInteractiveQuery: backend.start FAILED provider=\(provider.id): \(error)")
            preflightError = "Failed to launch claude: \(error.localizedDescription)"
            closeLogFiles()
            try? FileManager.default.removeItem(at: scratch)
            isInteractiveSession = false
            isRunning = false
            runningKind = nil
            currentProcessID = nil
            lastActivityAt = Date()
            releaseRunLifecycle()
            // Clean up the pre-displayed user text (backend never started).
            firstMessagePreDisplayed = false
            // Cancel any queued send task (shouldn't exist yet, but guard for safety).
            interactiveSendTask?.cancel()
            interactiveSendTask = nil
            isAwaitingGenerationSlot = false
            // No gate to release — we never acquired it for the session.
        }
    }

    /// Send one user turn to the active interactive query session.
    ///
    /// This function acquires the shared generation gate for the duration of the turn
    /// (from the write to stdin until the agent emits `messageStop`/`result`). The
    /// acquisition is ASYNC and may wait if another launcher is currently generating.
    /// While waiting, `isAwaitingGenerationSlot` is `true` so the UI can show a hint.
    public func sendInteractiveMessage(_ message: String, displayText: String? = nil) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.shouldSendMessage(
            isRunning: isRunning,
            isInteractiveSession: isInteractiveSession,
            isGenerating: isGenerating,
            isAwaitingGenerationSlot: isAwaitingGenerationSlot,
            message: trimmed
        ) else {
            DebugLog.agent("sendInteractiveMessage: GUARD bail (isRunning=\(isRunning) isInteractive=\(isInteractiveSession) isGenerating=\(isGenerating) isAwaitingSlot=\(isAwaitingGenerationSlot) empty=\(trimmed.isEmpty)")
            return
        }
        DebugLog.agent("sendInteractiveMessage: queuing turn chars=\(trimmed.count) displayChars=\((displayText ?? trimmed).count)")

        // Signal that we're waiting for the gate. The UI shows a hint; canSend = false.
        isAwaitingGenerationSlot = true

        // Spawn a cancellable task that acquires the generation gate, then sends
        // the turn to the backend and consumes the per-turn stream. Stored so
        // stopAgent()/finish() can cancel a pending wait.
        let backend = self.backend
        let session = self.sessionHandle
        interactiveSendTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let ok = await self.awaitGenerationSlot()
            DebugLog.agent("sendInteractiveMessage: gate acquire ok=\(ok)")
            self.isAwaitingGenerationSlot = false
            guard ok, !Task.isCancelled, self.isInteractiveSession,
                  let session else {
                // Acquired the gate then bailed (cancelled or session ended) — give
                // it back so a queued peer isn't stranded.
                if ok { self.releaseGenerationSlot() }
                DebugLog.agent("sendInteractiveMessage: bail after gate (cancelled=\(Task.isCancelled) isInteractive=\(self.isInteractiveSession) session=\(session != nil)")
                return
            }
            // Display the user's message (or the displayText override — D3's
            // continue path sends a preamble to the agent but shows the user's
            // actual message in the transcript). The full `trimmed` message
            // (preamble) is sent to the backend below.
            let visible = (displayText ?? trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
            if self.firstMessagePreDisplayed {
                // Already appended by `startInteractiveQuery` before backend.start
                // — skip the double-append but keep the persisted-count logic below.
                self.firstMessagePreDisplayed = false
            } else {
                self.events.append(.userText(visible))
                self.eventTimestamps.append(Date())
            }
            // The fresh-chat path seeds this first user message at chat-creation
            // time (WikiStoreModel.startChat). Mark it flushed so the next
            // flushTranscript() doesn't double-insert it — the row already exists
            // at seq 0; it stays in `events` only for live transcript display.
            if self.firstMessagePrePersisted {
                self.persistedEventCount = self.events.count
                self.firstMessagePrePersisted = false
            }
            self.setGenerating(true)    // UI flag: ChatView banner + send guard
            DebugLog.agent("sendInteractiveMessage: turn start (setGenerating=true)")
            self.lastActivityAt = Date()
            // Send the turn and consume the per-turn stream. The backend writes
            // the NDJSON line to stdin; the stream finishes at `.messageStop`
            // (turn boundary) or `.result` (session end).
            let stream = await backend.send(
                TurnInput(userText: trimmed), into: session)
            for await event in stream {
                self.lastActivityAt = Date()
                self.mergeOrAppend(event)
                if AgentEvent.endsGeneration(event) {
                    self.setGenerating(false)
                    self.flushTranscript()
                    self.generateChatSummary()
                    // Capture the per-turn usage delta and forward it to the
                    // menu bar tracker (if wired). Reads the backend's
                    // cumulative session snapshot and emits the delta vs the
                    // last turn, so the daily total doesn't double-count.
                    await self.captureInteractiveUsage()
                    DebugLog.agent("sendInteractiveMessage: turn end (endsGeneration) → flushTranscript")
                    if Self.releasesGenerationSlotPerTurn(
                        isInteractiveSession: self.isInteractiveSession) {
                        self.releaseGenerationSlot()
                        DebugLog.agent("sendInteractiveMessage: generation slot released (interactive)")
                    }
                }
            }
        }
    }

    /// Pure decision: whether `sendInteractiveMessage` would actually start a turn
    /// (vs. bail on a guard). Extracted so the gate logic is unit-testable without a
    /// live process (the full send path needs a spawned claude + stdin).
    ///
    /// A turn may start iff: a process is alive (`isRunning`), it's an interactive
    /// (stdin-backed) session, the text isn't blank, the agent is NOT already
    /// generating a response, and we're NOT already waiting to acquire the gate. The
    /// last condition prevents double-queueing — there can be at most one pending
    /// send task at a time.
    ///
    /// Regression guard: `startInteractiveQuery` must NOT pre-set `isGenerating`
    /// before calling `sendInteractiveMessage(firstMessage)` — the first send runs
    /// with `isGenerating == false`, so it passes this gate and the message lands.
    /// If that ordering regresses, the first message is dropped and claude blocks
    /// on stdin forever (events=0, perpetual spinner).
    static func shouldSendMessage(
        isRunning: Bool,
        isInteractiveSession: Bool,
        isGenerating: Bool,
        isAwaitingGenerationSlot: Bool,
        message: String
    ) -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return isRunning && isInteractiveSession && !trimmed.isEmpty
            && !isGenerating && !isAwaitingGenerationSlot
    }

    /// Stop ONLY the agent process. Does NOT touch a running pdf2md
    /// conversion — a standalone extract running alongside a query continues.
    /// Also cancels any in-flight send task (generation gate wait).
    public func stopAgent() {
        DebugLog.agent(
            "stopAgent() requested: isRunning=\(isRunning) "
            + "session=\(sessionHandle != nil) "
            + "pid=\(currentProcessID ?? -1)")
        // Cancel any pending send (gate wait) so it doesn't fire after the session ends.
        interactiveSendTask?.cancel()
        interactiveSendTask = nil
        isAwaitingGenerationSlot = false
        // Ask the backend to cancel the session (closes stdin + terminates the
        // process). Fire-and-forget: the onExit callback drives finish() — but
        // we also call finish(-1) synchronously below so the UI tears down
        // immediately without waiting for the async cancel to land.
        if let session = sessionHandle {
            let backend = self.backend
            Task { await backend.cancel(session) }
        }
        // Phase 3: if the planner session is still alive (kept open as a fork
        // source during the executor phase), close it. `cancel` on the current
        // session terminates the subprocess, which kills all sessions anyway,
        // but this prevents the plannerSessionHandle from dangling after teardown.
        plannerSessionHandle = nil
        if isRunning {
            finish(status: -1)  // -1 sentinel = user-cancelled / forced teardown
        }
    }

    /// Terminate EVERYTHING — extraction + agent process. Convenience for the
    /// few surfaces that don't distinguish (e.g. app termination cleanup).
    /// Extraction is now managed by `QueueActivityTracker` + `QueueEngine` —
    /// `stop()` only needs to stop the agent.
    func stop() {
        stopAgent()
    }

    /// End the interactive query session (if any) and clear the visible
    /// transcript so the page returns to its empty state; the next send spawns a
    /// fresh claude process with a clean context. History is already persisted
    /// incrementally (and stopAgent → finish flushes the tail), so nothing is lost.
    /// Guarded so it can never kill a non-query run (ingest/lint) streaming into
    /// this launcher, and it does NOT touch extractionLog/extractionPID — a
    /// concurrently running pdf2md extraction is untouched.
    public func startNewChat() {
        if isRunning && runningKind != .query { return }
        if isRunning {
            // stopAgent() is a safe no-op when idle (PR #198); here it terminates
            // the live query process and triggers finish() → final flush + sink clear.
            stopAgent()
        }
        events = []
        eventTimestamps = []
        isStreamingAssistantRow = false
        isStreamingThinkingRow = false
        rawTranscript = ""
        stderr = ""
        exitStatus = nil
        preflightError = nil
        transcriptSink = nil
        persistedEventCount = 0
        // state (.newChat draft → .chat(id)) is handled by the caller (ChatView)
        // via store.retargetTab, since the launcher does not
        // know which tab it lives in.
        activeChatID = nil
    }

    // MARK: - Transcript persistence (issue #119)

    /// Pure tail computation: the slice of `events` not yet handed to the sink.
    /// Extracted so the cursor arithmetic is unit-testable without driving a live
    /// launcher. Mirrors the `>=` guard in `flushTranscript()` — returns empty when
    /// nothing new has arrived since `persistedCount`.
    static func unflushedTail(events: [AgentEvent], persistedCount: Int) -> [AgentEvent] {
        guard persistedCount < events.count else { return [] }
        return Array(events[persistedCount...])
    }

    /// Extract the first assistant-text sentence from the event stream (issue
    /// #411). Iterates `events` to find the first `.assistantText(String)` or
    /// `.result(isError:text:)` with non-empty text, then extracts the first
    /// sentence via `ChatSummary.summaryExtract(from:maxLength:)`. Returns `nil`
    /// if no suitable event is found or the extract is empty. Static so the
    /// event-selection logic is unit-testable without driving a live launcher.
    nonisolated static func firstSummaryText(from events: [AgentEvent]) -> String? {
        for event in events {
            let text: String
            switch event {
            case .assistantText(let s):
                text = s
            case .result(_, let s):
                text = s
            default:
                continue
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let extract = ChatSummary.summaryExtract(from: text)
            guard !extract.isEmpty else { continue }
            return extract
        }
        return nil
    }

    /// Generate the one-line chat summary from `events` and hand it to
    /// `summarySink` (issue #411). Called once in `finish()` after the final
    /// `flushTranscript()` and before `activeChatID = nil`. No-op when no
    /// summary can be extracted or no sink/chatID is set.
    private func generateChatSummary() {
        guard !summaryGenerated else { return }
        guard let extracted = Self.firstSummaryText(from: events),
              let chatID = activeChatID else { return }
        summaryGenerated = true
        summarySink?(PageID(rawValue: chatID), extracted)
    }

    /// Hand the not-yet-persisted tail of `events` to `transcriptSink`, if any, and
    /// advance the cursor. Filtering to persistable events is the model's job
    /// (`WikiStoreModel.appendChatEvents` filters via `AgentEvent.isPersistable`) —
    /// the tail is passed whole. No-op when nothing new has arrived or no sink is
    /// installed.
    private func flushTranscript() {
        guard persistedEventCount < events.count else { return }
        let tail = Self.unflushedTail(events: events, persistedCount: persistedEventCount)
        persistedEventCount = events.count
        // Diagnostic (issue: "page attached → no response"): summarize what the
        // turn actually produced so a repro tells us empty/tool-only vs. a live
        // render bug. Logs the tail's event-kind histogram + total assistant
        // text length.
        var kinds: [String: Int] = [:]
        var assistantChars = 0
        for e in tail {
            let k: String
            switch e {
            case .userText: k = "userText"
            case .assistantText(let t): k = "assistantText"; assistantChars += t.count
            case .assistantTextDelta: k = "assistantTextDelta"
            case .toolUse: k = "toolUse"
            case .toolResult: k = "toolResult"
            case .subagent: k = "subagent"
            case .result(_, let t): k = "result"; assistantChars += t.count
            case .systemInit: k = "systemInit"
            case .messageStop: k = "messageStop"
            case .turnFailed: k = "turnFailed"
            case .thinking: k = "thinking"
            case .thinkingDelta: k = "thinkingDelta"
            case .raw: k = "raw"
            }
            kinds[k, default: 0] += 1
        }
        DebugLog.agent("flushTranscript: tail=\(tail.count) assistantChars=\(assistantChars) kinds=\(kinds)")
        transcriptSink?(tail)
    }

    // MARK: - Stream ingestion (main actor)

    /// Mirror a raw stdout chunk to `rawTranscript` + `run.jsonl`. Called from
    /// the backend's `onStdoutChunk` callback (which fires on the pipe's
    /// background queue, hopped to the main actor). The line-splitting, parsing,
    /// and event routing now happen in the backend + the per-turn `for await`
    /// consumer — this method only owns the raw-bytes mirror.
    private func ingestRawStdout(_ chunk: String) {
        lastActivityAt = Date()
        rawTranscript.append(chunk)
        writeLog(chunk, to: logHandle)
    }

    /// Route one parsed event into `events`: either grow the in-progress streamed
    /// assistant row in place, or append a new row (the existing, non-streaming
    /// behavior). This is what lets `ChatWebView` patch a live row
    /// instead of only ever appending (issue #121).
    private func mergeOrAppend(_ event: AgentEvent) {
        let now = Date()
        switch event {
        case .assistantTextDelta(let delta):
            if isStreamingAssistantRow, case .assistantText(let existing) = events.last {
                events[events.count - 1] = .assistantText(existing + delta)
                // Keep the original timestamp — the row's "first seen" time.
            } else {
                events.append(.assistantText(delta))
                eventTimestamps.append(now)
                isStreamingAssistantRow = true
            }

        case .assistantText:
            // The complete/final text for a block already being streamed — replace
            // the in-progress row with the authoritative full text rather than
            // appending a duplicate. Any other `.assistantText` (no streaming in
            // flight, e.g. a run without `--include-partial-messages`) appends as
            // it always has.
            if isStreamingAssistantRow, case .assistantText = events.last {
                events[events.count - 1] = event
                // Update to the finalization time — the turn is complete.
                eventTimestamps[eventTimestamps.count - 1] = now
            } else {
                events.append(event)
                eventTimestamps.append(now)
            }
            isStreamingAssistantRow = false

        case .thinkingDelta(let delta):
            // Streamed reasoning chunk — coalesce into the in-progress `.thinking`
            // row, mirroring `.assistantTextDelta` → `.assistantText` (issue #391).
            if isStreamingThinkingRow, case .thinking(let existing) = events.last {
                events[events.count - 1] = .thinking(existing + delta)
            } else {
                events.append(.thinking(delta))
                eventTimestamps.append(now)
                isStreamingThinkingRow = true
            }

        case .thinking:
            // The complete/final thought text for a block already being streamed —
            // replace with the authoritative full text. Mirrors `.assistantText`.
            if isStreamingThinkingRow, case .thinking = events.last {
                events[events.count - 1] = event
                eventTimestamps[eventTimestamps.count - 1] = now
            } else {
                events.append(event)
                eventTimestamps.append(now)
            }
            isStreamingThinkingRow = false

        default:
            events.append(event)
            eventTimestamps.append(now)
            isStreamingAssistantRow = false
            isStreamingThinkingRow = false
        }

        // Forward to the queue's per-item transcript callback (Activity window).
        // Fired on every event so the tracker gets a live, complete transcript.
        if let onAgentEvent {
            onAgentEvent(event)
        } else {
            DebugLog.agent("mergeOrAppend: onAgentEvent is nil — event not forwarded to tracker")
        }
    }

    /// Append a raw stderr chunk: surface it in `stderr`, mirror to the transcript +
    /// `run.stderr.log`.
    private func ingestStderr(_ chunk: String) {
        lastActivityAt = Date()
        stderr.append(chunk)
        rawTranscript.append(chunk)
        writeLog(chunk, to: stderrLogHandle)
    }

    /// Record the exit status and tear down. Guarded on `isRunning` so it runs
    /// EXACTLY ONCE per run: `stopAgent()` and the `onExit` callback may both
    /// race to call it. The backend drains any trailing partial line before the
    /// stream finishes, so no line-buffer drain is needed here (the old
    /// `stdoutLineBuffer` drain moved to the backend's terminationHandler).
    private func finish(status: Int32) {
        guard isRunning else {
            DebugLog.agent("finish: ignored (already torn down) status=\(status)")
            return
        }
        DebugLog.agent("finish: status=\(status) events=\(events.count) activeChatID=\(activeChatID ?? "nil")")
        watchdogTask?.cancel()
        watchdogTask = nil
        watchdogHasWarned = false
        // Session over: flush any remaining tail (a killed/died session still
        // persists its last events) THEN detach the sink — no further writes.
        flushTranscript()
        // Generate and persist the one-line chat summary (issue #411). Must
        // run AFTER flushTranscript() (so the transcript is committed) and
        // BEFORE activeChatID = nil (so the chat ID is still available).
        generateChatSummary()
        transcriptSink = nil
        summarySink = nil
        onAgentEvent = nil
        // #544 live progress: detach the live-usage callback after the run ends,
        // mirroring onAgentEvent. The Activity window stops receiving updates
        // here; the final cumulative totals arrive via the AppQueueIngestion
        // provider's onUsagecallback.
        onLiveUsage = nil
        liveUsageProviderLabel = nil
        // #608: detach the pending-permission callback after the run ends,
        // mirroring onAgentEvent/onLiveUsage. Emit a final `nil` first so the
        // Activity window's yellow row clears on terminal state — the
        // continuation may have resolved via auto-reject timeout (which fires
        // `refreshPendingPermissions()` and already emits), but a terminal
        // state arriving first (cancelled mid-prompt, hard process death)
        // needs this explicit clear or the row lingers.
        onPendingPermission?(nil)
        onPendingPermission = nil
        // Interactive usage tracking: detach the callback and clear the
        // snapshot baseline so a new run starts fresh (no stale delta base).
        onInteractiveUsage = nil
        lastInteractiveUsageSnapshot = nil
        // D2 flip-timing: clear activeChatID AFTER flushTranscript() has
        // committed the final tail.
        // transcriptSink?(tail) which runs store.appendChatEvents on the main
        // actor before returning. By the time we reach this line, the persisted
        // chatMessages(chatID:) and the in-memory events[] agree, so flipping the
        // view's source-of-truth from "live" to "persisted" cannot truncate.
        // (If we cleared it before the flush, the view would re-source from the
        // store with the last turn's events still missing → truncated flash.)
        activeChatID = nil
        closeLogFiles()
        // Write the verbose debug summary (summary.json) capturing provider,
        // model, kind, duration, and total usage. No-op when no debug folder
        // was created for this run. The model id is read from the backend's
        // last session (a detached task so finish doesn't block on the actor).
        writeDebugSummary(finishedAt: Date(), status: status)
        exitStatus = status
        // Clear process-alive state.
        isRunning = false
        isInteractiveSession = false
        runningKind = nil
        sessionHandle = nil
        plannerSessionHandle = nil
        currentProcessID = nil
        ingestingSourceIDs = []
        // Cancel any in-flight send task (gate wait or stream consumer). Clear the
        // awaiting flag so the UI stops showing the "Waiting…" hint.
        interactiveSendTask?.cancel()
        interactiveSendTask = nil
        isAwaitingGenerationSlot = false
        setGenerating(false)
        lastActivityAt = Date()
        // Slice 2: stop the pending-permission poller and clear surfaced pending
        // (the session is ending). The backend's `cancel` already drained any
        // in-flight always-ask continuations.
        stopPendingPermissionPoller()
        pendingPermissions = []
        // Release the agent-run lifecycle (decrement `store.agentRunCount`)
        // from here — NOT from the `onExit` callback — so EVERY completion
        // path decrements it.
        releaseRunLifecycle()
        // Release the generation gate if still held. For one-shot runs this is the
        // primary release path (they hold the gate through finish). For interactive
        // sessions this covers the edge case where the process died MID-TURN (the
        // normal per-turn release via the stream's endsGeneration didn't fire). The
        // idempotent `releaseGenerationSlot()` guard makes this safe in all paths.
        releaseGenerationSlot()
    }

    /// Release the agent-run lifecycle closure exactly once. Idempotent: clearing the stored
    /// handler makes repeated calls (from `finish()`, a spawn-failure teardown, or
    /// the watchdog) a no-op.
    private func releaseRunLifecycle() {
        onUnlockHandler?()
        onUnlockHandler = nil
    }

    /// Clear per-run artifacts (events, transcript, exit status, log handles, etc.)
    /// at the start of a new run. Unlike the old `resetRunState`, this does NOT
    /// touch `isRunning` — process lifetime is managed explicitly. Called right
    /// before staging/preflight at the top of each launch path.
    private func resetRunArtifacts() {
        DebugLog.agent("resetRunArtifacts: clearing per-run artifacts (prior activeChatID=\(activeChatID ?? "nil"))")
        watchdogTask?.cancel()
        watchdogTask = nil
        watchdogHasWarned = false
        events = []
        eventTimestamps = []
        isStreamingAssistantRow = false
        isStreamingThinkingRow = false
        rawTranscript = ""
        stderr = ""
        exitStatus = nil
        isInteractiveSession = false
        setGenerating(false)
        runningKind = nil
        logFileURL = nil
        debugFolderURL = nil
        runCommitedAt = nil
        runProviderLabel = nil
        runModelId = nil
        lastActivityAt = nil
        currentIngestPhase = nil
        currentProcessID = nil
        sessionHandle = nil
        plannerSessionHandle = nil
        runTotalUsage = nil
        // Interactive usage: clear the per-session baseline so each
        // interactive run starts fresh (the first turn's delta == full usage).
        lastInteractiveUsageSnapshot = nil
        thinkingOption = nil
        onUnlockHandler = nil
        // A reset starts a new run: a stale sink must never receive a new
        // session's events (issue #119).
        transcriptSink = nil
        summarySink = nil
        onAgentEvent = nil
        // #544 live progress: clear the live-usage callback + provider label so
        // a stale callback from a prior run never receives a new run's updates.
        onLiveUsage = nil
        liveUsageProviderLabel = nil
        // #608: clear the pending-permission callback so a stale callback from
        // a prior run never receives a new run's permission updates. NO emit
        // of `nil` here — `resetRunArtifacts()` runs at the START of every
        // `run(...)` (before the new run's `onPendingPermission` is installed
        // at line ~930), so emitting here would clear the prior run's row just
        // before the new run's flow starts, which is correct but redundant —
        // `finish()` for the prior run already emitted `nil`. Skipped to keep
        // `resetRunArtifacts()` a pure reset (no side effects on the prior
        // run's already-torn-down Activity state).
        onPendingPermission = nil
        summaryGenerated = false
        persistedEventCount = 0
        firstMessagePrePersisted = false
        firstMessagePreDisplayed = false
        // D2: a stale active chat association must never survive into a new run.
        // (startInteractiveQuery sets the fresh value right after this reset.)
        activeChatID = nil
        // Slice 2: clear any surfaced pending permissions + poller from a prior run.
        stopPendingPermissionPoller()
        pendingPermissions = []
    }

    // MARK: - Backend log files

    /// Create `run.jsonl` (raw stream-json) and `run.stderr.log` under the run's
    /// scratch dir and open append handles. Also creates the `debug/` folder for
    /// the verbose ACP wire trace (see `DebugRunLogger`). Best-effort: if a
    /// handle can't open, the in-memory transcript still works.
    private func openLogFiles(in scratch: URL) {
        let jsonl = scratch.appendingPathComponent("run.jsonl", isDirectory: false)
        let stderrLog = scratch.appendingPathComponent("run.stderr.log", isDirectory: false)
        let manager = FileManager.default
        manager.createFile(atPath: jsonl.path, contents: nil)
        manager.createFile(atPath: stderrLog.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: jsonl)
        stderrLogHandle = try? FileHandle(forWritingTo: stderrLog)
        logFileURL = jsonl
        // Create the debug/ subfolder. `DebugRunLogger` creates the actual
        // `debug/` + `debug/turns/` directories lazily when instantiated in
        // `ACPBackend.startProcess` from this URL; we just expose the path here
        // so the UI can reveal it and the backend profile can carry it.
        debugFolderURL = scratch.appendingPathComponent("debug", isDirectory: true)
    }

    private func writeLog(_ text: String, to handle: FileHandle?) {
        guard let handle, let data = text.data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }

    /// Write `summary.json` to the run's `debug/` folder with provider, model,
    /// kind, duration, and total usage. Reads the model id from the backend (a
    /// short actor hop) and the accumulated usage from `runTotalUsage`. Runs as
    /// a detached `@MainActor` task so `finish()` doesn't block on the actor hop
    /// — the debug folder persists on disk, the task writes to it if it still
    /// exists. Best-effort: non-fatal if the write fails (logged via DebugLog).
    private func writeDebugSummary(finishedAt: Date, status: Int32) {
        guard debugFolderURL != nil else { return }
        let startedAt = runCommitedAt
        let providerLabel = runProviderLabel
        let kind = runningKind
        let totalUsage = runTotalUsage
        let session = sessionHandle
        let backend = self.backend
        Task { @MainActor in
            // Try to read the model id from the ACP backend (last session's
            // advertised current model). Non-fatal if nil — the field is
            // optional in the summary.
            var modelId: String?
            if let session, let acp = backend as? ACPBackend {
                modelId = await acp.sessionUsage(for: session)?.modelId
            }
            let summary = DebugRunSummary.from(
                provider: providerLabel,
                model: modelId,
                kind: kind?.rawValue,
                startedAt: startedAt,
                finishedAt: finishedAt,
                usage: totalUsage,
                phases: [])
            DebugLog.agent("writeDebugSummary: writing summary.json provider=\(providerLabel ?? "nil") model=\(modelId ?? "nil") kind=\(kind?.rawValue ?? "nil")")
            if let acp = backend as? ACPBackend {
                await acp.writeDebugSummary(summary)
            }
        }
    }

    private func closeLogFiles() {
        try? logHandle?.close()
        try? stderrLogHandle?.close()
        logHandle = nil
        stderrLogHandle = nil
    }

    /// Create a fresh per-run writable scratch dir under the app's Caches (decision
    /// #4 — Claude Code needs a writable cwd; the mount is read-only). The dir also
    /// holds the per-run `run.jsonl` / `run.stderr.log` backend logs, so — unlike
    /// the previous version — we do NOT delete it on termination; it persists for
    /// post-hoc debugging via "Reveal log". Returns nil only if it can't be created.
    ///
    /// Layout (per #681 chat-debug-folders):
    /// `<base>/Self Driving Wiki-agent/<id>/runs/<RFC3339>/`
    ///
    /// - `<id>` is the stable run-namespace identifier: a chat ULID for chat runs
    ///   (`startInteractiveQuery`) or a queue item ULID for ingest/lint runs
    ///   (`run`). Both chats and queue items are retriable — a pub-sub-style
    ///   retry creates a NEW timestamped sibling under the same `<id>/runs/`,
    ///   so prior-run logs are preserved without clobber. Derivable from `<id>`
    ///   alone across app restarts, so `debugFolderURL(forChat:)` (chat side)
    ///   and `QueueActivityTracker.debugURL(for:)` (ingest/lint side, via
    ///   rehydrated `queue_item_activity.debug_url`) resolve correctly without
    ///   any in-memory map.
    /// - `<RFC3339>` is the spawn timestamp (RFC 3339, UTC, milliseconds). Lex
    ///   sort = chronological, so "latest run" is `max(runNames)` with no `stat`
    ///   needed; also human-readable in Finder (vs opaque UUIDv4).
    ///
    /// The rare `id == nil` case (a non-queue, non-chat caller — currently only
    /// legacy test paths via `AgentOperationRunner.run()`) falls back to the
    /// flat `<agentRoot>/<RFC3339>/` layout: no stable identity to namespace
    /// under, and nothing reopens it from history.
    private func makeScratchDirectory(id: String? = nil) -> URL? {
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let agentRoot = base.appendingPathComponent("Self Driving Wiki-agent", isDirectory: true)
        let timestamp = Self.rfc3339Timestamp(for: Date())
        let scratch: URL
        if let id {
            scratch = agentRoot
                .appendingPathComponent(id, isDirectory: true)
                .appendingPathComponent("runs", isDirectory: true)
                .appendingPathComponent(timestamp, isDirectory: true)
        } else {
            scratch = agentRoot.appendingPathComponent(timestamp, isDirectory: true)
        }
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            return scratch
        } catch {
            return nil
        }
    }

    /// RFC 3339 / ISO 8601 timestamp with millisecond precision, UTC. Used as
    /// the run-folder name so lexicographic sort = chronological order —
    /// "latest run" is `max(runNames)` with no `stat` needed. Milliseconds
    /// (`.withFractionalSeconds`) disambiguate same-second spawns; the launch
    /// queue serializes same-kind spawns anyway, so collisions are not a real
    /// concern. `ISO8601DateFormatter` is Foundation's canonical RFC 3339
    /// formatter (thread-safe, no locale drift).
    private static func rfc3339Timestamp(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    // MARK: - Seatbelt sandbox

    /// Resolve the write-confinement seatbelt sandbox for an Ingest or Edit spawn.
    /// The sandbox is **always on** for these paths — it confines the agent's
    /// filesystem writes to the wiki DB + scratch + `~/.claude`, AND denies exec/read
    /// of the resolved `pdf2md` script so a compromised agent can't run the bundled
    /// extractor (reads, network, and all other exec stay open; see `SandboxProfile`).
    /// Returns `nil` (fail-open, logged) only when a required path can't be resolved,
    /// so a misconfiguration never blocks agent work entirely.
    ///
    /// - Parameter pdf2mdScriptPath: the resolved `pdf2md` script path (or nil if the
    ///   app couldn't resolve one). Threaded into the profile as the `PDF2MD_SCRIPT`
    ///   deny target. When nil, no exec/read deny is emitted (the agent has nothing
    ///   bundled to run; generic `uv`/`python3` is still reachable — issue #116 item 2).
    ///
    /// This function ONLY resolves the invocation; it does NOT create any directories.
    /// Each spawn site that receives a non-nil result MUST call `createSandboxTmpDir(in:)`
    /// before launching the child so that `TMPDIR` (set by `OperationCommand.applySandbox`)
    /// points at a directory that actually exists.
    ///
    /// (The chat path uses this write invocation directly — chats are always
    /// write-capable. The former read-only Ask sandbox is retained in-tree but
    /// unwired.)
    private func resolveSandboxInvocation(
        wikiID: String,
        scratch: URL,
        dir: URL,
        pdf2mdScriptPath: String?
    ) -> SandboxProfile.SandboxInvocation? {
        // HOME for the `-D HOME` profile param. Read from the environment the child
        // will inherit (fall back to the process home). Forwarded for forward-compat
        // and debugging; the current whitelist profile does not reference it.
        let homePath = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()

        // The active wiki's SQLite DB path mirrors `WikiResolver.databaseURL(for:)`:
        // `<container>/<ulid>.sqlite`. `dir` is the App Group container the DB lives in.
        // Symlink resolution is performed inside `SandboxProfile.invocation` (the
        // tested core layer) so the canonical path reaches the seatbelt profile.
        let dbPath = dir.appendingPathComponent("\(wikiID).sqlite", isDirectory: false).path

        // Fail-open if any required path is empty/relative (misconfiguration).
        guard !scratch.path.isEmpty, scratch.path.hasPrefix("/"),
              !dbPath.isEmpty, dbPath.hasPrefix("/") else {
            DebugLog.agent("sandbox: could not resolve scratch/db path — running UNSANDBOXED")
            return nil
        }

        let invocation = SandboxProfile.invocation(
            homePath: homePath,
            scratchDir: scratch.path,
            wikiDBPath: dbPath,
            pdf2mdScriptPath: pdf2mdScriptPath
        )
        let pdf2mdNote = pdf2mdScriptPath.map { " + denying pdf2md @ \($0)" } ?? ""
        DebugLog.agent("sandbox: confining Ingest/Edit agent writes to scratch + \(dbPath)\(pdf2mdNote)")
        return invocation
    }

    /// Resolve the bundled `pdf2md` script path to deny in the agent seatbelt, or nil
    /// if no script is resolvable. Delegates to the injected
    /// `resolvePdf2mdScriptPath` closure (set by the app to call
    /// `PdfExtractionService.resolveScript()`) so the deny always targets the
    /// exact file the agent would otherwise reach. Resolved once per spawn and
    /// handed to BOTH the edit and read-only invocations.
    private func resolvePdf2mdScriptPath() -> String? {
        let path = pdf2mdScriptPathResolver()
        if path == nil {
            DebugLog.agent("sandbox: pdf2md not resolved — no PDF2MD_SCRIPT deny rule emitted")
        }
        return path
    }

    /// Create the `scratch/.tmp` directory a sandboxed spawn would point
    /// `TMPDIR` at. Must be called at each spawn site whenever a non-nil
    /// sandbox is resolved so the directory exists before the child process
    /// tries to write into it. Best-effort: failure (e.g. scratch unwritable)
    /// is surfaced later by the child's own write errors.
    private static let tmpRelocationLeaf = ".tmp"
    private func createSandboxTmpDir(in scratch: URL) {
        let tmp = scratch.appendingPathComponent(Self.tmpRelocationLeaf, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
}

// MARK: - #607: per-operation permission policy domain

/// The operation kind the launcher resolves a permission policy for. Kept
/// distinct from `WikiOperation.Kind` (the *run* kind) so the permission-
/// policy domain stays independent (no coupling between the two enums). Mapping
/// from a `WikiOperation.Kind` to a `PermissionOperationKind` happens at the
/// launcher call site (`.lint`/`.lintPage` → `.lint`, `.ingest` → `.ingest`,
/// else `.chat`).
///
/// Extraction is intentionally NOT a kind here — see `plans/acp-permissions.md`
/// §5.1 (extraction keeps its `.bypass` default on `ACPExtractionClient` and its
/// callers weren't fully enumerated; a follow-up PR can add `.extraction` once
/// every `ACPExtractionClient()` construction threads the extraction key).
public enum PermissionOperationKind: Sendable {
    case chat
    case ingest
    case lint
}

// MARK: - #607: one-time legacy key migration

/// One-shot migration of the pre-#607 `agentPermissionMode` UserDefaults key
/// into the post-#607 `chatPermissionMode` key. Idempotent + injectable
/// (`defaults` is a parameter) so it can be unit-tested against a throwaway
/// `UserDefaults(suiteName:)` without touching the app's real `.standard`
/// defaults — mirrors `AppStorageMigration.migrateZoomKey`'s shape.
///
/// **Why `object(forKey:) == nil` (not `string(forKey:) == nil`):** `UserDefaults
/// .string(forKey:)` cannot distinguish "key absent" from "key present but empty
/// string" — `object(forKey:) == nil` is the only correct key-presence check.
/// This is the predicate test #9 in `plans/acp-permissions.md` §8.2 asserts.
///
/// **Idempotent:** after the first run, `object(forKey: PermissionModeKey.chat)`
/// is non-nil (we just wrote it), so the guard fails on subsequent launches.
///
/// **Copy, not move:** the legacy `agentPermissionMode` is left in place
/// (orphaned, like `sandbox-config.json`) — deleting a UserDefaults key has no
/// rollback path, and a future downgrade would silently lose the user's pick.
public enum PermissionModeMigration {
    public static func migrateOnce(
        from legacyKey: String = "agentPermissionMode",
        to newKey: String = AgentLauncher.PermissionModeKey.chat,
        in defaults: UserDefaults = .standard
    ) {
        // Only migrate if the new chat key has NEVER been written (object == nil).
        guard defaults.object(forKey: newKey) == nil,
              let legacy = defaults.string(forKey: legacyKey),
              !legacy.isEmpty,
              let policy = PermissionPolicy(rawValue: legacy) else { return }
        defaults.set(policy.rawValue, forKey: newKey)
        DebugLog.agent("PermissionModeMigration: copied legacy \(legacyKey)=\(policy.rawValue) -> \(newKey)")
    }
}
