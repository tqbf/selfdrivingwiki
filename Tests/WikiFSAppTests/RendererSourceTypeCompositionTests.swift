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

    // `cliRepairReceivesCatalog` moved to Tests/WikiCtlFixtureTests with the
    // fixture-binary split: the CLI store profile it exercised now lives in
    // the build-only `wikictl-fixture` target (the shipping wikictl boots no
    // local store).

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
