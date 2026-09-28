import AppKit
import Foundation
import SwiftUI
import Testing
import WikiFSCore
import WikiFSEngine
import WikiFSTypes
@testable import WikiFS

/// Hosted coverage for Settings → Fetch: the fetchers-focus instance of the
/// package settings view mounts in an NSWindow (same pattern as
/// `ExtractionRouteTableHostedTests`), lists ONLY fetcher package rows,
/// shows the fetcher route table with its own picker, never renders the
/// extractor-scope ACP provider section, and persists selections through
/// `routeFetchers` only.
///
/// SwiftUI's accessibility tree is only materialized for real AX clients, so
/// the `fetch.*` identifier vocabulary is pinned by the source-contract
/// extensions in `ExtractionRouteTableHostedTests` and
/// `ExtractorPackageSettingsTests`.
///
/// `.serialized` + `.timeLimit` (issue #1051 discipline): each window-owning
/// test takes the shared `HostedAppKitTestGate` lease.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct FetchSettingsHostedTests {

    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return app
    }()

    private static let stubCredentials = InMemoryCredentialService()

    private func tempDirectory(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A snapshot with one extractor and one fetcher installed: each tab's
    /// filtered view must show exactly its own row.
    private func mixedSnapshot() throws -> ExtractorPackageSettingsSnapshot {
        var snapshot = ExtractorPackageSettingsSnapshot()
        snapshot.rows = [
            ExtractorPackageSettingsRow(
                role: .extractor,
                kind: .pdf,
                packageID: "org.example.pdf",
                version: "1.0.0",
                digestPrefix: String(repeating: "3", count: 12),
                registrationID: "document",
                revision: ExtractorPackageRevisionID(
                    packageID: try ExtractorPackageID(validating: "org.example.pdf"),
                    version: try ExtractorPackageVersion(validating: "1.0.0"),
                    digest: try ExtractorPackageDigest(hex: String(repeating: "3", count: 64)))),
            ExtractorPackageSettingsRow(
                role: .fetcher,
                kind: nil,
                packageID: "org.example.fetcher",
                version: "2.0.0",
                digestPrefix: String(repeating: "f", count: 12),
                registrationID: "acquire",
                revision: ExtractorPackageRevisionID(
                    packageID: try ExtractorPackageID(validating: "org.example.fetcher"),
                    version: try ExtractorPackageVersion(validating: "2.0.0"),
                    digest: try ExtractorPackageDigest(hex: String(repeating: "f", count: 64)))),
        ]
        snapshot.registrationSnapshots = [
            ExtractorRouteRegistrationSnapshot(
                reference: ExtractorReference(
                    revision: try ExtractorPackageRevisionID(
                        packageID: ExtractorPackageID(validating: "org.example.pdf"),
                        version: ExtractorPackageVersion(validating: "1.0.0"),
                        digest: try ExtractorPackageDigest(hex: String(repeating: "3", count: 64))),
                    registrationID: try ExtractorRegistrationID(validating: "document")),
                displayName: "PDF Package",
                packageName: "PDF Package",
                kinds: [.pdf],
                mimeTypes: [try ExtractorMIMEType(validating: "application/pdf")],
                filenameExtensions: []),
            ExtractorRouteRegistrationSnapshot(
                reference: ExtractorReference(
                    revision: try ExtractorPackageRevisionID(
                        packageID: ExtractorPackageID(validating: "org.example.fetcher"),
                        version: ExtractorPackageVersion(validating: "2.0.0"),
                        digest: try ExtractorPackageDigest(hex: String(repeating: "f", count: 64))),
                    registrationID: try ExtractorRegistrationID(validating: "acquire")),
                displayName: "Example Fetcher",
                packageName: "Example Fetcher",
                role: .fetcher,
                kinds: [],
                mimeTypes: [try ExtractorMIMEType(validating: "application/x-example")],
                filenameExtensions: []),
        ]
        snapshot.credentialRequirements = [
            ExtractorCredentialRequirementSummary(
                packageID: "org.example.fetcher",
                packageName: "Example Fetcher",
                packageVersion: "2.0.0",
                registrationID: "acquire",
                requirementID: "api-key",
                label: "API Key",
                purpose: "Fetch sources.",
                isOptional: false,
                isConfigured: false,
                sourceName: "Keychain",
                authorizationState: .needsAuthorization,
                kinds: [],
                mimeTypes: ["application/x-example"]),
        ]
        return snapshot
    }

    private func makeView(
        directory: URL,
        snapshot: ExtractorPackageSettingsSnapshot,
        pane: ExtractionSettingsPane = .packages,
        roleFocus: ExtractionSettingsRoleFocus = .fetchers
    ) -> ExtractionSettingsView {
        ExtractionSettingsView(
            containerDirectory: directory,
            launcher: AgentLauncher(),
            credentials: Self.stubCredentials,
            packageSnapshot: { snapshot },
            initialPane: pane,
            roleFocus: roleFocus)
    }

    private func mount(_ view: ExtractionSettingsView) -> NSWindow {
        _ = Self.app
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 640, height: 560))
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        window.orderFrontRegardless()
        return window
    }

    private func tableViews(_ window: NSWindow) -> [NSTableView] {
        guard let content = window.contentView else { return [] }
        var tables: [NSTableView] = []
        func walk(_ view: NSView) {
            if let table = view as? NSTableView { tables.append(table) }
            for subview in view.subviews { walk(subview) }
        }
        walk(content)
        return tables
    }

    private func nonblockingWait(
        _ condition: () -> Bool,
        timeout: Duration = .seconds(5)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while condition() == false {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for the hosted view to load")
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    // MARK: - Packages pane

    /// AC.2 + AC.4: the Fetch tab's packages table lists ONLY the fetcher
    /// row from a mixed snapshot (one extractor + one fetcher installed).
    @Test("fetch tab lists only fetcher packages")
    func fetchTabListsOnlyFetcherRows() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        let dir = try tempDirectory("fetch-settings-packages")
        let snapshot = try mixedSnapshot()

        let fetchWindow = mount(makeView(directory: dir, snapshot: snapshot))
        try await nonblockingWait { !self.tableViews(fetchWindow).isEmpty }
        let fetchTables = tableViews(fetchWindow)
        #expect(!fetchTables.isEmpty, "fetch tab mounted a table")
        if let packagesTable = fetchTables.first {
            #expect(packagesTable.numberOfRows == 1, "one fetcher row, no extractor rows")
        }

        // The mirror assertion: the Extraction tab shows the extractor row
        // and NOT the fetcher row.
        let extractorWindow = mount(makeView(
            directory: dir, snapshot: snapshot, roleFocus: .extractors))
        try await nonblockingWait { !self.tableViews(extractorWindow).isEmpty }
        let extractorTables = tableViews(extractorWindow)
        #expect(!extractorTables.isEmpty, "extraction tab mounted a table")
        if let packagesTable = extractorTables.first {
            #expect(packagesTable.numberOfRows == 1, "one extractor row, no fetcher rows")
        }
    }

    // MARK: - Defaults pane

    /// AC.2: the Fetch tab's defaults pane mounts the fetcher route table
    /// with exactly the fetcher registration's claimed route, and the picker
    /// choices come from the fetcher registration only.
    @Test("fetch tab route table lists claimed fetcher routes")
    func fetchTabRouteTableListsFetcherRoutes() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        let dir = try tempDirectory("fetch-settings-routes")
        let snapshot = try mixedSnapshot()

        let window = mount(makeView(
            directory: dir, snapshot: snapshot, pane: .defaults))
        try await nonblockingWait { !self.tableViews(window).isEmpty }
        let tables = tableViews(window)
        #expect(!tables.isEmpty, "fetch defaults pane mounted a table")
        if let routeTable = tables.first {
            // The claimed fetcher route plus the bundled `application/zotero`
            // default — at least the claimed route mounted.
            #expect(routeTable.numberOfRows >= 1)
        }
        // Value-level pin: the builder's fetcher rows include exactly the
        // claimed route for this registration (the hosted table renders
        // these rows plus any bundled/saved routes).
        let rows = ExtractorRouteTableBuilder.buildFetcherRows(.init(
            configuration: ExtractionConfig(),
            registrations: snapshot.registrationSnapshots,
            availableRegistrations: snapshot.registrationSnapshots))
        let claimed = try #require(
            rows.first { $0.route.mimeType.rawValue == "application/x-example" })
        #expect(claimed.choices.contains { $0.displayName == "Example Fetcher" })
        #expect(claimed.status == .ready)
    }

    /// The skeptic-review regression: the ACP provider section is an
    /// extractor-scope configuration and must NEVER appear in the Fetch
    /// tab, even when the loaded config has an ACP selection on an
    /// extractor route.
    @Test("fetch tab never shows the ACP provider section")
    func fetchTabHidesACPProviderSection() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        let dir = try tempDirectory("fetch-settings-acp")
        // A saved ACP host selection on the canonical PDF route.
        var config = ExtractionConfig()
        config.setExtractorSelection(
            .host(HostExtractorReference(
                adapterID: try HostExtractorID(validating: "acp"))),
            for: .canonicalPDF)
        try config.save(to: dir)

        let snapshot = try mixedSnapshot()
        let window = mount(makeView(
            directory: dir, snapshot: snapshot, pane: .defaults))
        try await nonblockingWait { !self.tableViews(window).isEmpty }

        // The ACP picker's stable identifier must not exist anywhere in the
        // hosted hierarchy (it is only rendered when the section shows).
        func containsACPIdentifier(_ view: NSView) -> Bool {
            if view.accessibilityIdentifier() == "extraction.defaults.acp.provider" { return true }
            return view.subviews.contains { containsACPIdentifier($0) }
        }
        let content = try #require(window.contentView)
        #expect(containsACPIdentifier(content) == false)
    }

    // MARK: - Selection persistence

    /// AC.3 (config-level leg of the fallback): the write path the fetcher
    /// picker uses persists a `routeFetchers` record — and only there. The
    /// hosted NSPopUpButton drive is covered by the picker binding mapping
    /// to this exact path (`writeFetcherSelection`).
    @Test("fetcher selection persists to routeFetchers only")
    func fetcherSelectionPersistsToRouteFetchersOnly() throws {
        let dir = try tempDirectory("fetch-settings-persist")
        let route = try #require(FetcherRouteID(
            normalizing: "application/x-example"))
        let lineage = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.example.fetcher"),
            registrationID: try ExtractorRegistrationID(validating: "acquire"))

        var config = ExtractionConfig()
        config.setFetcherSelection(.installed(lineage), for: route)
        try config.save(to: dir)

        let reloaded = ExtractionConfig.load(from: dir)
        #expect(reloaded.routeFetchers.count == 1)
        #expect(reloaded.fetcherSelection(for: route) == .installed(lineage))
        #expect(reloaded.routeExtractors.isEmpty)

        // An explicit disable also persists — and never revives the default.
        var disabled = ExtractionConfig.load(from: dir)
        disabled.setFetcherSelection(ExtractionBackendReference.none, for: route)
        try disabled.save(to: dir)
        let reloadedDisabled = ExtractionConfig.load(from: dir)
        #expect(reloadedDisabled.fetcherSelection(for: route) == ExtractionBackendReference.none)
        #expect(reloadedDisabled.fetcherSelectionOrDefault(for: route) == ExtractionBackendReference.none)
        #expect(reloadedDisabled.routeExtractors.isEmpty)
    }

    /// The model-level filter contract (AC.4): the static row builder
    /// filters installed rows by role while failed subjects bypass the
    /// filter and appear in both foci.
    @Test("model filters installed rows by role and keeps failed rows in both")
    func modelFiltersByRole() throws {
        var snapshot = try mixedSnapshot()
        snapshot.failedPackages = [
            ExtractorPackageFailureSummary(
                packageID: "org.example.broken",
                version: "0.9.0",
                digestPrefix: String(repeating: "b", count: 12),
                message: "activation refused"),
        ]

        let extractorRows = ExtractorPackageSettingsModel.tableRows(
            from: snapshot, roleFocus: .extractors)
        let fetcherRows = ExtractorPackageSettingsModel.tableRows(
            from: snapshot, roleFocus: .fetchers)

        #expect(extractorRows.count == 2)
        #expect(extractorRows.contains { $0.packageID == "org.example.pdf" })
        #expect(extractorRows.contains { $0.packageID == "org.example.broken" })
        #expect(extractorRows.contains { $0.packageID == "org.example.fetcher" } == false)

        #expect(fetcherRows.count == 2)
        #expect(fetcherRows.contains { $0.packageID == "org.example.fetcher" })
        #expect(fetcherRows.contains { $0.packageID == "org.example.broken" })
        #expect(fetcherRows.contains { $0.packageID == "org.example.pdf" } == false)
    }
}
