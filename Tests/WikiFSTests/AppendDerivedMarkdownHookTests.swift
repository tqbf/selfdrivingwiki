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
