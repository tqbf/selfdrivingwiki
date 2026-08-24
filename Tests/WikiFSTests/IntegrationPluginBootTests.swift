#if os(macOS)
import Cordis
import CordisLoader
import Foundation
import Testing
@testable import WikiFSEngine

@Suite("Integration plugin boot", .serialized, .timeLimit(.minutes(1)))
struct IntegrationPluginBootTests {
    @Test("fixture-safe capabilities register lazily and unload")
    func capabilitiesRegisterAndUnload() async throws {
        let calls = IntegrationFactoryCallCounter()
        let entries = [
            Entry(id: EntryID("integrations"), plugin: IntegrationsPlugin.id),
            Entry(
                id: EntryID("zotero"),
                plugin: ZoteroIntegrationPlugin.id,
                config: [
                    "apiBaseURL": .string("https://example.invalid/zotero"),
                    "hasAPIKey": .bool(true),
                ]),
            Entry(id: EntryID("podcast"), plugin: PodcastIntegrationPlugin.id),
            Entry(id: EntryID("url-fetch"), plugin: URLFetchIntegrationPlugin.id),
        ]
        let booted = try await CordisBoot.boot(CordisBoot.Options(
            catalog: try PluginCatalog([
                IntegrationsPlugin.definition,
                ZoteroIntegrationPlugin.definition { baseURL in
                    await calls.record(.zotero)
                    return FixtureIntegrationEntryPoint(value: baseURL.absoluteString)
                },
                PodcastIntegrationPlugin.definition {
                    await calls.record(.podcast)
                    return FixtureIntegrationEntryPoint(value: "podcast")
                },
                URLFetchIntegrationPlugin.definition {
                    await calls.record(.urlFetch)
                    return FixtureIntegrationEntryPoint(value: "url-fetch")
                },
            ]),
            layers: [PatchFile(entries: entries)]))

        let registry = try #require(
            try await booted.context.find(IntegrationServiceKeys.capabilities))
        #expect(await registry.capabilityIDs() == [
            PodcastIntegrationPlugin.capabilityID,
            URLFetchIntegrationPlugin.capabilityID,
            ZoteroIntegrationPlugin.capabilityID,
        ].sorted { $0.rawValue < $1.rawValue })
        #expect(await calls.total == 0)

        let zotero = try #require(await registry.resolve(ZoteroIntegrationPlugin.capabilityID))
        _ = try await zotero.entryPoint()
        #expect(await calls.total == 1)

        try await booted.tree.update(to: entries.filter { $0.id != EntryID("podcast") })
        #expect(await registry.resolve(PodcastIntegrationPlugin.capabilityID) == nil)
        #expect(await registry.resolve(URLFetchIntegrationPlugin.capabilityID) != nil)

        try await booted.shutdown()
    }
}

private enum FixtureIntegrationKind: Sendable {
    case zotero
    case podcast
    case urlFetch
}

private actor IntegrationFactoryCallCounter {
    private(set) var total = 0

    func record(_ kind: FixtureIntegrationKind) {
        total += 1
    }
}

private struct FixtureIntegrationEntryPoint: Sendable {
    let value: String
}
#endif
