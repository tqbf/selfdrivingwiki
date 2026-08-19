#if os(macOS)
import Foundation
import WikiFSCore
import WikiFSSearch

public struct SearchRuntimeIdentity: Equatable, Sendable {
    public let wikiID: WikiID
    public let indexDirectory: URL

    public init(wikiID: WikiID, containerDirectory: URL) {
        self.wikiID = wikiID
        self.indexDirectory = containerDirectory
            .appendingPathComponent("search-index", isDirectory: true)
            .appendingPathComponent(wikiID.rawValue, isDirectory: true)
    }

    public func validate() throws {
        guard !wikiID.rawValue.isEmpty else {
            throw SearchServicesError.invalidIdentity("wiki ID is empty")
        }
        guard indexDirectory.lastPathComponent == wikiID.rawValue,
              indexDirectory.deletingLastPathComponent().lastPathComponent == "search-index"
        else {
            throw SearchServicesError.invalidIdentity("index path does not match wiki ID")
        }
    }
}

/// Owns startup, sequential synchronization, query admission, and disposal for
/// one wiki's derived Tantivy index.
public actor SearchRuntime: SearchServices {
    private enum State { case starting, ready, disposed }

    private let identity: SearchRuntimeIdentity
    private let indexer: TantivyIndexer
    private let markerSource: (any TantivyRebuildMarkerSource)?
    private let streamFactory: any SearchChangeStreamFactory
    private var state: State = .starting
    private var lastSequence: UInt64?
    private var eventTask: Task<Void, Never>?

    public init(
        identity: SearchRuntimeIdentity,
        indexer: TantivyIndexer,
        contentSource: any TantivyContentSource,
        streamFactory: any SearchChangeStreamFactory
    ) {
        self.identity = identity
        self.indexer = indexer
        self.markerSource = contentSource as? any TantivyRebuildMarkerSource
        self.streamFactory = streamFactory
    }

    public func start() async throws {
        guard state == .starting else {
            if state == .disposed { throw SearchServicesError.disposedRuntime }
            return
        }
        try identity.validate()
        let subscription: SearchChangeStreamSubscription
        do {
            subscription = try streamFactory.take()
            try await rebuildIfNeeded()
            try requireStarting()
            for event in subscription.bufferedEvents {
                try await apply(event)
                try requireStarting()
            }
        } catch {
            streamFactory.finish()
            state = .disposed
            throw SearchServicesError.startupFailed(String(describing: error))
        }
        state = .ready
        eventTask = Task { [weak self, stream = subscription.stream] in
            guard let self else { return }
            for await event in stream {
                if Task.isCancelled { break }
                await self.consume(event)
            }
        }
    }

    public func search(
        query: String,
        kinds: [TantivyDocumentKind],
        limit: Int
    ) async throws -> [TantivyShadowSearchResult] {
        try requireReady()
        let results = try await IndexerSearchServices(indexer: indexer)
            .search(query: query, kinds: kinds, limit: limit)
        try requireReady()
        return results
    }

    public func autocomplete(
        partial: String,
        kinds: Set<TantivyDocumentKind>,
        distance: UInt8,
        limit: Int
    ) async throws -> [TantivyShadowSearchResult] {
        try requireReady()
        let results = try await IndexerSearchServices(indexer: indexer).autocomplete(
            partial: partial, kinds: kinds, distance: distance, limit: limit)
        try requireReady()
        return results
    }

    public func dispose() async {
        guard state != .disposed else { return }
        state = .disposed
        let task = eventTask
        eventTask = nil
        task?.cancel()
        streamFactory.finish()
        await task?.value
    }

    private func consume(_ event: ResourceChangeEvent) async {
        guard state == .ready else { return }
        do {
            try await apply(event)
        } catch {
            guard state == .ready else { return }
            DebugLog.store("SearchRuntime[\(identity.wikiID.rawValue)]: event synchronization failed: \(error)")
        }
    }

    private func apply(_ event: ResourceChangeEvent) async throws {
        guard event.wikiID == identity.wikiID else { return }
        if let previous = lastSequence,
           event.seq != previous &+ 1 {
            try await rebuild()
        }
        lastSequence = event.seq
        guard let kind = event.kind else {
            try await rebuild()
            return
        }
        guard let documentKind = Self.documentKind(for: kind) else { return }
        switch event.change {
        case .created, .updated:
            await indexer.upsert(ulid: event.id, kind: documentKind)
        case .deleted:
            await indexer.delete(ulid: event.id, kind: documentKind)
        }
    }

    private func rebuildIfNeeded() async throws {
        let markerRequiresRebuild = await markerSource?.requiresTantivyRebuild() ?? false
        let count = await indexer.count()
        guard markerRequiresRebuild || count == 0 else { return }
        try await rebuild()
        try requireStarting()
        if markerRequiresRebuild {
            await markerSource?.clearTantivyRebuildRequirement()
            try requireStarting()
        }
    }

    private func rebuild() async throws {
        try await indexer.rebuild()
        guard state != .disposed else { throw SearchServicesError.disposedRuntime }
    }

    private func requireStarting() throws {
        guard state == .starting, !Task.isCancelled else {
            throw SearchServicesError.disposedRuntime
        }
    }

    private func requireReady() throws {
        switch state {
        case .ready: return
        case .starting: throw SearchServicesError.unavailable
        case .disposed: throw SearchServicesError.disposedRuntime
        }
    }

    private static func documentKind(for kind: ResourceKind) -> TantivyDocumentKind? {
        switch kind {
        case .page: .page
        case .source: .source
        case .chat: .chat
        case .bookmark, .systemPrompt, .wikiIndex, .log: nil
        }
    }
}
#endif
