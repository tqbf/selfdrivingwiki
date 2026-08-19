#if os(macOS)
import Foundation
import WikiFSCore
import WikiFSSearch

/// Per-wiki owner of asynchronous composition and one stable search facade.
@MainActor
public final class SearchCompositionOwner {
    public nonisolated let services: MutableSearchServices

    private enum State {
        case idle
        case starting(Task<Void, Never>, MutableSearchServices.Installation)
        case installed(SearchRuntimeLease, MutableSearchServices.Installation)
        case stopped
    }

    private let registry: SearchRuntimeRegistry
    private let startupPrerequisite: Task<Void, Never>?
    private let assembly: SearchRuntimeAssembly
    private var state: State = .idle
    private var startupError: (any Error)?

    public init(
        registry: SearchRuntimeRegistry,
        identity: SearchRuntimeIdentity,
        contentSource: any TantivyContentSource,
        changeStreamFactory: any SearchChangeStreamFactory,
        startupPrerequisite: Task<Void, Never>? = nil,
        services: MutableSearchServices = MutableSearchServices()
    ) {
        self.registry = registry
        self.startupPrerequisite = startupPrerequisite
        self.assembly = SearchRuntimeAssembly(
            identity: identity,
            contentSource: contentSource,
            changeStreamFactory: changeStreamFactory)
        self.services = services
    }

    public func start() {
        guard case .idle = state else { return }
        let installation = MutableSearchServices.Installation()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runStartup(installation: installation)
        }
        state = .starting(task, installation)
    }

    public func awaitSettled() async {
        guard case .starting(let task, _) = state else { return }
        await task.value
    }

    public func failureDescription() -> String? {
        startupError.map(String.init(describing:))
    }

    public func shutdown() async {
        switch state {
        case .idle:
            state = .stopped
            assembly.changeStreamFactory.finish()
        case .starting(let task, let installation):
            state = .stopped
            await services.invalidate(installation)
            task.cancel()
            assembly.changeStreamFactory.finish()
            await task.value
        case .installed(let lease, let installation):
            state = .stopped
            await services.invalidate(installation)
            await lease.dispose()
        case .stopped:
            return
        }
    }

    private func runStartup(installation: MutableSearchServices.Installation) async {
        do {
            if let startupPrerequisite { await startupPrerequisite.value }
            guard isAdmitted(installation), !Task.isCancelled else { return }
            let lease = try await registry.assemble(assembly)
            guard isAdmitted(installation), !Task.isCancelled else {
                await lease.dispose()
                return
            }
            await services.install(lease.services, for: installation)
            guard isAdmitted(installation), !Task.isCancelled else {
                await services.invalidate(installation)
                await lease.dispose()
                return
            }
            state = .installed(lease, installation)
            startupError = nil
        } catch is CancellationError {
            assembly.changeStreamFactory.finish()
        } catch {
            guard isAdmitted(installation) else { return }
            startupError = error
            state = .idle
            assembly.changeStreamFactory.finish()
            DebugLog.store("SearchCompositionOwner: runtime assembly failed: \(error)")
        }
    }

    private func isAdmitted(_ installation: MutableSearchServices.Installation) -> Bool {
        guard case .starting(_, let current) = state else { return false }
        return current == installation
    }
}
#endif
