#if os(macOS)
import Cordis
import CordisLoader
import Foundation
import Testing
import WikiFSTypes
@testable import WikiCtlCore
@testable import WikiFSCore
@testable import WikiFSEngine
@testable import wikictl_fixture

/// The fixture store profile projects the machine's renderer source-type
/// catalog onto the composed store (AC.3's CLI leg), and commands run against
/// that projection. Ported from the WikiCtlCore-era suite; the profile moved
/// into the build-only `wikictl-fixture` target with the fixture-binary split.
@Suite("Fixture store profile renderer catalog", .serialized, .timeLimit(.minutes(3)))
struct FixtureRendererCatalogTests {
    @Test func fixtureProfileReceivesCatalog() async throws {
        let container = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fixture-source-type-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: container) }
            catch { Issue.record("fixture catalog test cleanup failed: \(error)") }
        }

        let wikiID = WikiID(rawValue: "01JFIXTUREWIKI0000000000000")
        let fixture = FixtureMermaidCatalog.catalog
        var profile = CLIStoreProfile { request in
            try await CordisBoot.boot(.init(
                catalog: try CLIPluginCatalog.build(),
                layers: [PatchFile(entries: try ProductionProfiles.cli(
                    databaseURL: request.databaseURL,
                    wikiID: request.wikiID,
                    homeDirectory: request.containerDirectory))]))
        }
        profile.resolveRendererCatalog = { fixture }

        let observed = try await profile.withStore(request: .init(
            databaseURL: container.appendingPathComponent("\(wikiID.rawValue).sqlite"),
            wikiID: wikiID,
            containerDirectory: container
        )) { store -> Bool in
            let projected = store.registeredRendererSourceTypes == fixture
            // A real command runs against the projected store: the repair
            // sweep is read-only under dryRun and must not fail.
            let report = try store.repairMIME(dryRun: true)
            #expect(report.applied == false)
            return projected
        }
        #expect(observed)
    }
}

/// The reviewed Mermaid claim, decoded once for the catalog projection
/// assertion (same fixture shape as the app-tier composition suite).
enum FixtureMermaidCatalog {
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
