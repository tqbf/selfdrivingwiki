import Foundation
import Testing
@testable import WikiFSCore

struct AppendDerivedMarkdownTests {
    private func source(_ store: GRDBWikiStore) throws -> SourceSummary {
        try store.addSource(filename: "source.pdf", data: Data("pdf".utf8))
    }

    @Test func persistsTypedProducerAndOrigin() throws {
        let store = try TestStoreFactory.inMemory()
        let source = try source(store)
        let version = try store.appendDerivedMarkdown(
            sourceID: source.id, content: "# output", origin: .extraction,
            producer: .backend(.anthropic), providerID: ProviderID(rawValue: "anthropic"),
            modelID: ModelID(rawValue: "model"), toolVersion: nil, sourceVersionID: nil, note: "test")
        let provenance = try #require(try store.extractionProvenance(markdownVersionID: version.id))
        #expect(provenance.origin == .extraction)
        #expect(provenance.producer == .backend(.anthropic))
        #expect(provenance.providerID == ProviderID(rawValue: "anthropic"))
        #expect(provenance.modelID == ModelID(rawValue: "model"))
    }

    @Test func persistsPresentSourceVersion() throws {
        let store = try TestStoreFactory.inMemory()
        let source = try source(store)
        let sourceVersion = try store.appendContentVersion(sourceID: source.id, data: Data("new".utf8), mimeType: nil, provenance: nil)
        let derived = try store.appendDerivedMarkdown(
            sourceID: source.id, content: "# output", origin: .extraction,
            producer: .tool(.pdf2md), providerID: nil, modelID: nil, toolVersion: "1.0",
            sourceVersionID: sourceVersion.id, note: nil)
        #expect(derived.sourceVersionID == sourceVersion.id)
    }

    @Test func persistsAbsentSourceVersion() throws {
        let store = try TestStoreFactory.inMemory()
        let source = try source(store)
        let derived = try store.appendDerivedMarkdown(
            sourceID: source.id, content: "# output", origin: .transcript,
            producer: .tool(.transcript), providerID: nil, modelID: nil, toolVersion: nil,
            sourceVersionID: nil, note: nil)
        #expect(derived.sourceVersionID == nil)
    }

    @Test func newDerivedVersionBecomesActiveAndPriorVersionRemainsAlternative() throws {
        let store = try TestStoreFactory.inMemory()
        let source = try source(store)
        let first = try store.appendDerivedMarkdown(sourceID: source.id, content: "first", origin: .extraction, producer: .tool(.pdf2md), providerID: nil, modelID: nil, toolVersion: nil, sourceVersionID: nil, note: nil)
        let second = try store.appendDerivedMarkdown(sourceID: source.id, content: "second", origin: .extraction, producer: .tool(.docling), providerID: nil, modelID: nil, toolVersion: nil, sourceVersionID: nil, note: nil)
        #expect(try store.processedMarkdownHead(sourceID: source.id)?.id == second.id)
        #expect(try store.processedMarkdownHistory(sourceID: source.id).map(\.id).contains(first.id))
    }

    @Test func rejectsNonDerivedOrigin() throws {
        let store = try TestStoreFactory.inMemory()
        let source = try source(store)
        #expect(throws: AppendDerivedMarkdownError.nonDerivedOrigin(.user)) {
            _ = try store.appendDerivedMarkdown(sourceID: source.id, content: "x", origin: .user, producer: nil, providerID: nil, modelID: nil, toolVersion: nil, sourceVersionID: nil, note: nil)
        }
    }

    @Test func rejectsModelWithoutProviderBackedProducer() throws {
        let store = try TestStoreFactory.inMemory()
        let source = try source(store)
        #expect(throws: AppendDerivedMarkdownError.modelRequiresProviderBackedProducer) {
            _ = try store.appendDerivedMarkdown(sourceID: source.id, content: "x", origin: .extraction, producer: nil, providerID: nil, modelID: ModelID(rawValue: "model"), toolVersion: nil, sourceVersionID: nil, note: nil)
        }
    }

    @Test func rejectsProviderFieldsForLocalTool() throws {
        let store = try TestStoreFactory.inMemory()
        let source = try source(store)
        #expect(throws: AppendDerivedMarkdownError.providerFieldsUnsupportedForLocalTool) {
            _ = try store.appendDerivedMarkdown(sourceID: source.id, content: "x", origin: .extraction, producer: .tool(.docling), providerID: ProviderID(rawValue: "remote"), modelID: nil, toolVersion: nil, sourceVersionID: nil, note: nil)
        }
    }

    @Test func rejectsToolVersionForBackend() throws {
        let store = try TestStoreFactory.inMemory()
        let source = try source(store)
        #expect(throws: AppendDerivedMarkdownError.toolVersionUnsupportedForBackend) {
            _ = try store.appendDerivedMarkdown(sourceID: source.id, content: "x", origin: .extraction, producer: .backend(.gemini), providerID: nil, modelID: nil, toolVersion: "1", sourceVersionID: nil, note: nil)
        }
    }

    @Test func rejectsForeignSourceVersion() throws {
        let store = try TestStoreFactory.inMemory()
        let first = try source(store)
        let second = try store.addSource(filename: "other.pdf", data: Data("other".utf8))
        let otherVersion = try store.appendContentVersion(sourceID: second.id, data: Data("new".utf8), mimeType: nil, provenance: nil)
        #expect(throws: AppendDerivedMarkdownError.foreignSourceVersion(otherVersion.id)) {
            _ = try store.appendDerivedMarkdown(sourceID: first.id, content: "x", origin: .extraction, producer: .tool(.pdf2md), providerID: nil, modelID: nil, toolVersion: nil, sourceVersionID: otherVersion.id, note: nil)
        }
    }

    @Test func rejectsMissingSource() throws {
        let store = try TestStoreFactory.inMemory()
        let missing = SourceID(rawValue: "missing")
        #expect(throws: AppendDerivedMarkdownError.missingSource(missing)) {
            _ = try store.appendDerivedMarkdown(sourceID: missing, content: "x", origin: .extraction, producer: nil, providerID: nil, modelID: nil, toolVersion: nil, sourceVersionID: nil, note: nil)
        }
    }

    @Test func acceptsPermittedNilOptionalFields() throws {
        let store = try TestStoreFactory.inMemory()
        let source = try source(store)
        _ = try store.appendDerivedMarkdown(sourceID: source.id, content: "x", origin: .transcript, producer: .tool(.transcript), providerID: nil, modelID: nil, toolVersion: nil, sourceVersionID: nil, note: nil)
    }

    @Test func validationFailureWritesNothingAndEmitsNothing() async throws {
        let store = try TestStoreFactory.inMemory()
        let source = try source(store)
        let bus = WikiEventBus(wikiID: WikiID(rawValue: "derived-validation"))
        store.eventBus = bus
        let recorder = SignalRecorder()
        bus.subscribe(nil) { recorder.append($0) }

        #expect(throws: AppendDerivedMarkdownError.nonDerivedOrigin(.user)) {
            _ = try store.appendDerivedMarkdown(
                sourceID: source.id, content: "x", origin: .user, producer: nil,
                providerID: nil, modelID: nil, toolVersion: nil, sourceVersionID: nil, note: nil)
        }
        for _ in 0..<3 { await flushBusDeliveries() }
        #expect(recorder.snapshot.isEmpty)
        #expect(try store.processedMarkdownHistory(sourceID: source.id).isEmpty)
    }
}
