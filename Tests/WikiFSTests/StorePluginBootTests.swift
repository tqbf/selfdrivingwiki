#if os(macOS)
import Cordis
import CordisLoader
import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine

@Suite("Store plugin boot", .serialized, .timeLimit(.minutes(1)))
struct StorePluginBootTests {
    private actor EventRecorder {
        private(set) var events: [ResourceChangeEvent] = []

        func append(_ event: ResourceChangeEvent) {
            events.append(event)
        }
    }

    @Test("disposal cancels and awaits in-flight store event forwarding")
    func disposalStopsInFlightForwarding() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-plugin-disposal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("could not remove store forwarding fixture: \(error)") }
        }
        let gate = StoreForwardingGate()
        let databaseURL = directory.appendingPathComponent("wiki.sqlite", isDirectory: false)
        let layer = PatchFile(entries: [Entry(
            id: EntryID("store"),
            plugin: StorePlugin.id,
            config: [
                "databasePath": .string(databaseURL.path),
                "wikiID": .string("store-forwarding-disposal"),
            ])])
        let booted = try await CordisBoot.boot(.init(
            catalog: try PluginCatalog([StorePlugin.makeDefinition { _ in await gate.wait() }]),
            layers: [layer]))
        let store = try #require(try await booted.context.find(StoreServiceKeys.store))
        let readService = try #require(try await booted.context.find(StoreServiceKeys.readService))
        let resolvedAgain = try #require(try await booted.context.find(StoreServiceKeys.readService))
        #expect(readService === resolvedAgain)
        _ = try await readService.asyncRead { try $0.listSources().count }
        let recorder = EventRecorder()
        _ = try await booted.context.on(StoreEventKeys.resourceChange) { event in
            await recorder.append(event)
        }

        _ = try store.createPage(title: "Paused forwarding")
        await gate.awaitArrival()
        let disposal = Task { try await booted.tree.dispose() }
        await gate.awaitCancellation()
        #expect(!disposal.isCancelled)
        await gate.open()
        try await disposal.value

        #expect(await recorder.events.isEmpty)
        await #expect(throws: WikiReadServiceError.unavailable) {
            try await readService.asyncRead { try $0.listSources().count }
        }
        try await booted.context.dispose()
    }

    @Test("boot supplies the store and bridges changes until listener disposal")
    func bootSuppliesStoreAndBridgesChangesUntilDisposal() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-plugin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("could not remove store plugin fixture: \(error)")
            }
        }
        let databaseURL = directory.appendingPathComponent("wiki.sqlite", isDirectory: false)
        let wikiID = WikiID(rawValue: "store-plugin-test")
        let layer = PatchFile(entries: [
            Entry(
                id: EntryID("store"),
                plugin: StorePlugin.id,
                config: [
                    "databasePath": .string(databaseURL.path),
                    "wikiID": .string(wikiID.rawValue),
                ])
        ])
        let booted = try await CordisBoot.boot(CordisBoot.Options(
            catalog: try PluginCatalog([StorePlugin.definition]),
            layers: [layer]))

        let service = try #require(try await booted.context.find(StoreServiceKeys.store))
        let recorder = EventRecorder()
        let listener = try await booted.context.on(StoreEventKeys.resourceChange) { event in
            await recorder.append(event)
        }

        let page = try service.createPage(title: "Cordis store bridge")
        for _ in 0..<100 where await recorder.events.isEmpty {
            await MainActor.run { }
            await Task.yield()
        }
        let event = try #require(await recorder.events.first)
        #expect(event.wikiID == wikiID)
        #expect(event.kind == .page)
        #expect(event.id == page.id.rawValue)
        #expect(event.change == .created)

        try await listener.dispose()
        let countAfterDisposal = await recorder.events.count
        try service.updatePage(id: page.id, title: page.title, body: "after disposal")
        for _ in 0..<10 {
            await MainActor.run { }
            await Task.yield()
        }
        #expect(await recorder.events.count == countAfterDisposal)

        try await booted.shutdown()
    }
}

private actor StoreForwardingGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private let arrivals: AsyncStream<Void>
    private let arrivalContinuation: AsyncStream<Void>.Continuation
    private let cancellations: AsyncStream<Void>
    private let cancellationContinuation: AsyncStream<Void>.Continuation

    init() {
        let arrivalPair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        arrivals = arrivalPair.stream
        arrivalContinuation = arrivalPair.continuation
        let cancellationPair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        cancellations = cancellationPair.stream
        cancellationContinuation = cancellationPair.continuation
    }

    func wait() async {
        arrivalContinuation.yield(())
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in waiter = continuation }
        } onCancel: {
            cancellationContinuation.yield(())
        }
    }

    func awaitArrival() async {
        for await _ in arrivals { return }
    }

    func awaitCancellation() async {
        for await _ in cancellations { return }
    }

    func open() {
        waiter?.resume()
        waiter = nil
        arrivalContinuation.finish()
        cancellationContinuation.finish()
    }
}
#endif
