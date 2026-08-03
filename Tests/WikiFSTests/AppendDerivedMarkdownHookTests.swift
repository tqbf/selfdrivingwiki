import Foundation
import Testing
@testable import WikiFSCore

struct AppendDerivedMarkdownHookTests {
    private enum InjectedFailure: Error { case checkpoint }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func fileStore(hook: AppendDerivedMarkdownHooks) throws -> GRDBWikiStore {
        let url = try MetadataSQLiteFixtureSupport.fileURL(prefix: "append-derived-hook")
        return try GRDBWikiStore(
            databaseURL: url, schemaV48MigrationHooks: .productionDefault,
            schemaForeignKeyChecker: .productionDefault(), appendDerivedMarkdownHooks: hook)
    }

    @Test func afterInitialWritesCheckpointRunsExactlyOnce() throws {
        let counter = Counter()
        let store = try fileStore(hook: .init(afterInitialWrites: { counter.increment() }))
        let source = try store.addSource(filename: "source.pdf", data: Data("pdf".utf8))
        _ = try store.appendDerivedMarkdown(
            sourceID: source.id, content: "output", origin: .extraction,
            producer: .tool(.pdf2md), providerID: nil, modelID: nil, toolVersion: nil,
            sourceVersionID: nil, note: nil)
        #expect(counter.count == 1)
    }

    @Test func productionAfterInitialWritesHookIsNoOp() throws {
        let store = try TestStoreFactory.inMemory()
        let source = try store.addSource(filename: "source.pdf", data: Data("pdf".utf8))
        _ = try store.appendDerivedMarkdown(
            sourceID: source.id, content: "output", origin: .transcript,
            producer: .tool(.transcript), providerID: nil, modelID: nil, toolVersion: nil,
            sourceVersionID: nil, note: nil)
        #expect(try store.processedMarkdownHead(sourceID: source.id) != nil)
    }

    @Test func injectedAfterInitialWritesFailureRollsBackDerivedVersion() throws {
        let store = try fileStore(hook: .init(afterInitialWrites: { throw InjectedFailure.checkpoint }))
        let source = try store.addSource(filename: "source.pdf", data: Data("pdf".utf8))
        #expect(throws: InjectedFailure.self) {
            _ = try store.appendDerivedMarkdown(
                sourceID: source.id, content: "output", origin: .extraction,
                producer: .tool(.pdf2md), providerID: nil, modelID: nil, toolVersion: nil,
                sourceVersionID: nil, note: nil)
        }
        #expect(try store.processedMarkdownHistory(sourceID: source.id).isEmpty)
        #expect(try store.processedMarkdownHead(sourceID: source.id) == nil)
    }

    @Test func injectedAfterInitialWritesFailureRollsBackActivityPlan() throws {
        let url = try MetadataSQLiteFixtureSupport.fileURL(prefix: "append-derived-activity")
        let store = try GRDBWikiStore(
            databaseURL: url, schemaV48MigrationHooks: .productionDefault,
            schemaForeignKeyChecker: .productionDefault(),
            appendDerivedMarkdownHooks: .init(afterInitialWrites: { throw InjectedFailure.checkpoint }))
        let source = try store.addSource(filename: "source.pdf", data: Data("pdf".utf8))
        #expect(throws: InjectedFailure.self) {
            _ = try store.appendDerivedMarkdown(
                sourceID: source.id, content: "output", origin: .extraction,
                producer: .tool(.pdf2md), providerID: nil, modelID: nil, toolVersion: nil,
                sourceVersionID: nil, note: nil)
        }
        store.close()
        #expect(try MetadataSQLiteFixtureSupport.scalar(
            "SELECT COUNT(*) FROM activities WHERE kind = 'extract';", at: url) == "0")
    }

    @Test func injectedAfterInitialWritesFailureRollsBackSourceVersionLink() throws {
        let store = try fileStore(hook: .init(afterInitialWrites: { throw InjectedFailure.checkpoint }))
        let source = try store.addSource(filename: "source.pdf", data: Data("pdf".utf8))
        let sourceVersion = try store.appendContentVersion(
            sourceID: source.id, data: Data("new".utf8), mimeType: nil, provenance: nil)
        #expect(throws: InjectedFailure.self) {
            _ = try store.appendDerivedMarkdown(
                sourceID: source.id, content: "output", origin: .extraction,
                producer: .tool(.pdf2md), providerID: nil, modelID: nil, toolVersion: nil,
                sourceVersionID: sourceVersion.id, note: nil)
        }
        #expect(try store.processedMarkdownHistory(sourceID: source.id).isEmpty)
    }

    @Test func injectedAfterInitialWritesFailurePreservesPriorHead() throws {
        let url = try MetadataSQLiteFixtureSupport.fileURL(prefix: "append-derived-head")
        let initial = try GRDBWikiStore(databaseURL: url)
        let source = try initial.addSource(filename: "source.pdf", data: Data("pdf".utf8))
        let head = try initial.appendDerivedMarkdown(
            sourceID: source.id, content: "first", origin: .extraction,
            producer: .tool(.pdf2md), providerID: nil, modelID: nil, toolVersion: nil,
            sourceVersionID: nil, note: nil)
        initial.close()

        let failing = try GRDBWikiStore(
            databaseURL: url, schemaV48MigrationHooks: .productionDefault,
            schemaForeignKeyChecker: .productionDefault(),
            appendDerivedMarkdownHooks: .init(afterInitialWrites: { throw InjectedFailure.checkpoint }))
        #expect(throws: InjectedFailure.self) {
            _ = try failing.appendDerivedMarkdown(
                sourceID: source.id, content: "second", origin: .extraction,
                producer: .tool(.docling), providerID: nil, modelID: nil, toolVersion: nil,
                sourceVersionID: nil, note: nil)
        }
        #expect(try failing.processedMarkdownHead(sourceID: source.id)?.id == head.id)
    }

    @Test func injectedAfterInitialWritesFailureRollsBackBlobAndRefcountEffects() throws {
        let url = try MetadataSQLiteFixtureSupport.fileURL(prefix: "append-derived-blob")
        let store = try GRDBWikiStore(
            databaseURL: url, schemaV48MigrationHooks: .productionDefault,
            schemaForeignKeyChecker: .productionDefault(),
            appendDerivedMarkdownHooks: .init(afterInitialWrites: { throw InjectedFailure.checkpoint }))
        let source = try store.addSource(filename: "source.pdf", data: Data("pdf".utf8))
        store.close()
        let before = try MetadataSQLiteFixtureSupport.scalar("SELECT COUNT(*) FROM blobs;", at: url)
        let failing = try GRDBWikiStore(
            databaseURL: url, schemaV48MigrationHooks: .productionDefault,
            schemaForeignKeyChecker: .productionDefault(),
            appendDerivedMarkdownHooks: .init(afterInitialWrites: { throw InjectedFailure.checkpoint }))
        #expect(throws: InjectedFailure.self) {
            _ = try failing.appendDerivedMarkdown(
                sourceID: source.id, content: "new derived body", origin: .extraction,
                producer: .tool(.pdf2md), providerID: nil, modelID: nil, toolVersion: nil,
                sourceVersionID: nil, note: nil)
        }
        failing.close()
        #expect(try MetadataSQLiteFixtureSupport.scalar("SELECT COUNT(*) FROM blobs;", at: url) == before)
    }

    @Test func injectedAfterInitialWritesFailureEmitsNothing() async throws {
        let store = try fileStore(hook: .init(afterInitialWrites: { throw InjectedFailure.checkpoint }))
        let source = try store.addSource(filename: "source.pdf", data: Data("pdf".utf8))
        let bus = WikiEventBus(wikiID: WikiID(rawValue: "derived-hook-failure"))
        store.eventBus = bus
        let recorder = SignalRecorder()
        bus.subscribe(nil) { recorder.append($0) }
        #expect(throws: InjectedFailure.self) {
            _ = try store.appendDerivedMarkdown(
                sourceID: source.id, content: "output", origin: .extraction,
                producer: .tool(.pdf2md), providerID: nil, modelID: nil, toolVersion: nil,
                sourceVersionID: nil, note: nil)
        }
        for _ in 0..<3 { await flushBusDeliveries() }
        #expect(recorder.snapshot.isEmpty)
    }

    @Test func retryAfterInjectedPersistenceFailureSucceeds() throws {
        let databaseURL = try MetadataSQLiteFixtureSupport.fileURL(prefix: "append-derived-retry")
        let failingStore = try GRDBWikiStore(
            databaseURL: databaseURL, schemaV48MigrationHooks: .productionDefault,
            schemaForeignKeyChecker: .productionDefault(),
            appendDerivedMarkdownHooks: .init(afterInitialWrites: { throw InjectedFailure.checkpoint }))
        let source = try failingStore.addSource(filename: "source.pdf", data: Data("pdf".utf8))
        #expect(throws: InjectedFailure.self) {
            _ = try failingStore.appendDerivedMarkdown(
                sourceID: source.id, content: "output", origin: .extraction,
                producer: .tool(.pdf2md), providerID: nil, modelID: nil, toolVersion: nil,
                sourceVersionID: nil, note: nil)
        }

        let retryStore = try GRDBWikiStore(databaseURL: databaseURL)
        let retry = try retryStore.appendDerivedMarkdown(
            sourceID: source.id, content: "output", origin: .extraction,
            producer: .tool(.pdf2md), providerID: nil, modelID: nil, toolVersion: nil,
            sourceVersionID: nil, note: nil)
        #expect(try retryStore.processedMarkdownHead(sourceID: source.id)?.id == retry.id)
    }
}
