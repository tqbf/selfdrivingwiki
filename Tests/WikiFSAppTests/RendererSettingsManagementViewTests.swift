#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
import WikiFSCore
import WikiFSEngine
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
        // Packages are a selectable table with a fixed height, so the pane
        // scrolls internally instead of growing the Settings window.
        #expect(source.contains("Table(model.rows, selection: $selectedPackageID)"))
        #expect(source.contains(".frame(height: SettingsTableMetrics.height(forRowCount: model.rows.count))"))
        // Add is a first-class control under the table, not a disclosure.
        #expect(source.contains("Button(\"Add Package…\", systemImage: \"plus\")"))
        #expect(source.contains("renderer-package-add-button"))
        #expect(source.contains("renderer-package-remove-button"))
        #expect(!source.contains("Advanced Local Renderer Package Import"))
        #expect(!source.contains("DisclosureGroup"))
        #expect(source.contains("RendererSettingsPackagePicker.localImportSourceMessage"))
        #expect(source.contains("RendererSettingsPackagePicker.localImportStorageMessage"))
        #expect(source.contains("RendererSettingsPackagePicker.localImportAfterMessage"))
        #expect(source.contains("RendererSettingsPackagePicker.v1FormatMessage"))
        #expect(source.contains("The renderer package could not be validated or installed."))
        #expect(!appSource.contains(".task { await installedRendererHost.bootstrapBundledRendererPackages() }"))
        #expect(!source.contains("Install Renderer Directory"))
        #expect(!source.contains("No Renderer Directories"))
        #expect(!source.contains("The renderer directory could not be validated or installed."))
        #expect(!source.contains("Application Support"))
        #expect(!source.contains("App Group"))
        #expect(source.contains("Source data and wiki preferences were preserved"))
        // Removal tombstones stay hidden, but a quarantined or unvalidated
        // record keeps its row: its status is the only place the failure is
        // explained.
        #expect(source.contains(".filter { $0.state != .removed }"))
        // The pane is machine-scoped: installed packages are shared by every
        // wiki, and a source's renderer preference is written where the user
        // reads the source, not in Settings.
        #expect(source.contains("init(host: InstalledRendererHost)"))
        #expect(!source.contains("Source Renderer Preferences"))
        #expect(!source.contains("WikiStoreModel"))
        #expect(!source.contains("rendererSourcePreference"))
        #expect(!source.contains("setRendererSourcePreference"))
        #expect(!source.contains("removeRendererSourcePreference"))
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
            host: InstalledRendererHost(services: UnavailableRendererServices()))

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
        let model = RendererSettingsModel(host: host)
        let packageURL = try #require(BundledRendererPackages.excalidrawResourceURL())

        await model.install(directory: packageURL)

        #expect(model.lastError == nil)
        #expect(model.isBusy == false)
        #expect(model.rows.count == 1)
        #expect(model.diagnostic == "Renderer registry refreshed after installation.")
        try await handle.dispose()
    }

    @Test("the pane hosts its table and empty state in a macOS window")
    @MainActor
    func panelHostsTableAndEmptyState() {
        let view = RendererSettingsView(
            host: InstalledRendererHost(services: UnavailableRendererServices()))
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 640, height: 560))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        host.view.layoutSubtreeIfNeeded()

        #expect(host.view.fittingSize.width > 0)
        #expect(host.view.fittingSize.height > 0)
    }

    @Test("a control row is taller than a text row, so the caller picks one")
    func rowHeightFollowsTheCellsInTheTable() {
        let metrics = SettingsTableMetrics.self
        // A Picker sets its row's height, so a table of pop-ups needs more room
        // per row than a table of labels. Assuming the text height here clips
        // the last row out of view entirely.
        #expect(metrics.controlRowHeight > metrics.textRowHeight)
        #expect(metrics.height(forRowCount: 4) == metrics.height(forRowCount: 4, rowHeight: metrics.textRowHeight))
        #expect(metrics.height(forRowCount: 4, rowHeight: metrics.controlRowHeight)
            == metrics.headerHeight + 4 * metrics.controlRowHeight)
    }

    @Test("the shared table fits its rows between a floor and a ceiling")
    func tableHeightFollowsRowCountWithinBounds() {
        let metrics = SettingsTableMetrics.self

        // No rows: the empty state needs more room than the row floor gives.
        #expect(metrics.height(forRowCount: 0) == metrics.emptyHeight)

        // Below the floor, a stray one-row strip is padded to two rows.
        let floor = metrics.headerHeight + CGFloat(metrics.minimumVisibleRows) * metrics.textRowHeight
        #expect(metrics.height(forRowCount: 1) == floor)
        #expect(metrics.height(forRowCount: metrics.minimumVisibleRows) == floor)

        // Between the bounds the table fits its rows exactly, so a short list
        // leaves no dead space.
        #expect(metrics.height(forRowCount: 4) == metrics.headerHeight + 4 * metrics.textRowHeight)

        // Past the ceiling the height stops growing and the table scrolls.
        let ceiling = metrics.headerHeight + CGFloat(metrics.maximumVisibleRows) * metrics.textRowHeight
        #expect(metrics.height(forRowCount: metrics.maximumVisibleRows) == ceiling)
        #expect(metrics.height(forRowCount: 200) == ceiling)
    }

    @Test("status resolution keeps unavailable, safe mode, and rollback distinct")
    func statusResolutionFollowsRecordPrecedence() throws {
        let quarantined = try Self.makeRecord(state: .quarantined, diagnostic: .packageQuarantined)
        #expect(RendererPackageStatus.resolve(quarantined) == .unavailable(.packageQuarantined))

        let unvalidated = try Self.makeRecord(state: .unvalidated)
        #expect(RendererPackageStatus.resolve(unvalidated) == .unavailable(nil))

        let validated = try Self.makeRecord(state: .validated, descriptors: [try Self.makeDescriptor()])
        #expect(RendererPackageStatus.resolve(validated) == .available)

        // Safe mode outranks the lifecycle state: the version is validated but
        // suppressed, and only the suppression is actionable.
        let suppressed = try Self.makeRecord(
            state: .validated,
            isSafeModeSuppressed: true,
            descriptors: [try Self.makeDescriptor()])
        #expect(RendererPackageStatus.resolve(suppressed) == .safeModeSuppressed)

        let superseded = try Self.makeRecord(state: .superseded, descriptors: [try Self.makeDescriptor()])
        #expect(RendererPackageStatus.resolve(superseded) == .superseded)
    }

    @Test("every status explains itself so a row never shows a bare state word")
    func everyStatusCarriesAnExplanation() {
        let statuses: [RendererPackageStatus] = [
            .available,
            .superseded,
            .safeModeSuppressed,
            .unavailable(nil)
        ] + RendererPackageInstallDiagnostic.allCases.map { RendererPackageStatus.unavailable($0) }

        for status in statuses {
            #expect(status.label.isEmpty == false)
            #expect(status.explanation.isEmpty == false)
            #expect(status.systemImage.isEmpty == false)
        }
    }

    @Test("an import that produced no row reports on the pane, not on a package")
    func installFailureIsPaneScoped() async {
        let model = RendererSettingsModel(
            host: InstalledRendererHost(services: UnavailableRendererServices()))

        await model.install(directory: URL.temporaryDirectory.appending(path: "missing-renderer-package"))

        #expect(model.paneNotice?.severity == .failure)
        #expect(model.paneNotice?.message == RendererSettingsModel.installFailureMessage)
        #expect(model.diagnostic == nil)
    }

    @Test("one notice at a time: a refresh clears the outcome it replaced")
    func refreshClearsThePreviousNotice() async {
        let model = RendererSettingsModel(
            host: InstalledRendererHost(services: UnavailableRendererServices()))
        model.report(error: "Selection was rejected.")
        #expect(model.lastError == "Selection was rejected.")

        await model.refresh()

        #expect(model.lastError == nil)
        #expect(model.notice == nil)
    }

    private static func makeRecord(
        state: RendererPackageInstallState,
        diagnostic: RendererPackageInstallDiagnostic? = nil,
        isSafeModeSuppressed: Bool = false,
        descriptors: [RendererDescriptor] = []
    ) throws -> RendererPackageInstallRecord {
        let timestamp = RFC3339Timestamp(date: Date(timeIntervalSince1970: 1_700_000_000))
        return try RendererPackageInstallRecord(
            packageID: try RendererPackageID(validating: "org.example.settings"),
            version: try RendererPackageVersion(validating: "1.0.0"),
            expectedPackageHash: try RendererSHA256Digest(bytes: Array(repeating: 7, count: 32)),
            state: state,
            reservedAt: timestamp,
            updatedAt: timestamp,
            diagnostic: diagnostic,
            isSafeModeSuppressed: isSafeModeSuppressed,
            validatedDescriptors: descriptors)
    }

    private static func makeDescriptor() throws -> RendererDescriptor {
        let entryPath = try RendererRelativePath(validating: "index.html")
        return try RendererDescriptor(
            reference: RendererReference(
                packageID: try RendererPackageID(validating: "org.example.settings"),
                version: try RendererPackageVersion(validating: "1.0.0"),
                registrationID: try RendererRegistrationID(validating: "canvas")),
            displayName: "Example Canvas",
            implementation: .webPackage(RendererWebEntryPoint(path: entryPath)),
            matchers: [.artifactKind(.source)],
            presentations: [.web],
            approvedAssets: [
                RendererAsset(
                    path: entryPath,
                    digest: try RendererSHA256Digest(bytes: Array(repeating: 2, count: 32)))
            ],
            capabilities: [.inputRead],
            sizeLimits: try RendererSizeLimits(maximumInputByteCount: 1, maximumDecodedByteCount: 1),
            linkPolicy: .none,
            accessibility: RendererAccessibility(supportsVoiceOver: true, supportsKeyboardNavigation: true),
            compatibility: try RendererCompatibility(minimumProtocolRevision: 1, maximumProtocolRevision: 1),
            priority: 0)
    }
}
#endif
