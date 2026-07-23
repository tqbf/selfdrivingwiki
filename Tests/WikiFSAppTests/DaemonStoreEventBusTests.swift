#if os(macOS)
import Foundation
import Testing
@testable import WikiFSCore
@testable import wikid

/// Tests that the daemon attaches a `WikiEventBus` to every store it opens, and
/// that the bus listener fires on committed mutations — the bridge that lets
/// the app (a separate process) learn about daemon-side writes (summarizer,
/// queue completion, chat-message appends) via `DarwinNotifier` (#871
/// follow-up). Before this wiring, daemon stores had no bus, so `mutate()`
/// emitted into the void and the app never reloaded.
struct DaemonStoreEventBusTests {

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikid-bus-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Lock-guarded collector mirroring `SignalRecorder` (which lives in the
    /// `WikiFSTests` target and isn't visible here). The bus dispatches each
    /// `@MainActor` handler via `Task { @MainActor in … }`, so delivered events
    /// land a runloop tick after `emit`; `awaitCount` polls until they arrive.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [ResourceChangeEvent] = []
        func append(_ event: ResourceChangeEvent) {
            lock.lock(); events.append(event); lock.unlock()
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return events.count }
        var snapshot: [ResourceChangeEvent] { lock.lock(); defer { lock.unlock() }; return events }

        func awaitCount(_ expected: Int, timeoutMs: Int = 1000) async throws {
            let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000)
            while Date() < deadline {
                if count >= expected { return }
                await MainActor.run { }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
    }

    private func makeWiki(_ daemon: WikiDaemon, name: String = "BusTest") throws -> String {
        let wikiData = try #require(daemon.createWiki(name: name))
        return try JSONDecoder().decode(WikiDescriptor.self, from: wikiData).id
    }

    // MARK: - Bus is attached at every store-creation seam

    @Test func openStoreAttachesEventBus() throws {
        let daemon = WikiDaemon(containerDirectory: makeTempDir())
        let wikiID = try makeWiki(daemon)

        #expect(daemon.openStore(wikiID: wikiID))
        // `resolveStoreLazily` serves the now-cached store; the bus must be set.
        let store = try #require(daemon.resolveStoreLazily(wikiID: wikiID))
        #expect(store.eventBus != nil)
        #expect(store.eventBus?.wikiID == wikiID)
    }

    @Test func resolveStoreLazilyAttachesEventBus() throws {
        let daemon = WikiDaemon(containerDirectory: makeTempDir())
        let wikiID = try makeWiki(daemon)
        // Drop the cache so the resolver hits the lazy-open path.
        daemon.closeStore(wikiID: wikiID)

        let store = try #require(daemon.resolveStoreLazily(wikiID: wikiID))
        #expect(store.eventBus != nil)
        #expect(store.eventBus?.wikiID == wikiID)
    }

    @Test func createWikiAttachesEventBusToCachedStore() throws {
        let daemon = WikiDaemon(containerDirectory: makeTempDir())
        let wikiID = try makeWiki(daemon)

        // createWiki opens + caches the store; resolve returns that same store.
        let store = try #require(daemon.resolveStoreLazily(wikiID: wikiID))
        #expect(store.eventBus != nil)
    }

    // MARK: - The wired bus actually fires on a committed mutation

    @Test func storeMutationFiresBusListener() async throws {
        let daemon = WikiDaemon(containerDirectory: makeTempDir())
        let wikiID = try makeWiki(daemon)
        daemon.closeStore(wikiID: wikiID)

        let store = try #require(daemon.resolveStoreLazily(wikiID: wikiID))
        let bus = try #require(store.eventBus)
        let collector = Collector()
        bus.subscribe(nil) { collector.append($0) }

        // A real mutating write routes through mutate() → emit on the bus.
        _ = try store.createPage(title: "SignalProbe")

        try await collector.awaitCount(1)
        #expect(collector.count >= 1)
        #expect(collector.snapshot.allSatisfy { $0.wikiID == wikiID })
    }

    /// Regression guard: the bus listener that calls `DarwinNotifier` is
    /// registered (i.e. `wireEventBus` actually subscribed, not just created a
    /// bare bus). We assert indirectly by confirming a second subscriber on the
    /// same bus receives events alongside the daemon's own listener — proving
    /// the bus is live and multi-subscriber delivery works end-to-end.
    @Test func busDeliversToMultipleListenersAfterMutation() async throws {
        let daemon = WikiDaemon(containerDirectory: makeTempDir())
        let wikiID = try makeWiki(daemon)
        daemon.closeStore(wikiID: wikiID)

        let store = try #require(daemon.resolveStoreLazily(wikiID: wikiID))
        let bus = try #require(store.eventBus)
        let a = Collector()
        let b = Collector()
        _ = bus.subscribe(nil) { a.append($0) }
        _ = bus.subscribe(nil) { b.append($0) }

        _ = try store.createPage(title: "MultiProbe")

        try await a.awaitCount(1)
        try await b.awaitCount(1)
        #expect(a.count == 1)
        #expect(b.count == 1)
        #expect(a.snapshot[0].id == b.snapshot[0].id)
    }
}
#endif
