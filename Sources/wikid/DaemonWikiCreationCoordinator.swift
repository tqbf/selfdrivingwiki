#if canImport(WikiFSEngine)
import Foundation
import WikiFSCore
import WikiFSEngine

struct DaemonRegistryPersistence: Sendable {
    let save: @Sendable (WikiRegistry, URL) throws -> Void

    init(save: @escaping @Sendable (WikiRegistry, URL) throws -> Void = { registry, directory in
        try registry.save(to: directory)
    }) {
        self.save = save
    }
}

enum DaemonWikiCreationError: Error, Sendable {
    case shutdownStarted
    case reservationLost(WikiID)
}

actor DaemonWikiCreationCoordinator {
    struct RequestID: Hashable, Sendable {
        let rawValue: UUID
        init() { rawValue = UUID() }
    }

    enum State: Equatable, Sendable {
        case bootstrapping
        case persistingRegistry
        case preparingProfile
        case publishing
        case succeeded
        case failed
    }

    typealias PersistDescriptor = @Sendable (WikiDescriptor) throws -> Void
    typealias RemoveDescriptor = @Sendable (WikiID) throws -> Void
    typealias PrepareProfile = @Sendable (WikiID) async throws -> Void
    typealias RemoveProfile = @Sendable (WikiID) async -> Void
    typealias DeleteArtifacts = @Sendable (WikiID) throws -> Void

    private struct Request: Sendable {
        let id: RequestID
        let wikiID: WikiID
        var state: State
    }

    private let containerDirectory: URL
    private let bootstrap: StoreBootstrap
    private let persistDescriptor: PersistDescriptor
    private let removeDescriptor: RemoveDescriptor
    private let prepareProfile: PrepareProfile
    private let removeProfile: RemoveProfile
    private let deleteArtifacts: DeleteArtifacts
    private var requests: [WikiID: Request] = [:]
    private var settlementWaiters: [WikiID: [CheckedContinuation<Void, Never>]] = [:]
    private var shutdownStarted = false

    init(
        containerDirectory: URL,
        bootstrap: StoreBootstrap,
        persistDescriptor: @escaping PersistDescriptor,
        removeDescriptor: @escaping RemoveDescriptor,
        prepareProfile: @escaping PrepareProfile,
        removeProfile: @escaping RemoveProfile,
        deleteArtifacts: @escaping DeleteArtifacts
    ) {
        self.containerDirectory = containerDirectory
        self.bootstrap = bootstrap
        self.persistDescriptor = persistDescriptor
        self.removeDescriptor = removeDescriptor
        self.prepareProfile = prepareProfile
        self.removeProfile = removeProfile
        self.deleteArtifacts = deleteArtifacts
    }

    func createWiki(name: String) async throws -> WikiDescriptor {
        guard !shutdownStarted else { throw DaemonWikiCreationError.shutdownStarted }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var descriptor = WikiDescriptor.make(displayName: trimmed.isEmpty ? "Untitled Wiki" : trimmed)
        let requestID = RequestID()
        requests[descriptor.id] = Request(id: requestID, wikiID: descriptor.id, state: .bootstrapping)
        let databaseURL = containerDirectory.appendingPathComponent("\(descriptor.id.rawValue).sqlite", isDirectory: false)
        var registryPersisted = false

        do {
            let result = try await Self.bootstrap(bootstrap, databaseURL: databaseURL)
            try Task.checkCancellation()
            descriptor.homePageID = result.homePageID
            try ensureAdmitted(descriptor.id, requestID: requestID, state: .persistingRegistry)
            try persistDescriptor(descriptor)
            registryPersisted = true
            try ensureAdmitted(descriptor.id, requestID: requestID, state: .preparingProfile)
            try await prepareProfile(descriptor.id)
            try Task.checkCancellation()
            try ensureAdmitted(descriptor.id, requestID: requestID, state: .publishing)
            requests[descriptor.id]?.state = .succeeded
            finishRequest(descriptor.id)
            return descriptor
        } catch {
            requests[descriptor.id]?.state = .failed
            if registryPersisted {
                await removeProfile(descriptor.id)
                do { try removeDescriptor(descriptor.id) }
                catch { DebugLog.store("wikid: registry rollback failed for \(descriptor.id.rawValue): \(error)") }
            }
            do { try deleteArtifacts(descriptor.id) }
            catch { DebugLog.store("wikid: artifact rollback failed for \(descriptor.id.rawValue): \(error)") }
            finishRequest(descriptor.id)
            throw error
        }
    }

    func beginShutdown() {
        guard !shutdownStarted else { return }
        shutdownStarted = true
    }

    func awaitCreationSettlement(wikiID: WikiID) async {
        guard requests[wikiID] != nil else { return }
        await withCheckedContinuation { continuation in
            settlementWaiters[wikiID, default: []].append(continuation)
        }
    }

    func state(for wikiID: WikiID) -> State? {
        requests[wikiID]?.state
    }

    private func finishRequest(_ wikiID: WikiID) {
        requests.removeValue(forKey: wikiID)
        let waiters = settlementWaiters.removeValue(forKey: wikiID) ?? []
        for waiter in waiters { waiter.resume() }
    }

    private nonisolated static func bootstrap(
        _ bootstrap: StoreBootstrap,
        databaseURL: URL
    ) async throws -> StoreBootstrapResult {
        try Task.checkCancellation()
        return try bootstrap.createAndSeed(databaseURL: databaseURL)
    }

    private func ensureAdmitted(_ wikiID: WikiID, requestID: RequestID, state: State) throws {
        guard !shutdownStarted else { throw DaemonWikiCreationError.shutdownStarted }
        guard requests[wikiID]?.id == requestID else {
            throw DaemonWikiCreationError.reservationLost(wikiID)
        }
        requests[wikiID]?.state = state
    }
}
#endif
