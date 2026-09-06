#if os(macOS)
import Cordis
import CordisLoader
import Foundation
import Testing
import WikiFSTypes
@testable import WikiCtlCore
@testable import WikiFSCore
@testable import WikiFSEngine
@testable import WikiFS

/// AC.3: store/model, CLI, and unavailable-services composition legs for the
/// source-type catalog. The SessionManager fan-out leg lives in the
/// WikiFSTests target where the session fixtures are.
@Suite("Renderer source-type composition", .serialized, .timeLimit(.minutes(3)))
struct RendererSourceTypeCompositionTests {
    @Test func liveSessionsReceiveCatalog() async throws {
        let store = try makeStore()
        let catalog = MermaidCompositionFixtures.catalog
        await MainActor.run {
            let model = WikiStoreModel(store: store)
            model.registeredRendererSourceTypes = catalog
            #expect(store.registeredRendererSourceTypes == catalog)
        }
    }

    @Test func cliRepairReceivesCatalog() async throws {
        let container = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("source-type-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }

        let wikiID = WikiID(rawValue: "01JCLIREPAIRWIKI000000000")
        var registry = WikiRegistry()
        registry.add(WikiDescriptor(
            id: wikiID,
            displayName: "CLI Repair Catalog",
            createdAt: Date(timeIntervalSince1970: 0),
            lastUsedAt: Date(timeIntervalSince1970: 0)))
        try registry.save(to: container)

        let fixture = MermaidCompositionFixtures.catalog
        var profile = CLIStoreProfile { request in
            try await CordisBoot.boot(.init(
                catalog: try CLIPluginCatalog.build(),
                layers: [PatchFile(entries: try ProductionProfiles.cli(
                    databaseURL: request.databaseURL,
                    wikiID: request.wikiID,
                    homeDirectory: request.containerDirectory))]))
        }
        profile.resolveRendererCatalog = { fixture }

        let runner = WikiCtlRunner(
            resolveContainer: { WikiResolver(containerDirectory: container) },
            storeProfile: profile
        ) { _, store, _, _ in
            #expect(store.registeredRendererSourceTypes == fixture)
            let report = try store.repairMIME(dryRun: true)
            #expect(report.applied == false)
            return SourceCommand.Result(payload: .text("ok"), didCommit: false)
        }

        _ = try await runner.runOrdinary(
            command: .page(.list(json: false)),
            wikiSelector: wikiID.rawValue,
            environment: [:])
    }

    @Test func unavailableRendererCatalogIsEmpty() async throws {
        // Without a host snapshot the factory inputs carry the empty catalog.
        let emptyInputs = await MainActor.run { InstalledRendererFactory.Inputs.unavailable }
        let catalog = await MainActor.run { emptyInputs.registeredSourceTypes }
        #expect(catalog.isEmpty)
        let store = try makeStore()
        #expect(store.registeredRendererSourceTypes.isEmpty)
    }

    // MARK: - Fixtures

    private func makeStore() throws -> GRDBWikiStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("source-type-composition-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try GRDBWikiStore(databaseURL: directory.appendingPathComponent("WikiFS.sqlite"))
    }
}

/// The reviewed Mermaid claim, decoded once for composition assertions.
enum MermaidCompositionFixtures {
    static let catalog: RegisteredRendererSourceTypes = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifest = try! JSONDecoder().decode(
            RendererManifest.self,
            from: try! Data(contentsOf: root.appendingPathComponent("RendererPackages/Mermaid/manifest.json")))
        return RegisteredRendererSourceTypes(descriptors: manifest.descriptors)
    }()
}
#endif
