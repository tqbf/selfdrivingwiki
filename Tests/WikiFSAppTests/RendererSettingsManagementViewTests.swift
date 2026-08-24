#if os(macOS)
import Foundation
import Testing
import WikiFSCore
@testable import WikiFS

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct RendererSettingsManagementViewTests {
    @Test("settings surface exposes machine installation without wiki enablement controls")
    func settingsSurfaceUsesMachineInstallationScopesAndCopy() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/WikiFS/Settings/RendererSettingsView.swift"),
            encoding: .utf8)
        let appSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/WikiFS/Window/WikiFSApp.swift"),
            encoding: .utf8)

        #expect(source.contains("Installed on This Mac"))
        #expect(source.contains("No renderer packages are installed on this Mac."))
        #expect(source.contains("Advanced Local Renderer Package Import"))
        #expect(source.contains("RendererSettingsPackagePicker.localImportSourceMessage"))
        #expect(source.contains("RendererSettingsPackagePicker.localImportStorageMessage"))
        #expect(source.contains("RendererSettingsPackagePicker.localImportAfterMessage"))
        #expect(source.contains("RendererSettingsPackagePicker.importButtonTitle"))
        #expect(source.contains("RendererSettingsPackagePicker.v1FormatMessage"))
        #expect(source.contains("The renderer package could not be validated or installed."))
        #expect(!appSource.contains(".task { await installedRendererHost.bootstrapBundledRendererPackages() }"))
        #expect(appSource.contains("RendererCompositionOwner"))
        #expect(!source.contains("Install Renderer Directory"))
        #expect(!source.contains("No Renderer Directories"))
        #expect(!source.contains("The renderer directory could not be validated or installed."))
        #expect(!source.contains("Application Support"))
        #expect(!source.contains("App Group"))
        #expect(source.contains("Source data and wiki preferences were preserved"))
        #expect(source.contains(".filter { $0.state == .validated }"))
        #expect(source.contains(".task(id: wikiID)"))
        #expect(source.contains("model.updateWiki(wiki)"))
        #expect(source.contains("rendererSourcePreference(for: source.id)"))
        #expect(source.contains("Selected renderer version"))
        #expect(source.contains("Updating renderer packages"))
        #expect(source.contains("announcementRequested"))
        #expect(source.contains("Files and archives are not supported."))
        #expect(!source.contains("Text(RendererSettingsPackagePicker.v1FormatMessage)"))
        #expect(source.contains(".font(.body)"))
        #expect(!source.contains(".font(.system(size:"))
        #expect(!source.contains("Enabled for This Wiki"))
        #expect(!source.contains("Enablement applies only to the currently open wiki."))
        #expect(!source.contains("setRendererWikiEnablement"))
        #expect(!source.contains("rendererWikiEnablement(for:"))
        #expect(!source.contains("isEnabledForWiki"))
    }

    @Test("settings model reports install failure and clears busy state")
    func settingsModelReportsInstallFailure() async {
        let model = RendererSettingsModel(
            host: InstalledRendererHost(services: UnavailableRendererServices()),
            wiki: nil)

        await model.install(directory: URL.temporaryDirectory.appending(path: "missing-renderer-package"))

        #expect(model.lastError == "The renderer package could not be validated or installed.")
        #expect(model.isBusy == false)
    }

    @Test("settings model installs a validated package into machine-wide rows")
    func settingsModelInstallsValidatedPackage() async throws {
        let root = URL.temporaryDirectory.appending(path: "renderer-settings-install-\(UUID().uuidString)")
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Renderer settings install fixture cleanup failed.") }
        }
        let layout = try RendererPackageStoreLayout(appGroupContainerRoot: root)
        let handle = try await RendererRuntimeFactory(
            layout: layout,
            bundledPackageSource: { BundledRendererPackages.excalidrawResourceURL() },
            reviewedBundledIdentity: .init(
                packageID: BundledRendererPackages.excalidrawPackageID,
                version: BundledRendererPackages.excalidrawVersion,
                registrationID: BundledRendererPackages.excalidrawRegistrationID))
            .assemble()
        let host = InstalledRendererHost(services: handle.services)
        let model = RendererSettingsModel(host: host, wiki: nil)
        let packageURL = try #require(BundledRendererPackages.excalidrawResourceURL())

        await model.install(directory: packageURL)

        #expect(model.lastError == nil)
        #expect(model.isBusy == false)
        #expect(model.rows.count == 1)
        #expect(model.diagnostic == "Renderer registry refreshed after installation.")
        try await handle.dispose()
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
        let host = InstalledRendererHost(services: UnavailableRendererServices())
        let model = RendererSettingsModel(host: host, wiki: firstWiki)

        model.updateWiki(secondWiki)

        #expect(model.wiki === secondWiki)
    }
}
#endif
