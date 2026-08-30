#if os(macOS)
import Foundation
import Observation
import WikiFSCore

public enum SessionLoadingError: Error, Equatable, Sendable {
    case processProfileUnavailable(String)
}

/// Owns the live `WikiSession` cache for multi-window SwiftUI
/// (`plans/multi-window-ui.md` Phase 2b). Each window's `RootScene` calls
/// ``session(for:descriptor:)`` to resolve (or create) the session for its
/// wiki ID. Two windows showing the SAME wiki share ONE session — one store,
/// one bus, one gate — so edits in one propagate instantly to the other via
/// the shared `WikiEventBus`. Windows showing DIFFERENT wikis get distinct
/// sessions with independent gates, so a long ingest in one window cannot
/// block a query in another.
///
/// `WindowGroup(for: WikiID.self)` deduplicates by `==` on the value, so it
/// won't open two windows for the same wiki ID anyway — but `SessionManager`
/// handles the case where the user opens wiki A, closes that window, then
/// opens wiki A again (the session was released on close, a fresh one is
/// created).
///
/// Lives in `WikiFSEngine` because it manages `WikiSession` instances (an
/// Engine type). The app layer owns the `SessionManager` via `@State` and
/// passes it into each `RootScene`.
@MainActor
@Observable
public final class SessionManager {
    public enum SessionReadiness: Equatable, Sendable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    public typealias AsyncSessionLoader = @MainActor @Sendable (WikiID, WikiDescriptor) async throws -> any WikiSessionProtocol
    public typealias TestSessionFactory = @MainActor (WikiID, WikiDescriptor) throws -> any WikiSessionProtocol

    /// Observable readiness for the mandatory per-wiki child-profile boot path.
    public private(set) var readiness: [WikiID: SessionReadiness] = [:]
    @ObservationIgnored private let asyncSessionLoader: AsyncSessionLoader?
    /// Explicit synchronous fixture seam. Production must provide the async
    /// child-profile loader and never sets this closure.
    @ObservationIgnored private let testSessionFactory: TestSessionFactory?

    /// Live sessions keyed by wiki ID. A wiki open in multiple windows
    /// shares ONE session (one store, one bus, one gate).
    public private(set) var sessions: [WikiID: any WikiSessionProtocol] = [:]
    /// Number of live `RootScene` owners for each cached session. A renderer
    /// window does not own a lease; it resolves through the session retained by
    /// the wiki window that activated it.
    @ObservationIgnored private var sessionLeaseCounts: [WikiID: Int] = [:]
    private struct SessionFlight: Sendable {
        let token: UUID
        let task: Task<any WikiSessionProtocol, Error>
    }
    @ObservationIgnored private var sessionFlights: [WikiID: SessionFlight] = [:]

    /// Per-wiki store-open failures (issue #881). When `session(for:)` throws
    /// (the on-disk DB couldn't be opened), the error message is recorded here
    /// keyed by wiki ID so `RootScene` can render a user-visible error view
    /// ("Could not open wiki database…") instead of silently showing an empty
    /// wiki. Cleared by ``clearOpenError(for:)`` (Retry button) so the next
    /// `session(for:)` call attempts a fresh open.
    public private(set) var openErrors: [WikiID: String] = [:]

    /// The user-visible error message for a wiki that failed to open, or nil.
    public func openError(for wikiID: WikiID) -> String? { openErrors[wikiID] }

    /// Clear a recorded open error so the next `session(for:)` retry attempts a
    /// fresh open (Retry button in the error view).
    public func clearOpenError(for wikiID: WikiID) { openErrors.removeValue(forKey: wikiID) }

    /// The wiki ID of the frontmost window. Updated by per-window scenePhase
    /// transitions (`.active`). Used by `VacuumCommands` (which lives at the
    /// scene level — `.commands` is a `Scene` modifier, not a `View`
    /// modifier, so it can't go on `RootScene`) to resolve the correct
    /// session for the menu-bar "Vacuum/Lint/Activity Log" actions.
    public var frontmostWikiID: WikiID?

    /// The shared extraction backend resolver (created once at app scope and
    /// passed into every session). Carries no per-wiki state, so sharing
    /// avoids re-reading the same config file per session.
    public let extractionCoordinator: ExtractionCoordinator

    /// Shared, app-wide queue engine. One instance serves every session.
    /// Widened to `any QueueEngineClient` (Phase 0) so the source can flip
    /// from in-process `QueueEngine` to an `XPCQueueEngineProxy` without
    /// rewriting call sites.
    public let queueEngine: any QueueEngineClient

    /// Shared, app-wide extraction provider. The app-layer bridge from the
    /// headless queue engine to `@MainActor` types.
    public let extractionProvider: any QueueExtractionProvider

    /// Owns the private process search root and per-wiki child lifetimes.
    public let searchRuntimeRegistry: SearchRuntimeRegistry
    private struct SearchRelease: Sendable {
        let token: UUID
        let task: Task<Void, Never>
    }
    @ObservationIgnored private var searchReleaseTasks: [WikiID: SearchRelease] = [:]

    /// App-scoped provider composition facade shared by every session launcher.
    /// The app supplies the runtime services, or an unavailable fallback when
    /// assembly fails, so non-agent wiki features remain usable.
    public let providerServices: any AgentProviderServices

    /// The App Group container directory holding every `<ulid>.sqlite`.
    public let containerDirectory: URL

    /// Resolves a legacy `pdf2md` script path for the agent seatbelt deny rule.
    /// Production no longer injects this: extraction runs through the
    /// registry's reviewed package plugins and there is no legacy subprocess
    /// path to deny, so the default `{ nil }` applies everywhere. Kept (with
    /// tests' explicit `{ nil }` still accepted) until the compatibility
    /// adapter is deleted in the Phase 9 cleanup.
    public let pdf2mdScriptPathResolver: () -> String?

    /// Receives per-turn interactive (Ask/Edit chat) usage deltas from each
    /// session's launchers so the menu bar daily total includes chat, not
    /// just queue runs. The app wires this to
    /// `QueueActivityTracker.recordInteractiveUsage`. Default no-op so
    /// headless/daemon callers (which have no UI tracker) are unaffected.
    public let interactiveUsageRecorder: @MainActor (SessionUsage) -> Void

    /// Factory for the HTML→Markdown extractor (defuddle). Called once per
    /// session at creation. The app passes a closure returning
    /// `LocalDefuddleExtractor()` (WikiFS target); defaults to nil (tag-based
    /// fallback) for headless/daemon/test callers. Issue #761.
    public let htmlMarkdownExtractorFactory: @MainActor () -> (any HtmlMarkdownExtractor)?

    /// Resolver for the configured HTML extraction backend (issue #799 PR2).
    /// Called once per session at creation. Reads `ExtractionConfig.htmlBackend`
    /// at the app wiring time and returns the chosen `HtmlExtractionBackend`,
    /// or `nil` if no default is set. Mirrors the `htmlMarkdownExtractorFactory`
    /// injection shape (the model is deliberately NOT config-aware — config is
    /// read by `ExtractionCoordinator` in this engine target — so the chosen
    /// backend is injected from the app layer that owns the config file).
    public let htmlBackendResolver: @MainActor () -> HtmlExtractionBackend?

    /// Resolver for the configured podcast transcription backend (issue #799
    /// PR4). Called once per session at creation. Reads
    /// `ExtractionConfig.podcastBackend` at the app wiring time and returns
    /// the chosen `PodcastTranscriptionBackend`, or `nil` if no default is
    /// set. Mirrors the `htmlBackendResolver` injection shape above (the
    /// model is deliberately NOT config-aware).
    public let podcastBackendResolver: @MainActor () -> PodcastTranscriptionBackend?

    /// Injection seam for the store factory (mirrors `WikiSession.makeStore`).
    /// Defaults to `StoreBackend.current.makeStore(databaseURL:)`. Tests inject
    /// a throwing closure to exercise the open-failure path (issue #881)
    /// without relying on filesystem corruption.
    public let makeStore: @Sendable (URL) throws -> WikiStore

    public init(
        containerDirectory: URL,
        extractionCoordinator: ExtractionCoordinator,
        queueEngine: any QueueEngineClient,
        extractionProvider: any QueueExtractionProvider,
        searchRuntimeRegistry: SearchRuntimeRegistry = SearchRuntimeRegistry(),
        providerServices: any AgentProviderServices = UnavailableAgentProviderServices(),
        pdf2mdScriptPathResolver: @escaping () -> String? = { nil },
        htmlMarkdownExtractorFactory: @escaping @MainActor () -> (any HtmlMarkdownExtractor)? = { nil },
        htmlBackendResolver: @escaping @MainActor () -> HtmlExtractionBackend? = { nil },
        podcastBackendResolver: @escaping @MainActor () -> PodcastTranscriptionBackend? = { nil },
        interactiveUsageRecorder: @escaping (@MainActor (SessionUsage) -> Void) = { _ in },
        makeStore: @escaping @Sendable (URL) throws -> WikiStore = { try StoreBackend.current.makeStore(databaseURL: $0) },
        asyncSessionLoader: AsyncSessionLoader? = nil,
        testSessionFactory: TestSessionFactory? = nil
    ) {
        self.containerDirectory = containerDirectory
        self.extractionCoordinator = extractionCoordinator
        self.queueEngine = queueEngine
        self.extractionProvider = extractionProvider
        self.searchRuntimeRegistry = searchRuntimeRegistry
        self.providerServices = providerServices
        self.pdf2mdScriptPathResolver = pdf2mdScriptPathResolver
        self.htmlMarkdownExtractorFactory = htmlMarkdownExtractorFactory
        self.htmlBackendResolver = htmlBackendResolver
        self.podcastBackendResolver = podcastBackendResolver
        self.interactiveUsageRecorder = interactiveUsageRecorder
        self.makeStore = makeStore
        self.asyncSessionLoader = asyncSessionLoader
        self.testSessionFactory = testSessionFactory
    }

    // MARK: - Session lifecycle

    public func readiness(for wikiID: WikiID) -> SessionReadiness {
        readiness[wikiID] ?? .idle
    }

    /// Await the per-wiki session composition boundary.
    ///
    /// Production callers inject the child-profile loader. A synchronous path
    /// exists only when tests explicitly install `testSessionFactory`.
    public func readySession(for wikiID: WikiID, descriptor: WikiDescriptor) async throws -> any WikiSessionProtocol {
        if let existing = sessions[wikiID] {
            existing.updateDescriptor(descriptor)
            sessionLeaseCounts[wikiID, default: 0] += 1
            readiness[wikiID] = .ready
            return existing
        }
        readiness[wikiID] = .loading
        guard let asyncSessionLoader else {
            guard testSessionFactory != nil else {
                let error = SessionLoadingError.processProfileUnavailable(
                    "Per-wiki child-profile loader is unavailable")
                readiness[wikiID] = .failed(String(describing: error))
                throw error
            }
            do {
                let session = try self.session(for: wikiID, descriptor: descriptor)
                readiness[wikiID] = .ready
                return session
            } catch {
                readiness[wikiID] = .failed(String(describing: error))
                throw error
            }
        }
        let flight: SessionFlight
        if let existing = sessionFlights[wikiID] {
            flight = existing
        } else {
            let token = UUID()
            let task = Task { @MainActor in
                try await asyncSessionLoader(wikiID, descriptor)
            }
            flight = SessionFlight(token: token, task: task)
            sessionFlights[wikiID] = flight
        }
        do {
            let session = try await flight.task.value
            guard sessionFlights[wikiID]?.token == flight.token else {
                if let installed = sessions[wikiID], installed === session {
                    installed.updateDescriptor(descriptor)
                    sessionLeaseCounts[wikiID, default: 0] += 1
                    return installed
                }
                await session.shutdown()
                throw CancellationError()
            }
            sessionFlights.removeValue(forKey: wikiID)
            if let installed = sessions[wikiID] {
                guard installed === session else {
                    await session.shutdown()
                    installed.updateDescriptor(descriptor)
                    sessionLeaseCounts[wikiID, default: 0] += 1
                    return installed
                }
            } else {
                sessions[wikiID] = session
            }
            sessionLeaseCounts[wikiID, default: 0] += 1
            openErrors.removeValue(forKey: wikiID)
            readiness[wikiID] = .ready
            return session
        } catch {
            if sessionFlights[wikiID]?.token == flight.token {
                sessionFlights.removeValue(forKey: wikiID)
                let failure = String(describing: error)
                readiness[wikiID] = .failed(failure)
                let dbPath = containerDirectory
                    .appendingPathComponent("\(wikiID.rawValue).sqlite", isDirectory: false).path
                openErrors[wikiID] = "Could not open the wiki database at \(dbPath). \(failure)"
                DebugLog.store("SessionManager: asynchronous wiki session boot failed for \(wikiID.rawValue): \(failure)")
            }
            throw error
        }
    }

    /// Get or create a session for `wikiID`. If a session already exists for
    /// this wiki (open in another window), returns the existing instance —
    /// so two windows over the same wiki share one store + bus + gate.
    ///
    /// - Throws: If the wiki's on-disk store cannot be opened, the error is
    ///   recorded in ``openErrors`` (so `RootScene` can show a user-visible
    ///   message) and rethrown. There is no in-memory fallback (#881) — a
    ///   failed open leaves `sessions[wikiID]` unset, and the caller renders
    ///   an error view instead of an empty wiki.
    public func session(for wikiID: WikiID, descriptor: WikiDescriptor) throws -> any WikiSessionProtocol {
        if let existing = sessions[wikiID] {
            // Refresh the descriptor in case the registry mutated (rename /
            // set home page) since this session was created.
            existing.updateDescriptor(descriptor)
            sessionLeaseCounts[wikiID, default: 0] += 1
            return existing
        }
        let newSession: any WikiSessionProtocol
        do {
            guard let testSessionFactory else {
                throw SessionLoadingError.processProfileUnavailable(
                    "Synchronous session construction is available only to injected test fixtures")
            }
            newSession = try testSessionFactory(wikiID, descriptor)
        } catch {
            // Record a user-visible message so RootScene can render an error
            // view. No in-memory fallback (#881) — the on-disk file is left
            // untouched for recovery.
            let dbPath = containerDirectory
                .appendingPathComponent("\(wikiID.rawValue).sqlite", isDirectory: false).path
            let message = "Could not open the wiki database at \(dbPath). The file may be corrupt. \(error)"
            DebugLog.store("SessionManager: failed to open wiki \(wikiID.rawValue): \(error)")
            openErrors[wikiID] = message
            throw error
        }
        // A successful open clears any previously-recorded error for this wiki.
        openErrors.removeValue(forKey: wikiID)
        // Transfer any deferred wiki-link click (registered by
        // `applyOrStashWikiLink` for a wiki whose window wasn't open yet)
        // onto the new session. `RootView` consumes it on appear.
        if let pending = consumePendingWikiLink(for: wikiID) {
            newSession.pendingWikiLink = pending
        }
        sessions[wikiID] = newSession
        sessionLeaseCounts[wikiID] = 1
        return newSession
    }

    /// Release one window's lease on a session. The session leaves the cache
    /// only after its last `RootScene` closes, so another window showing the
    /// same wiki can still resolve renderer and comparison windows through the
    /// shared manager.
    public func releaseSession(for wikiID: WikiID) {
        guard sessions[wikiID] != nil else { return }
        let remainingLeases = max(0, sessionLeaseCounts[wikiID, default: 1] - 1)
        guard remainingLeases == 0 else {
            sessionLeaseCounts[wikiID] = remainingLeases
            return
        }
        removeSession(for: wikiID)
    }

    private func removeSession(for wikiID: WikiID) {
        sessionLeaseCounts.removeValue(forKey: wikiID)
        guard let session = sessions.removeValue(forKey: wikiID) else { return }
        session.store.flushPendingSaves()
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            await session.shutdown()
            guard self?.searchReleaseTasks[wikiID]?.token == token else { return }
            self?.searchReleaseTasks[wikiID] = nil
        }
        searchReleaseTasks[wikiID] = SearchRelease(token: token, task: task)
    }

    /// Release all live sessions, await owned teardown, then dispose the private
    /// search root. App termination force-removes sessions regardless of how
    /// many window leases remain. Safe to call repeatedly.
    public func shutdownSearchRuntimes() async {
        for wikiID in Array(sessions.keys) { removeSession(for: wikiID) }
        let releases = Array(searchReleaseTasks.values)
        for release in releases { await release.task.value }
        searchReleaseTasks.removeAll()
        await searchRuntimeRegistry.shutdown()
    }

    /// Flush pending saves for ONE session (used by the registry's
    /// `flushActiveStore` closure before export/delete of a specific wiki).
    public func flushSession(for wikiID: WikiID) {
        sessions[wikiID]?.store.flushPendingSaves()
    }

    /// Flush pending saves for ALL active sessions (app background / quit).
    public func flushAllSessions() {
        for session in sessions.values {
            session.store.flushPendingSaves()
        }
    }

    // MARK: - Derived accessors (for bridge routing + FP multi-subscribe)

    /// All active wiki IDs (for bridge routing + FP multi-subscribe).
    public var activeWikiIDs: Set<WikiID> { Set(sessions.keys) }

    /// All live sessions (for bridge flush routing).
    public var allSessions: [any WikiSessionProtocol] { Array(sessions.values) }

    /// Fan out one authoritative machine-renderer reload to every live wiki
    /// projection. Closed/inactive wikis own no session and therefore reload
    /// the same machine authority when they next open.
    public func reloadRendererMachineAvailabilityForLiveSessions() {
        for session in sessions.values {
            session.store.reloadRendererMachineAvailability()
        }
    }

    /// Applies the registry's current extraction input claims to every live
    /// wiki model after package reconciliation. Closed wikis read the current
    /// claims when their sessions start.
    public func refreshRegisteredExtractionInputsForLiveSessions(
        _ inputs: RegisteredExtractionInputs
    ) {
        for session in sessions.values {
            session.store.registeredExtractionInputs = inputs
        }
    }

    /// The frontmost session, if any. Resolved from ``frontmostWikiID`` —
    /// `VacuumCommands` uses this to target the correct wiki for menu-bar
    /// Vacuum/Lint/Activity Log actions.
    public var frontmostSession: (any WikiSessionProtocol)? {
        guard let id = frontmostWikiID else { return nil }
        return sessions[id]
    }

    // MARK: - Cross-window wiki-link navigation

    /// Deferred `wiki://` click requests keyed by wiki ID, for wikis whose
    /// window is NOT yet open. When ``session(for:descriptor:)`` creates a
    /// session, it transfers the matching stash onto the session's
    /// ``WikiSession/pendingWikiLink``; `RootView` then consumes it on appear
    /// — after the store is ready. Used by the Activity / queue window, which
    /// renders transcripts across MANY wikis: a click on a still-closed wiki
    /// opens the window via `OpenWindowBridge.openWiki(wikiID)` (which dedupes
    /// by `==`, so a focus-if-open), then delivers the navigation once the
    /// session resolves. The open-window case is handled directly by the
    /// caller (it has the live store) and never reaches this stash.
    public var pendingWikiLinks: [WikiID: (url: URL, openInNewTab: Bool)] = [:]

    /// Stash a deferred `wiki://` navigation for `wikiID` — for a wiki whose
    /// window is NOT yet open. ``session(for:descriptor:)`` transfers the
    /// stash onto the new session; `RootView.onAppear` consumes it. Call this
    /// ONLY when the wiki window is closed; an open window's store can route
    /// the click directly.
    public func stashPendingWikiLink(_ wikiID: WikiID, url: URL, openInNewTab: Bool) {
        pendingWikiLinks[wikiID] = (url: url, openInNewTab: openInNewTab)
    }

    /// Consume (clear) the stashed deferred link for `wikiID`. Called by
    /// ``session(for:descriptor:)`` once it has transferred the stash onto
    /// the freshly-created session. One-shot: a second call returns nil.
    public func consumePendingWikiLink(for wikiID: WikiID) -> (url: URL, openInNewTab: Bool)? {
        pendingWikiLinks.removeValue(forKey: wikiID)
    }
}
#endif
