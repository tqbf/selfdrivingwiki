import Cordis
import CordisLoader
import Foundation
import WikiFSCore
import WikiFSTypes

internal actor RuntimeInvariantCoordinator {
    private let registry: InvariantRegistry
    private let sink: any InvariantViolationSink
    private var startupTask: Task<[InvariantRegistration], Error>?
    private var registrations: [InvariantRegistration] = []
    private var shutdownStarted = false

    init(processContext: CordisContext, sink: any InvariantViolationSink) throws {
        self.sink = sink
        registry = try InvariantRegistry(root: processContext, sink: sink)
    }

    func start() async throws {
        guard !shutdownStarted else { throw CancellationError() }
        if !registrations.isEmpty { return }
        if startupTask == nil {
            let registry = registry
            startupTask = Task {
                var installed: [InvariantRegistration] = []
                do {
                    for owner in [
                        InvariantOwners.wikiIdentity,
                        InvariantOwners.scopeLifecycle,
                        InvariantOwners.wikiEvents,
                        InvariantOwners.processOwnership,
                    ] {
                        installed.append(try await registry.register(.init(owner: owner) { _ in }))
                    }
                    return installed
                } catch {
                    for registration in installed.reversed() {
                        do { try await registration.dispose() } catch let cleanupError {
                            DebugLog.store("Runtime invariant startup cleanup failed: \(cleanupError)")
                        }
                    }
                    throw error
                }
            }
        }
        guard let startupTask else { throw CancellationError() }
        let installed = try await startupTask.value
        guard !shutdownStarted else {
            for registration in installed.reversed() {
                do { try await registration.dispose() } catch let cleanupError {
                    DebugLog.store("Runtime invariant late-start cleanup failed: \(cleanupError)")
                }
            }
            throw CancellationError()
        }
        registrations = installed
    }

    func observeWiki(
        profile: BootedProfile,
        profileWikiID: WikiID,
        store: any WikiStore,
        databaseWikiID: WikiID,
        host: WikiScopeHostAssociation
    ) async throws {
        let scope = try await profile.context.scopeDiagnostics()
        let eventBus = store.eventBus
        WikiScopeIdentitySnapshot(
            scope: scope,
            profileWikiID: profileWikiID,
            storeWikiID: eventBus?.wikiID,
            eventBusWikiID: eventBus?.wikiID,
            databaseWikiID: databaseWikiID,
            host: host)
            .validate(sink: sink)

        guard let eventBus else { return }
        let observer = WikiEventDiagnosticObserver(busWikiID: eventBus.wikiID, sink: sink)
        let cleanup = try ComponentDefinition(label: "invariant.wiki-event-observer") { activation in
            let id = UUID()
            eventBus.installDiagnosticObserver(observer, id: id)
            do {
                _ = try await activation.effect { _ in eventBus.removeDiagnosticObserver(id: id) }
            } catch {
                eventBus.removeDiagnosticObserver(id: id)
                throw error
            }
        }
        let handle = try await profile.context.register(cleanup)
        _ = try await handle.awaitSettled()
    }

    func shutdown() async {
        guard !shutdownStarted else { return }
        shutdownStarted = true
        let task = startupTask
        startupTask = nil
        var owned = registrations
        registrations.removeAll()
        if owned.isEmpty, let task {
            do { owned = try await task.value } catch {
                // Startup owns partial-registration cleanup and preserves its error.
            }
        }
        for registration in owned.reversed() {
            do {
                try await registration.dispose()
            } catch {
                DebugLog.store("Runtime invariant shutdown failed: \(error)")
            }
        }
    }
}
