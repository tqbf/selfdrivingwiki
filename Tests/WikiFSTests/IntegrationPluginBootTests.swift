#if os(macOS)
import Cordis
import CordisLoader
import Foundation
import Testing
import WikiFSCore
@testable import WikiFSEngine

@Suite("Integration plugin boot", .serialized, .timeLimit(.minutes(1)))
struct IntegrationPluginBootTests {
    @Test("typed capabilities resolve injected providers lazily and unload")
    func capabilitiesRegisterAndUnload() async throws {
        let calls = IntegrationFactoryCallCounter()
        let entries = [
            Entry(id: EntryID("url-provider"), plugin: ProcessRuntimePlugins.urlFetchProviderID),
            Entry(id: EntryID("integrations"), plugin: IntegrationsPlugin.id),
            Entry(id: EntryID("url-fetch"), plugin: URLFetchIntegrationPlugin.id),
        ]
        let booted = try await CordisBoot.boot(CordisBoot.Options(
            catalog: try PluginCatalog([
                IntegrationsPlugin.definition,
                URLFetchIntegrationPlugin.definition,
                processURLProviderDefinition(calls: calls),
            ]),
            layers: [PatchFile(entries: entries)]))

        let registry = try #require(
            try await booted.context.find(IntegrationServiceKeys.capabilities))
        #expect(await registry.capabilityIDs() == [URLFetchIntegrationPlugin.capabilityID])
        #expect(calls.urlFetch == 0)

        let urlCapability = try #require(await registry.resolve(URLFetchIntegrationPlugin.capabilityID))
        guard case .urlFetch = try await urlCapability.entryPoint() else {
            Issue.record("URL capability returned the wrong typed entry point")
            return
        }
        #expect(calls.urlFetch == 1)

        try await booted.tree.update(to: entries.filter { $0.id != EntryID("url-fetch") })
        #expect(await registry.resolve(URLFetchIntegrationPlugin.capabilityID) == nil)

        try await booted.shutdown()
    }

    @Test("an adapter fails settlement without its declared process provider")
    func adapterFailsWithoutDeclaredProvider() async throws {
        let options = CordisBoot.Options(
            catalog: try PluginCatalog([
                IntegrationsPlugin.definition,
                URLFetchIntegrationPlugin.definition,
            ]),
            layers: [PatchFile(entries: [
                Entry(id: EntryID("integrations"), plugin: IntegrationsPlugin.id),
                Entry(id: EntryID("url-fetch"), plugin: URLFetchIntegrationPlugin.id),
            ])])

        do {
            let booted = try await CordisBoot.boot(options)
            try await booted.shutdown()
            Issue.record("profile boot succeeded without the URL fetch provider")
        } catch {
            #expect(String(describing: error).contains("url-fetch"))
            #expect(String(describing: error).contains("pending"))
        }
    }

    private func processURLProviderDefinition(
        calls: IntegrationFactoryCallCounter
    ) -> PluginDefinition {
        processDefinition(
            id: ProcessRuntimePlugins.urlFetchProviderID,
            key: ProcessServiceKeys.urlFetchProvider,
            service: URLFetchProvider(makeFetcher: {
                calls.recordURLFetch()
                return FixtureURLFetcher()
            }))
    }

    private func processDefinition<Service: Sendable>(
        id: PluginID,
        key: ServiceKey<Service>,
        service: Service
    ) -> PluginDefinition {
        PluginDefinition(id: id, provisions: [ServiceDependency(key)]) {
            try ComponentDefinition(label: id.rawValue, provisions: [ServiceDependency(key)]) { activation in
                _ = try await activation.supply(key, value: service)
            }
        }
    }
}

/// Test-only synchronization invariant: every mutable field is accessed while
/// `lock` is held, and no reference to protected state escapes the lock scope.
private final class IntegrationFactoryCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var urlFetchCount = 0

    var urlFetch: Int { lock.withLock { urlFetchCount } }

    func recordURLFetch() {
        lock.withLock { urlFetchCount += 1 }
    }
}

private struct FixtureURLFetcher: URLFetchService.URLResourceFetcher {
    func fetch(_ url: URL) async throws -> URLFetchService.FetchResponse {
        URLFetchService.FetchResponse(data: Data(), contentType: nil, finalURL: url)
    }
}
#endif
