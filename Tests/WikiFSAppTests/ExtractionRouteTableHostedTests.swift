#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
import WikiFSCore
import WikiFSEngine
import WikiFSTypes
@testable import WikiFS

/// Hosted coverage for Settings → Extraction's native route table. The real
/// `ExtractionSettingsView` mounts in an NSWindow (same pattern as
/// `PageContextMenuHostedTests`) and must render, lay out, and load the
/// package snapshot without wedging or crashing.
///
/// SwiftUI's accessibility tree is only materialized for real AX clients, so
/// the identifier/label/status vocabulary is pinned by the source-contract
/// test here plus the hosted contract in `ExtractorPackageSettingsTests`;
/// spoken-announcement behavior remains the manual VoiceOver smoke script's
/// job (`scripts/voiceover-extractor-settings-smoke.md`).
///
/// `.serialized` + `.timeLimit` (issue #1051 discipline): each window-owning
/// test takes the shared `HostedAppKitTestGate` lease so suites never overlap
/// on the single `swift test` AppKit host.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct ExtractionRouteTableHostedTests {

    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return app
    }()

    /// In-memory credential stub (#1159) — the hosted view must never touch
    /// Keychain; `InMemoryCredentialService` backs the write-only UI seam.
    private static let stubCredentials = InMemoryCredentialService()

    private func tempDirectory(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func snapshot(
        registrations: [ExtractorRouteRegistrationSnapshot] = [],
        failedPackageIDs: Set<String> = []
    ) -> ExtractorPackageSettingsSnapshot {
        var snapshot = ExtractorPackageSettingsSnapshot()
        snapshot.registrationSnapshots = registrations
        snapshot.failedPackages = failedPackageIDs.map {
            ExtractorPackageFailureSummary(
                packageID: $0,
                version: "1.0.0",
                digestPrefix: String(repeating: "a", count: 12),
                message: "activation refused")
        }
        return snapshot
    }

    private func makeView(
        directory: URL,
        snapshot: ExtractorPackageSettingsSnapshot
    ) -> ExtractionSettingsView {
        ExtractionSettingsView(
            containerDirectory: directory,
            launcher: AgentLauncher(),
            credentials: Self.stubCredentials,
            packageSnapshot: { snapshot })
    }

    private func mount(_ view: ExtractionSettingsView) -> NSWindow {
        _ = Self.app
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 640, height: 560))
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        // Offscreen but visible: SwiftUI's `.task` (the first snapshot load)
        // only fires once the view is in a visible window hierarchy.
        window.orderFrontRegardless()
        return window
    }

    private func sourceView() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/WikiFS/Sources/ExtractionSettingsView.swift"),
            encoding: .utf8)
    }

    /// Non-blocking bounded wait for SwiftUI's async `.task` to complete the
    /// first snapshot load.
    private func waitUntil(
        _ condition: () -> Bool,
        timeout: Duration = .seconds(5)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while condition() == false {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for the hosted route table to load")
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    // MARK: - AC.10: the table renders and scrolls internally

    private func containsDescendant(_ view: NSView, _ predicate: (NSView) -> Bool) -> Bool {
        if predicate(view) { return true }
        return view.subviews.contains { containsDescendant($0, predicate) }
    }

    private func firstTableView(_ window: NSWindow) -> NSTableView? {
        guard let content = window.contentView else { return nil }
        var result: NSTableView?
        func walk(_ view: NSView) {
            if result == nil, let table = view as? NSTableView { result = table }
            for subview in view.subviews { walk(subview) }
        }
        walk(content)
        return result
    }

    @Test("the route table mounts, loads its snapshot, and scrolls internally")
    func rendersRouteTableWithoutCrash() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        let dir = try tempDirectory("route-table-render")
        // A real registration whose MIME is outside the host routes: the table
        // then holds four rows (PDF, HTML, Word, and the registration-derived
        // epub route). Row views only exist after the async snapshot load rebuilds
        // routeRows, so the wait below observes the actual load instead of the
        // initial layout.
        let view = makeView(directory: dir, snapshot: snapshot(registrations: [
            ExtractorRouteRegistrationSnapshot(
                reference: ExtractorReference(
                    revision: ExtractorPackageRevisionID(
                        packageID: try ExtractorPackageID(validating: "org.example.pdf"),
                        version: try ExtractorPackageVersion(validating: "1.0.0"),
                        digest: try ExtractorPackageDigest(hex: String(repeating: "3", count: 64))),
                    registrationID: try ExtractorRegistrationID(validating: "pdf")),
                displayName: "PDF Package",
                packageName: "PDF Package",
                kinds: [.pdf],
                mimeTypes: [try ExtractorMIMEType(validating: "application/epub+zip")],
                filenameExtensions: []),
        ]))
        let window = mount(view)

        try await waitUntil {
            self.firstTableView(window)?.numberOfRows == 4
        }
        // The hosted hierarchy contains a native table (row views) inside a
        // clip view — the scrollable, window-bounded layout.
        let content = try #require(window.contentView)
        #expect(containsDescendant(content) { $0 is NSClipView })
        let table = try #require(firstTableView(window))
        #expect(table.numberOfRows == 4)
    }

    @Test("a non-ready route status dialog mounts with recovery controls")
    func nonReadyStatusOpensRecoverySheet() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        let presentation = ExtractorRouteRecoveryPresentation(
            route: .canonicalPDF,
            extractorName: "Missing Extractor",
            status: .packageNotInstalled,
            shortStatusLabel: "Not installed",
            systemImage: "shippingbox",
            title: "Missing Extractor is not installed",
            summary: "The saved package selection is not present on this Mac.",
            impact: ExtractorRouteRecoveryPresenter.blockedImpact,
            primaryAction: .refreshStatus,
            secondaryActions: [.chooseAnotherExtractor, .copyDiagnostics],
            accessibilityText: "PDF, Missing Extractor, Not installed. Show status details.",
            diagnosticCategory: .packageNotInstalled,
            diagnosticReport: "Extractor Status Diagnostic\nStatus: package-not-installed",
            authorizationRequirement: nil)
        let controller = NSHostingController(rootView: ExtractionSettingsView.ExtractorStatusDialog(
            presentation: presentation,
            inProgressAction: nil,
            onAction: { _ in }))
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 520, height: 420))
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        window.orderFrontRegardless()
        let content = try #require(window.contentView)
        #expect(content.fittingSize.width > 0)
        #expect(content.fittingSize.height > 0)
    }

    @Test("a package credential configuration dialog mounts")
    func packageCredentialConfigurationDialogMounts() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        let requirement = ExtractorCredentialRequirementSummary(
            packageID: "org.example.extractor",
            packageName: "Example Extractor",
            packageVersion: "1.0.0",
            registrationID: "main",
            requirementID: "api-token",
            label: "API token",
            purpose: "Authenticates requests.",
            isOptional: false,
            isConfigured: true,
            sourceName: "Keychain",
            authorizationState: .needsAuthorization,
            kinds: ["pdf"],
            mimeTypes: ["application/pdf"])
        let controller = NSHostingController(
            rootView: ExtractionSettingsView.PackageConfigurationDialog(
                title: "Example Extractor",
                requirements: [requirement],
                authorizeRequirement: { _ in .succeeded(nil) },
                revokeRequirement: { _ in .succeeded(nil) },
                onCredentialMutation: { _ in }))
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 460, height: 380))
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        window.orderFrontRegardless()
        let content = try #require(window.contentView)
        #expect(content.fittingSize.width > 0)
        #expect(content.fittingSize.height > 0)
    }

    @Test("the table keeps a constrained height at the Settings minimum size")
    func tableUsesConstrainedScrollableLayout() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        let dir = try tempDirectory("route-table-scroll")
        let view = makeView(directory: dir, snapshot: snapshot())
        let window = mount(view)
        let content = try #require(window.contentView)

        // The hosting hierarchy contains a clip view (the table's internal
        // scroll viewport); the Settings form itself carries the fixed
        // minimum frame, so row growth scrolls instead of resizing.
        #expect(containsDescendant(content) { $0 is NSClipView })
        #expect((window.contentView?.bounds.height ?? 0) > 0)

        // The height comes from a named metric, not a magic literal.
        let source = try sourceView()
        #expect(source.contains("routeTableHeight"))
        #expect(source.contains("Table(routeRows)"))
    }

    // MARK: - AC.8 / AC.11 / AC.12 / AC.14 / AC.15 contracts

    /// The route picker vocabulary, identifiers, status vocabulary, and the
    /// dual-write mapping are structural contracts of the view source.
    @Test("route table source exposes the accessibility and mapping contract")
    func routeTableSourceContract() throws {
        let source = try sourceView()

        // The table and its columns.
        #expect(source.contains("Table(routeRows)"))
        #expect(source.contains("TableColumn(\"Format\")"))
        #expect(source.contains("TableColumn(\"Default extractor\")"))
        #expect(source.contains("TableColumn(\"Status\")"))

        // Stable route-derived accessibility identifiers and labels.
        #expect(source.contains("extraction.routes.table"))
        #expect(source.contains("extraction.routes.picker"))
        #expect(source.contains(".accessibilityLabel(\"Default extractor for \\(row.descriptor.displayName)\")"))
        #expect(source.contains(".accessibilityValue(accessibilityValue(row))"))
        #expect(source.contains("Default extractor routes"))
        #expect(source.contains("accessibilityKey("))

        // Fixed compact status vocabulary and actionable detail controls.
        #expect(source.contains("\"Ready\""))
        #expect(source.contains("\"Needs setup\""))
        #expect(source.contains("\"Not installed\""))
        #expect(source.contains("\"Starting\""))
        #expect(source.contains("\"Failed\""))
        #expect(source.contains("extraction.routes.status"))
        #expect(source.contains("Show status details"))
        #expect(source.contains("ExtractorStatusDialog("))
        #expect(source.contains("Technical Details"))
        #expect(source.contains("Configure…"))
        #expect(source.contains("Authorize Credential…"))
        #expect(source.contains("Test Connection"))
        #expect(source.contains("Retry Activation"))
        #expect(source.contains("Refresh Status"))
        #expect(source.contains("Choose Another Extractor…"))
        #expect(source.contains("Copy Diagnostics"))
        #expect(source.contains("retryActivation?()"))
        #expect(source.contains("focusedRoutePicker = route"))
        #expect(source.contains("copyDiagnostics(presentation.diagnosticReport)"))
        #expect(source.contains("extraction.status.action"))
        #expect(source.contains("extraction.status.technical-details"))
        #expect(source.contains("extraction.status.done"))
        #expect(source.contains("Report a Bug") == false)

        // The picker writes through the dual-write mapping with auto-save; no
        // synchronous state write from a representable update path.
        #expect(source.contains("ExtractorRouteSettingsMapping.write(selection, route: row.route, into: &config)"))
        #expect(source.contains("rebuildRouteRows()"))
        #expect(source.contains("NSViewRepresentable") == false)

        // ACP and Docling configuration follows the PDF route selection only.
        // #1159: the Configure… button lives IN the route table (a per-row
        // Configuration column) and opens a dialog (macos-design progressive
        // disclosure) rather than inline sections.
        #expect(source.contains("switch routeSelections[row.id]"))
        #expect(source.contains("TableColumn(\"Configuration\")"))
        #expect(source.contains("Button(\"Configure…\")"))
        #expect(source.contains(".sheet(item: $serviceConfigurationDialog)"))
        #expect(source.contains("ACPConfigurationDialog("))
        #expect(source.contains("DoclingConfigurationDialog("))

        // Technical MIME identity stays out of the primary columns (help text).
        #expect(source.contains("MIME type: \\(row.route.mimeType.rawValue)"))
        #expect(source.contains("Text(\"\\(row.route.mimeType.rawValue)\")") == false)

        // The podcast picker is its own section at the same level as the
        // extractor routes, wired to the podcast binding.
        #expect(source.contains("podcastBackendBinding"))
        #expect(source.contains("Picker(\"Podcast Transcript\", selection: podcastBackendBinding)"))
        #expect(source.contains("Text(\"Transcripts\")"))
    }

    @Test("picker options show only extractor names")
    func pickerOptionsHideImplementationCategories() throws {
        let route = ExtractorRouteID.canonicalPDF
        let logical = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.example.extractor"),
            registrationID: try ExtractorRegistrationID(validating: "main"))
        let cases: [(ExtractorRouteSourceCategory, ExtractionBackendReference?, String)] = [
            (.reviewedPackage, .installed(logical), "Reviewed Extractor"),
            (.installedPackage, .installed(logical), "Installed Extractor"),
            (.connectedService, .builtIn(.pdf(.acp)), "ACP Provider"),
            (.builtIn, .builtIn(.html(.tagBased)), "Tag-based"),
            (.prompt, nil, "No default (ask each time)"),
            (.unavailable, .installed(logical), "Missing Extractor"),
        ]

        for (category, reference, name) in cases {
            let choice = ExtractorRouteChoice(
                route: route,
                reference: reference,
                displayName: name,
                category: category)
            #expect(ExtractionSettingsView.optionLabel(choice) == name)
        }
    }

    /// A stale installed selection stays selected and blocks the route after a
    /// persisted-file round trip.
    @Test("a stale installed selection persists and remains unavailable")
    func staleSelectionRemainsUnavailable() async throws {
        let dir = try tempDirectory("route-table-stale")
        let logical = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.example.gone"),
            registrationID: try ExtractorRegistrationID(validating: "main"))

        // The table's write path, exercised end to end: mapping write + save.
        var config = ExtractionConfig(backend: .acp)
        ExtractorRouteSettingsMapping.write(.installed(logical), route: .canonicalPDF, into: &config)
        try config.save(to: dir)

        let reloaded = ExtractionConfig.load(from: dir)
        #expect(reloaded.extractorSelection(for: .canonicalPDF) == .installed(logical))
        #expect(reloaded.pdfExtractor == .installed(logical))
        let decision = ExtractorSelectionResolver.resolvePDF(configuration: reloaded, activeRegistrations: [])
        #expect(decision.selection == .unavailableInstalled(kind: .pdf, reference: logical))
        #expect(decision.diagnostic == .unavailableInstalled(logical))

        // The route table preserves the blocked state.
        let rows = ExtractorRouteTableBuilder.build(.init(
            configuration: reloaded,
            registrations: []))
        let pdf = rows.first { $0.route == .canonicalPDF }
        #expect(pdf?.status == .packageNotInstalled)
        #expect(pdf?.savedSelection == .installed(logical))
    }

    /// DOCX analogue of the stale-PDF fixture: an explicit installed DOCX
    /// selection that has no active registration persists through the
    /// mapping write + config round trip and blocks the DOCX route with the
    /// redacted unavailable diagnostic.
    @Test("a stale DOCX selection persists and remains unavailable")
    func staleDocxSelectionRemainsUnavailable() async throws {
        let dir = try tempDirectory("route-table-stale-docx")
        let logical = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.example.gone.docx"),
            registrationID: try ExtractorRegistrationID(validating: "document"))

        var config = ExtractionConfig(backend: .acp)
        ExtractorRouteSettingsMapping.write(.installed(logical), route: .canonicalDOCX, into: &config)
        try config.save(to: dir)

        let reloaded = ExtractionConfig.load(from: dir)
        #expect(reloaded.extractorSelection(for: .canonicalDOCX) == .installed(logical))
        #expect(reloaded.docxExtractor == .installed(logical))
        let decision = ExtractorSelectionResolver.resolveDOCX(configuration: reloaded, activeRegistrations: [])
        #expect(decision.selection == .unavailableInstalled(kind: .docx, reference: logical))
        #expect(decision.diagnostic == .unavailableInstalled(logical))

        let rows = ExtractorRouteTableBuilder.build(.init(
            configuration: reloaded,
            registrations: []))
        let docx = rows.first { $0.route == .canonicalDOCX }
        #expect(docx?.status == .packageNotInstalled)
        #expect(docx?.savedSelection == .installed(logical))
    }
}

@Suite("Extractor route recovery presenter")
struct ExtractorRouteRecoveryPresenterTests {
    private func logical(_ packageID: String = "org.example.extractor") throws -> LogicalExtractorReference {
        LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: packageID),
            registrationID: try ExtractorRegistrationID(validating: "main"))
    }

    private func row(
        selection: ExtractionBackendReference?,
        status: ExtractorRouteStatus,
        route: ExtractorRouteID = .canonicalPDF,
        exactSummary: String? = nil
    ) -> ExtractorRouteSettingsRow {
        ExtractorRouteSettingsRow(
            descriptor: ExtractorRouteDescriptor(
                route: route,
                displayName: route == .canonicalPDF ? "PDF" : "HTML",
                systemImage: "doc"),
            savedSelection: selection,
            resolvedSelection: nil,
            choices: [ExtractorRouteChoice(
                route: route,
                reference: selection,
                displayName: "Example Extractor",
                category: selection == nil ? .prompt : .installedPackage,
                exactSummary: exactSummary)],
            status: status)
    }

    private func requirement(
        logical: LogicalExtractorReference,
        configured: Bool,
        authorization: ExtractorCredentialRequirementSummary.AuthorizationState
    ) -> ExtractorCredentialRequirementSummary {
        ExtractorCredentialRequirementSummary(
            packageID: logical.packageID.rawValue,
            packageName: "Docling Serve",
            packageVersion: "1.0.0",
            registrationID: logical.registrationID.rawValue,
            requirementID: "token",
            label: "API token",
            purpose: "Connect to Docling Serve",
            isOptional: false,
            isConfigured: configured,
            sourceName: "Docling token",
            authorizationState: authorization,
            kinds: ["pdf"],
            mimeTypes: ["application/pdf"])
    }

    @Test func compactVocabularyContainsNoFallbackOrDoesntWork() throws {
        let states: [ExtractorRouteStatus] = [
            .ready,
            .needsSetup(.missingACPProvider),
            .packageNotInstalled,
            .waitingForHostActivation,
            .activationFailed(message: nil),
            .unavailableSelection,
        ]
        let labels = states.map {
            ExtractorRouteRecoveryPresenter.present(
                row: row(selection: .installed(try! logical()), status: $0),
                extractorName: "Example",
                facts: .init()).shortStatusLabel
        }
        #expect(Set(labels) == ["Ready", "Needs setup", "Not installed", "Starting", "Failed"])
        let combined = labels.joined(separator: " ").lowercased()
        #expect(combined.contains("fallback") == false)
        #expect(combined.contains("doesn't work") == false)
    }

    @Test func needsSetupMatrix() throws {
        let acp = row(selection: .builtIn(.pdf(.acp)), status: .ready)
        var facts = ExtractorRouteRecoveryFacts()
        let missingProvider = ExtractorRouteRecoveryPresenter.present(
            row: acp, extractorName: "ACP Provider", facts: facts)
        #expect(missingProvider.status == .needsSetup(.missingACPProvider))
        #expect(missingProvider.primaryAction == .configure)

        facts.acpProviderID = "missing-provider"
        let unavailableProvider = ExtractorRouteRecoveryPresenter.present(
            row: acp, extractorName: "ACP Provider", facts: facts)
        #expect(unavailableProvider.status == .needsSetup(.unavailableACPProvider))

        let doclingLogical = ProcessExtractionServices.reviewedDoclingLogical
        let docling = row(selection: .installed(doclingLogical), status: .ready)
        var doclingFacts = ExtractorRouteRecoveryFacts()
        let missingEndpoint = ExtractorRouteRecoveryPresenter.present(
            row: docling, extractorName: "Docling Serve", facts: doclingFacts)
        #expect(missingEndpoint.status == .needsSetup(.invalidDoclingEndpoint))

        doclingFacts.doclingEndpoint = "https://docling.example.test/convert"
        let missingCredential = ExtractorRouteRecoveryPresenter.present(
            row: docling, extractorName: "Docling Serve", facts: doclingFacts)
        #expect(missingCredential.status == .needsSetup(.missingDoclingCredential))

        doclingFacts.doclingCredentialConfigured = true
        doclingFacts.credentialRequirements = [requirement(
            logical: doclingLogical,
            configured: true,
            authorization: .needsAuthorization)]
        let unauthorized = ExtractorRouteRecoveryPresenter.present(
            row: docling, extractorName: "Docling Serve", facts: doclingFacts)
        #expect(unauthorized.status == .needsSetup(.unauthorizedDoclingCredential))
        #expect(unauthorized.primaryAction == .authorizeCredential)

        doclingFacts.credentialRequirements = []
        doclingFacts.connectionTest = .failed
        doclingFacts.connectionFailureMessage = "Connection refused"
        let failedTest = ExtractorRouteRecoveryPresenter.present(
            row: docling, extractorName: "Docling Serve", facts: doclingFacts)
        #expect(failedTest.status == .needsSetup(.doclingConnectionFailed))
        #expect(failedTest.primaryAction == .testConnection)
    }

    @Test func packageLifecycleMatrixUsesNewestApplicableFailure() throws {
        let selected = try logical()
        let selectedRow = row(selection: .installed(selected), status: .packageNotInstalled)
        let missing = ExtractorRouteRecoveryPresenter.present(
            row: selectedRow, extractorName: "Example", facts: .init())
        #expect(missing.shortStatusLabel == "Not installed")
        #expect(missing.actions == [.refreshStatus, .chooseAnotherExtractor, .copyDiagnostics])

        let waiting = ExtractorRouteRecoveryPresenter.present(
            row: row(selection: .installed(selected), status: .waitingForHostActivation),
            extractorName: "Example",
            facts: .init())
        #expect(waiting.shortStatusLabel == "Starting")
        #expect(waiting.primaryAction == .retryActivation)

        var facts = ExtractorRouteRecoveryFacts()
        facts.retainedFailures = [
            ExtractorPackageFailureSummary(
                packageID: selected.packageID.rawValue,
                version: "1.0.0",
                digestPrefix: "111111111111",
                message: "old failure"),
            ExtractorPackageFailureSummary(
                packageID: "org.example.other",
                version: "9.0.0",
                digestPrefix: "999999999999",
                message: "other failure"),
            ExtractorPackageFailureSummary(
                packageID: selected.packageID.rawValue,
                version: "2.0.0",
                digestPrefix: "222222222222",
                message: "new failure"),
        ]
        let failed = ExtractorRouteRecoveryPresenter.present(
            row: selectedRow, extractorName: "Example", facts: facts)
        #expect(failed.status == .activationFailed(message: "new failure"))
        #expect(failed.diagnosticReport.contains("Version: 2.0.0"))
        #expect(failed.diagnosticReport.contains("new failure"))
        #expect(failed.diagnosticReport.contains("old failure") == false)
    }
}

@Suite("Extractor route diagnostics")
struct ExtractorRouteDiagnosticReportTests {
    @Test func endpointOriginRemovesUserInfoPathQueryAndFragment() {
        let origin = ExtractorRouteDiagnosticReport.endpointOrigin(
            "https://user:password@Docling.Example:8443/private/convert?token=SECRET#fragment")
        #expect(origin == "https://docling.example:8443")
    }

    @Test func secretCanaryNeverEntersReport() throws {
        let secret = "CANARY_SECRET_VALUE"
        let privatePath = "/Users/alice/private/operation-file.pdf"
        let logical = ProcessExtractionServices.reviewedDoclingLogical
        let row = ExtractorRouteSettingsRow(
            descriptor: ExtractorRouteDescriptor(
                route: .canonicalPDF, displayName: "PDF", systemImage: "doc"),
            savedSelection: .installed(logical),
            resolvedSelection: .unavailableInstalled(kind: .pdf, reference: logical),
            choices: [ExtractorRouteChoice(
                route: .canonicalPDF,
                reference: .installed(logical),
                displayName: "Docling Serve",
                category: .reviewedPackage)],
            status: .unavailableSelection)
        var facts = ExtractorRouteRecoveryFacts()
        facts.doclingEndpoint = "https://user:\(secret)@docling.example\(privatePath)?token=\(secret)"
        facts.doclingCredentialConfigured = true
        facts.connectionFailureMessage = "Authorization: Bearer \(secret) at \(privatePath)"
        facts.appVersion = "1.2.3"
        facts.appBuild = "456"
        facts.macOSVersion = "Version 26.0"
        let presentation = ExtractorRouteRecoveryPresenter.present(
            row: row, extractorName: "Docling Serve", facts: facts)
        for canary in [secret, privatePath, "Authorization:", "Bearer", "operation-file.pdf", "?token="] {
            #expect(presentation.diagnosticReport.contains(canary) == false)
        }
        #expect(presentation.diagnosticReport.contains("https://docling.example"))
    }

    @Test func copyTextMatchesPreview() throws {
        let logical = try LogicalExtractorReference(
            packageID: ExtractorPackageID(validating: "org.example.missing"),
            registrationID: ExtractorRegistrationID(validating: "main"))
        let row = ExtractorRouteSettingsRow(
            descriptor: ExtractorRouteDescriptor(
                route: .canonicalPDF, displayName: "PDF", systemImage: "doc"),
            savedSelection: .installed(logical),
            resolvedSelection: .unavailableInstalled(kind: .pdf, reference: logical),
            choices: [],
            status: .packageNotInstalled)
        let first = ExtractorRouteRecoveryPresenter.present(
            row: row, extractorName: "Missing Extractor", facts: .init())
        let second = ExtractorRouteRecoveryPresenter.present(
            row: row, extractorName: "Missing Extractor", facts: .init())
        // Copy Diagnostics hands out the same value the Technical Details
        // preview renders: the report must be deterministic, populated, and
        // within the named bound.
        #expect(first.diagnosticReport == second.diagnosticReport)
        #expect(first.diagnosticReport.isEmpty == false)
        #expect(first.diagnosticReport.count <= ExtractorRouteDiagnosticReport.maximumReportLength)
    }
}

#endif
