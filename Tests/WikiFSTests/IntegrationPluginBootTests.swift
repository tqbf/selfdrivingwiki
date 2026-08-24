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
        let configuration = ZoteroConfigurationFixture()
        let entries = [
            Entry(id: EntryID("url-provider"), plugin: ProcessRuntimePlugins.urlFetchProviderID),
            Entry(id: EntryID("zotero-provider"), plugin: ProcessRuntimePlugins.zoteroClientProviderID),
            Entry(id: EntryID("integrations"), plugin: IntegrationsPlugin.id),
            Entry(
                id: EntryID("zotero"),
                plugin: ZoteroIntegrationPlugin.id,
                config: [
                    "apiBaseURL": .string("https://example.invalid/zotero"),
                    "hasAPIKey": .bool(true),
                ]),
            Entry(id: EntryID("url-fetch"), plugin: URLFetchIntegrationPlugin.id),
        ]
        let booted = try await CordisBoot.boot(CordisBoot.Options(
            catalog: try PluginCatalog([
                IntegrationsPlugin.definition,
                ZoteroIntegrationPlugin.definition,
                URLFetchIntegrationPlugin.definition,
                processURLProviderDefinition(calls: calls),
                processZoteroProviderDefinition(configuration: configuration, calls: calls),
            ]),
            layers: [PatchFile(entries: entries)]))

        let registry = try #require(
            try await booted.context.find(IntegrationServiceKeys.capabilities))
        #expect(await registry.capabilityIDs() == [
            URLFetchIntegrationPlugin.capabilityID,
            ZoteroIntegrationPlugin.capabilityID,
        ].sorted { $0.rawValue < $1.rawValue })
        #expect(calls.total == 0)

        let urlCapability = try #require(await registry.resolve(URLFetchIntegrationPlugin.capabilityID))
        guard case .urlFetch = try await urlCapability.entryPoint() else {
            Issue.record("URL capability returned the wrong typed entry point")
            return
        }
        #expect(calls.urlFetch == 1)

        let zoteroCapability = try #require(await registry.resolve(ZoteroIntegrationPlugin.capabilityID))
        guard case .zotero = try await zoteroCapability.entryPoint() else {
            Issue.record("Zotero capability returned the wrong typed entry point")
            return
        }
        await configuration.replace(libraryID: "later-library", apiKey: "later-key")
        guard case .zotero = try await zoteroCapability.entryPoint() else {
            Issue.record("Zotero capability returned the wrong typed entry point after settings changed")
            return
        }
        #expect(calls.zotero == 2)
        #expect(configuration.readCount == 2)

        try await booted.tree.update(to: entries.filter { $0.id != EntryID("zotero") })
        #expect(await registry.resolve(ZoteroIntegrationPlugin.capabilityID) == nil)
        #expect(await registry.resolve(URLFetchIntegrationPlugin.capabilityID) != nil)

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

    private func processZoteroProviderDefinition(
        configuration: ZoteroConfigurationFixture,
        calls: IntegrationFactoryCallCounter
    ) -> PluginDefinition {
        processDefinition(
            id: ProcessRuntimePlugins.zoteroClientProviderID,
            key: ProcessServiceKeys.zoteroClientProvider,
            service: ZoteroClientProvider(
                readConfiguration: { configuration.snapshot() },
                readCredential: { configuration.credential() },
                makeFetcher: {
                    calls.recordZotero()
                    return FixtureZoteroFetcher()
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
    private var zoteroCount = 0

    var urlFetch: Int { lock.withLock { urlFetchCount } }
    var zotero: Int { lock.withLock { zoteroCount } }
    var total: Int { lock.withLock { urlFetchCount + zoteroCount } }

    func recordURLFetch() {
        lock.withLock { urlFetchCount += 1 }
    }

    func recordZotero() {
        lock.withLock { zoteroCount += 1 }
    }
}

private final class ZoteroConfigurationFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var libraryID = "initial-library"
    private var apiKey = "initial-key"
    private var reads = 0

    var readCount: Int {
        lock.withLock { reads }
    }

    func snapshot() -> ZoteroConfig {
        lock.withLock {
            reads += 1
            return ZoteroConfig(libraryID: libraryID)
        }
    }

    func credential() -> String? {
        lock.withLock { apiKey }
    }

    func replace(libraryID: String, apiKey: String) async {
        lock.withLock {
            self.libraryID = libraryID
            self.apiKey = apiKey
        }
    }
}

private struct FixtureURLFetcher: URLFetchService.URLResourceFetcher {
    func fetch(_ url: URL) async throws -> URLFetchService.FetchResponse {
        URLFetchService.FetchResponse(data: Data(), contentType: nil, finalURL: url)
    }
}

private struct FixtureZoteroFetcher: ZoteroClient.RequestFetcher {
    func fetch(_ request: URLRequest) async throws -> (data: Data, statusCode: Int) {
        (Data("[]".utf8), 200)
    }
}
#endif
