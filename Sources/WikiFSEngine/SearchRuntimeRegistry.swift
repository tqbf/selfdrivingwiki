#if os(macOS)
import Cordis
import Foundation
import WikiFSCore
import WikiFSSearch

public enum SearchRuntimeRegistryError: Error, Equatable, Sendable {
    case shuttingDown
    case wikiAlreadyActive(WikiID)
}

public actor SearchRuntimeLease {
    public nonisolated let wikiID: WikiID
    public nonisolated let services: any SearchServices
    fileprivate let token: UUID
    private let releaseOperation: @Sendable (WikiID, UUID) async -> Void
    private var released = false

    fileprivate init(
        wikiID: WikiID,
        services: any SearchServices,
        token: UUID,
        release: @escaping @Sendable (WikiID, UUID) async -> Void
    ) {
        self.wikiID = wikiID
        self.services = services
        self.token = token
        self.releaseOperation = release
    }

    public func dispose() async {
        guard !released else { return }
        released = true
        await releaseOperation(wikiID, token)
    }
}

/// Process-scope owner of one private root context and independently serialized
/// per-wiki child lifetimes.
public actor SearchRuntimeRegistry {
    private struct Active: Sendable {
        let token: UUID
        let handle: SearchRuntimeHandle
    }

    private struct Starting: Sendable {
        let token: UUID
        var childContext: CordisContext?
    }

    private struct Retiring: Sendable {
        let token: UUID
        let task: Task<Void, Never>
    }

    private let rootContext: CordisContext
    private var active: [WikiID: Active] = [:]
    private var starting: [WikiID: Starting] = [:]
    private var startDrainWaiters: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var retiring: [WikiID: Retiring] = [:]
    private var shuttingDown = false
    private var didDisposeRoot = false

    public init() {
        rootContext = CordisContext()
    }

    public func assemble(_ assembly: SearchRuntimeAssembly) async throws -> SearchRuntimeLease {
        try await assemble(SearchRuntimeFactory(
            identity: assembly.identity,
            changeStreamFactory: assembly.changeStreamFactory,
            assemble: { context in try await assembly.assemble(in: context) }))
    }

    public func assemble(_ runtime: SearchRuntimeFactory) async throws -> SearchRuntimeLease {
        guard !shuttingDown else { throw SearchRuntimeRegistryError.shuttingDown }
        let wikiID = runtime.identity.wikiID
        guard active[wikiID] == nil, starting[wikiID] == nil else {
            throw SearchRuntimeRegistryError.wikiAlreadyActive(wikiID)
        }
        let startToken = UUID()
        starting[wikiID] = Starting(token: startToken, childContext: nil)
        defer {
            if starting[wikiID]?.token == startToken {
                starting[wikiID] = nil
                finishStartDrainWaitersIfNeeded()
            }
        }
        if let prior = retiring[wikiID] {
            await prior.task.value
            guard !shuttingDown else { throw SearchRuntimeRegistryError.shuttingDown }
            if retiring[wikiID]?.token == prior.token { retiring[wikiID] = nil }
        }
        let child = try await rootContext.child()
        guard starting[wikiID]?.token == startToken, !shuttingDown else {
            try await child.dispose()
            throw SearchRuntimeRegistryError.shuttingDown
        }
        starting[wikiID]?.childContext = child
        let handle = try await runtime.assemble(in: child)
        guard !shuttingDown else {
            try await handle.dispose()
            throw SearchRuntimeRegistryError.shuttingDown
        }
        let token = UUID()
        active[wikiID] = Active(token: token, handle: handle)
        return SearchRuntimeLease(
            wikiID: wikiID,
            services: handle.services,
            token: token,
            release: { [weak self] wikiID, token in
                await self?.release(wikiID: wikiID, token: token)
            })
    }

    public func shutdown() async {
        guard !didDisposeRoot else { return }
        shuttingDown = true
        let startingChildren = starting.values.compactMap(\.childContext)
        for child in startingChildren {
            do {
                try await child.dispose()
            } catch {
                DebugLog.store("SearchRuntimeRegistry: starting child disposal failed: \(error)")
            }
        }
        await waitForStartsToDrain()
        let current = active
        active.removeAll()
        for (wikiID, entry) in current {
            beginRetirement(wikiID: wikiID, handle: entry.handle)
        }
        let tasks = Array(retiring.values)
        for retirement in tasks { await retirement.task.value }
        retiring.removeAll()
        do {
            try await rootContext.dispose()
            didDisposeRoot = true
        } catch {
            DebugLog.store("SearchRuntimeRegistry: root disposal failed: \(error)")
        }
    }

    private func waitForStartsToDrain() async {
        guard !starting.isEmpty else { return }
        let pair = AsyncStream<Void>.makeStream()
        let id = UUID()
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStartDrainWaiter(id) }
        }
        startDrainWaiters[id] = pair.continuation
        for await _ in pair.stream { break }
    }

    private func removeStartDrainWaiter(_ id: UUID) {
        startDrainWaiters[id] = nil
    }

    private func finishStartDrainWaitersIfNeeded() {
        guard starting.isEmpty else { return }
        let waiters = Array(startDrainWaiters.values)
        startDrainWaiters.removeAll()
        for waiter in waiters { waiter.finish() }
    }

    private func release(wikiID: WikiID, token: UUID) async {
        guard let entry = active[wikiID], entry.token == token else {
            if let retirement = retiring[wikiID] { await retirement.task.value }
            return
        }
        active[wikiID] = nil
        let retirement = beginRetirement(wikiID: wikiID, handle: entry.handle)
        await retirement.task.value
        if retiring[wikiID]?.token == retirement.token { retiring[wikiID] = nil }
    }

    @discardableResult
    private func beginRetirement(wikiID: WikiID, handle: SearchRuntimeHandle) -> Retiring {
        let token = UUID()
        let task = Task {
            do {
                try await handle.dispose()
            } catch {
                DebugLog.store("SearchRuntimeRegistry[\(wikiID.rawValue)]: child disposal failed: \(error)")
            }
        }
        let retirement = Retiring(token: token, task: task)
        retiring[wikiID] = retirement
        return retirement
    }
}
#endif
