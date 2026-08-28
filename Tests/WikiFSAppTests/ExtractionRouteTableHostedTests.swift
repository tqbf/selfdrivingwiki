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

    /// In-memory credential stub — the hosted view must never touch Keychain.
    private struct StubCredentialStore: ExtractionCredentialStore {
        func secret(_ secret: ExtractionSecret) -> String? { nil }
        func setSecret(_ value: String?, _ secret: ExtractionSecret) throws {}
    }

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
            credentialStore: StubCredentialStore(),
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
        // then holds three rows (PDF, HTML, and the registration-derived epub
        // route). Row views only exist after the async snapshot load rebuilds
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
            self.firstTableView(window)?.numberOfRows == 3
        }
        // The hosted hierarchy contains a native table (row views) inside a
        // clip view — the scrollable, window-bounded layout.
        let content = try #require(window.contentView)
        #expect(containsDescendant(content) { $0 is NSClipView })
        let table = try #require(firstTableView(window))
        #expect(table.numberOfRows == 3)
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

        // Fixed status vocabulary.
        #expect(source.contains("\"Available\""))
        #expect(source.contains("\"Using fallback\""))
        #expect(source.contains("\"Not installed\""))
        #expect(source.contains("\"Waiting for host service\""))
        #expect(source.contains("\"Failed to activate\""))

        // The picker writes through the dual-write mapping with auto-save; no
        // synchronous state write from a representable update path.
        #expect(source.contains("ExtractorRouteSettingsMapping.write(selection, route: row.route, into: &config)"))
        #expect(source.contains("rebuildRouteRows()"))
        #expect(source.contains("NSViewRepresentable") == false)

        // ACP and Docling configuration follows the PDF route selection only.
        #expect(source.contains("switch routeSelections[ExtractorRouteID.canonicalPDF.description]"))
        #expect(source.contains("case .connectedService(.acp): acpSection"))
        #expect(source.contains("case .connectedService(.doclingServe): doclingSection"))

        // Technical MIME identity stays out of the primary columns (help text).
        #expect(source.contains("MIME type: \\(row.route.mimeType.rawValue)"))
        #expect(source.contains("Text(\"\\(row.route.mimeType.rawValue)\")") == false)

        // The podcast picker is a separate control wired to the podcast
        // binding, outside the route table, visually grouped by the
        // Transcripts sub-header.
        #expect(source.contains("podcastBackendBinding"))
        #expect(source.contains("Picker(\"Podcast Transcript\", selection: podcastBackendBinding)"))
        #expect(source.contains("Label(\"Transcripts\", systemImage: \"mic\")"))
    }

    /// A stale installed selection keeps the row's fallback active: the write
    /// path persists the typed reference and the fixed fallback still resolves
    /// through the production resolver (persisted-file round trip).
    @Test("a stale installed selection persists and still resolves to the fallback")
    func staleSelectionShowsFallbackStatus() async throws {
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
        #expect(decision.selection == .pdfBuiltIn(.localPdf2md))
        #expect(decision.diagnostic == .unavailableInstalled(logical))

        // And the mounted view's builder reports the fallback status for it.
        let rows = ExtractorRouteTableBuilder.build(.init(
            configuration: reloaded,
            registrations: []))
        let pdf = rows.first { $0.route == .canonicalPDF }
        #expect(pdf?.status == .usingFallback(description: "Bundled pdf2md extraction"))
        #expect(pdf?.savedSelection == .installed(logical))
    }
}
#endif
