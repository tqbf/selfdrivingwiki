import Foundation
import Observation
import WikiDaemonContract
import WikiFSEngine
import WikiFSCore
import WikiFSTypes

/// Owns the one active foreground lint run per wiki. The wiki session's
/// coordinator: reopening Lint for the same page focuses the existing sheet;
/// a second page's run is refused while a first sheet is active (no
/// invisible background work).
@MainActor
@Observable
final class ForegroundLintCoordinator {

    /// The shared provider services — the lint session's model lanes.
    private let services: any AgentProviderServices

    /// The active run per wiki. One sheet per wiki at a time.
    private var activeByWiki: [WikiID: ActiveRun] = [:]

    struct ActiveRun {
        let session: ForegroundLintSession
        let pageID: PageID
    }

    init(services: any AgentProviderServices) {
        self.services = services
    }

    // MARK: - Opening

    /// The active session for `wikiID`, when one exists.
    func activeSession(for wikiID: WikiID) -> ForegroundLintSession? {
        activeByWiki[wikiID]?.session
    }

    /// Whether `pageID` currently has the active run (focus instead of open).
    func isActive(pageID: PageID, wikiID: WikiID) -> Bool {
        activeByWiki[wikiID]?.pageID == pageID
    }

    /// Open (or focus) the lint sheet for `pageID`. Returns the session to
    /// present, or nil when a DIFFERENT page's run is active in this wiki
    /// (the caller shows the refusal — the first sheet stays the only one).
    func open(
        pageID: PageID, wikiID: WikiID, store: WikiStoreModel,
        configDirectory: URL?
    ) -> ForegroundLintSession? {
        if let active = activeByWiki[wikiID] {
            return active.pageID == pageID ? active.session : nil
        }
        // Load + validate the pipeline configuration for THIS run. A missing
        // file uses the bundled defaults in memory; an invalid file blocks
        // the run with the typed problems (never overwritten).
        let pipeline: LintPipelineDocument
        if let configDirectory {
            switch LintPipelineStore.load(from: configDirectory) {
            case .loaded(let document):
                pipeline = document
            case .missingDefaults(let defaults):
                pipeline = defaults
            case .invalid(_, let problems):
                DebugLog.lint("ForegroundLintCoordinator: invalid lint-pipelines.json: \(problems)")
                let session = ForegroundLintSession(
                    wikiID: wikiID, pipeline: .bundledDefaults(),
                    dependencies: .none)
                session.configProblems = problems
                session.fail("lint-pipelines.json is invalid — fix or remove it (open Configuration Folder in Settings). The file is never overwritten automatically.")
                let run = ActiveRun(session: session, pageID: pageID)
                activeByWiki[wikiID] = run
                return session
            }
        } else {
            pipeline = .bundledDefaults()
        }
        // The script sandbox's explicit denies: this wiki's database and the
        // daemon socket (the paths a script must never reach). Resolution
        // failure logs and omits the deny — the sandbox still denies network
        // and all writes outside scratch.
        let wikiDBPath: String?
        do {
            wikiDBPath = try DatabaseLocation.appGroupContainerURL(forWikiID: wikiID.rawValue).path
        } catch {
            DebugLog.lint("Lint script sandbox: wiki DB path unavailable, deny not emitted: \(error)")
            wikiDBPath = nil
        }
        let daemonSocket: String?
        do {
            daemonSocket = try SearchSocketWire.socketPath(
                inContainerDirectory: DatabaseLocation.appGroupContainerDirectory())
        } catch {
            DebugLog.lint("Lint script sandbox: daemon socket path unavailable, deny not emitted: \(error)")
            daemonSocket = nil
        }
        let session = ForegroundLintSession(
            wikiID: wikiID, pipeline: pipeline,
            dependencies: Self.dependencies(
                store: store, services: services,
                wikiDBPath: wikiDBPath, daemonSocketPath: daemonSocket))
        session.canonicalizationResolvers = Self.resolvers(store: store)
        activeByWiki[wikiID] = ActiveRun(session: session, pageID: pageID)
        return session
    }

    /// Close (dismiss + tear down) the active run for `wikiID`.
    func close(wikiID: WikiID) {
        guard let active = activeByWiki[wikiID] else { return }
        active.session.cancel()
        activeByWiki[wikiID] = nil
    }

    /// Record the outcome of a run so reopening decision-making stays honest.
    func runFinished(wikiID: WikiID) {
        activeByWiki[wikiID] = nil
    }

    /// Wiki shutdown: reject all late results and release the run.
    func shutdown(wikiID: WikiID) {
        close(wikiID: wikiID)
    }

    /// The App Group container directory the pipeline configuration loads
    /// from (nil on resolution failure — the bundled defaults then apply).
    static func resolvedConfigDirectory() -> URL? {
        do {
            return try DatabaseLocation.appGroupContainerDirectory()
        } catch {
            DebugLog.lint("Lint config directory unavailable, using bundled defaults: \(error)")
            return nil
        }
    }

    // MARK: - Dependency wiring

    /// The session's environment: capture through the store's coherent read,
    /// model steps through the provider services' lint lanes, script sandbox
    /// denies pointed at the wiki DB + daemon socket.
    static func dependencies(
        store: WikiStoreModel, services: any AgentProviderServices,
        wikiDBPath: String?, daemonSocketPath: String?
    ) -> ForegroundLintSession.Dependencies {
        ForegroundLintSession.Dependencies(
            capture: { pageID in
                store.lintCapture(pageID: pageID)
            },
            prepareCheck: { providerOverride, modelOverride in
                try await services.prepareLintCheck(
                    providerOverride: providerOverride, modelOverride: modelOverride)
            },
            prepareRepair: { providerOverride, modelOverride in
                try await services.prepareLintRepair(
                    providerOverride: providerOverride, modelOverride: modelOverride)
            },
            lintTurn: { prompt, systemPrompt, preparation in
                try await services.lintTurn(
                    prompt: prompt, systemPrompt: systemPrompt, preparation: preparation)
            },
            releaseToken: { token in
                await services.release(token)
            },
            wikiDBPath: { wikiDBPath },
            daemonSocketPath: { daemonSocketPath })
    }

    /// The public-resolver triple for preview canonicalization (same rules
    /// the composed upsert's sequential seam uses).
    static func resolvers(store: WikiStoreModel) -> ForegroundLintSession.CanonicalizationResolvers {
        ForegroundLintSession.CanonicalizationResolvers(
            page: { store.lintResolveTitleToID($0) },
            source: { store.lintResolveSourceByName($0) },
            chat: { store.lintResolveChatByTitle($0) })
    }
}
