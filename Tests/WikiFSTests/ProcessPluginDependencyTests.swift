#if os(macOS)
import Cordis
import CordisLoader
import Testing
import WikiFSCore
@testable import WikiFSEngine

@Suite("Process plugin dependencies", .serialized, .timeLimit(.minutes(1)))
struct ProcessPluginDependencyTests {
    @Test("process inputs settle independently of definition registration order")
    func shuffledDefinitionsSettle() async throws {
        let factories = ProcessPluginCatalogFactories(
            compositionInputs: ProfileBootFixture.fixtureProcessInputs(),
            makeEmbeddings: {
                ProcessRuntimeLease(service: .unavailable(identifier: "unavailable-fixture"), dispose: {})
            })
        let catalog = try PluginCatalog(ProcessRuntimePlugins.definitions(factories).reversed())
        let entries = [
            Entry(id: EntryID("inputs"), plugin: ProcessRuntimePlugins.inputsID),
            Entry(id: EntryID("agent"), plugin: ProcessRuntimePlugins.agentProviderID),
            Entry(id: EntryID("extraction"), plugin: ProcessRuntimePlugins.extractionID),
        ]

        let booted = try await CordisBoot.boot(.init(
            catalog: catalog,
            layers: [PatchFile(entries: entries)]))
        _ = try #require(try await booted.context.find(ProcessServiceKeys.agentProvider))
        _ = try #require(try await booted.context.find(ProcessServiceKeys.extraction))
        try await booted.shutdown()
    }

    @Test("removing runtime components invalidates retained stable facades")
    func removalInvalidatesFacades() async throws {
        let agentServices = MutableAgentProviderServices()
        let extractionServices = MutableExtractionServices()
        let fixtureInputs = ProfileBootFixture.fixtureProcessInputs()
        let inputs = ProcessCompositionInputs(
            agentProvider: AgentProviderProcessInput(
                services: agentServices,
                readConfiguration: fixtureInputs.agentProvider.readConfiguration,
                resolveCommand: fixtureInputs.agentProvider.resolveCommand,
                readCredential: fixtureInputs.agentProvider.readCredential,
                resolvePermissionPolicy: fixtureInputs.agentProvider.resolvePermissionPolicy),
            extraction: ExtractionProcessInput(
                services: extractionServices,
                readConfiguration: fixtureInputs.extraction.readConfiguration,
                readCredential: fixtureInputs.extraction.readCredential,
                resolveACP: fixtureInputs.extraction.resolveACP,
                httpFetcher: fixtureInputs.extraction.httpFetcher,
                makeLocalExtractor: fixtureInputs.extraction.makeLocalExtractor))
        let factories = ProcessPluginCatalogFactories(
            compositionInputs: inputs,
            makeEmbeddings: {
                ProcessRuntimeLease(service: .unavailable(identifier: "unavailable-fixture"), dispose: {})
            })
        let entries = [
            Entry(id: EntryID("inputs"), plugin: ProcessRuntimePlugins.inputsID),
            Entry(id: EntryID("agent"), plugin: ProcessRuntimePlugins.agentProviderID),
            Entry(id: EntryID("extraction"), plugin: ProcessRuntimePlugins.extractionID),
        ]
        let booted = try await CordisBoot.boot(.init(
            catalog: try ProcessPluginCatalog.build(factories: factories),
            layers: [PatchFile(entries: entries)]))
        let retainedAgent = try await booted.context.require(ProcessServiceKeys.agentProvider)
        let retainedExtraction = try await booted.context.require(ProcessServiceKeys.extraction)

        try await booted.tree.update(to: [entries[0]])

        do {
            _ = try await retainedAgent.prepareSummarization()
            Issue.record("retained agent facade accepted work after component removal")
        } catch let error as AgentProviderRuntimeError {
            #expect(error == .unavailable)
        }
        do {
            _ = try await retainedExtraction.prepare(backendOverride: Optional<ExtractionBackend>.none)
            Issue.record("retained extraction facade accepted work after component removal")
        } catch let error as ExtractionServicesError {
            #expect(error == .unavailable)
        }
        try await booted.shutdown()
    }
}
#endif
