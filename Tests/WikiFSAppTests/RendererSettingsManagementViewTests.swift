#if os(macOS)
import Foundation
import Testing
import WikiFSCore
@testable import WikiFS

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct RendererSettingsManagementViewTests {
    @Test("settings surface exposes the approved management scopes and copy")
    func settingsSurfaceUsesApprovedScopesAndCopy() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/WikiFS/Settings/RendererSettingsView.swift"),
            encoding: .utf8)

        #expect(source.contains("Installed on This Mac"))
        #expect(source.contains("Enabled for This Wiki"))
        #expect(source.contains(RendererSettingsPackagePicker.installButtonTitle))
        #expect(source.contains(RendererSettingsPackagePicker.v1FormatMessage))
        #expect(source.contains("Source data and wiki preferences were preserved"))
        #expect(source.contains(".filter { $0.state != .removed }"))
        #expect(source.contains(".task(id: wikiID)"))
        #expect(source.contains("model.updateWiki(wiki)"))
        #expect(source.contains(".font(.body)"))
        #expect(!source.contains(".font(.system(size:"))
    }

    @Test("settings model follows the current wiki store")
    func settingsModelTracksCurrentWikiStore() throws {
        let firstURL = URL.temporaryDirectory.appending(path: "renderer-settings-first-\\(UUID().uuidString).sqlite")
        let secondURL = URL.temporaryDirectory.appending(path: "renderer-settings-second-\\(UUID().uuidString).sqlite")
        defer {
            for url in [firstURL, secondURL] {
                do { try FileManager.default.removeItem(at: url) }
                catch { Issue.record("Renderer settings model fixture cleanup failed.") }
            }
        }

        let firstWiki = WikiStoreModel(store: try GRDBWikiStore(databaseURL: firstURL))
        let secondWiki = WikiStoreModel(store: try GRDBWikiStore(databaseURL: secondURL))
        let host = InstalledRendererHost(machineStore: nil, layout: nil)
        let model = RendererSettingsModel(host: host, wiki: firstWiki)

        model.updateWiki(secondWiki)

        #expect(model.wiki === secondWiki)
    }
}
#endif
