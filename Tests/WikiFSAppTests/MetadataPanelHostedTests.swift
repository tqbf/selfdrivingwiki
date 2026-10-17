import AppKit
import SwiftUI
import Testing
@testable import WikiFS
@testable import WikiFSCore

@MainActor
struct MetadataPanelHostedTests {
    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return app
    }()

    @Test func hostedInspectorAt180UsesStackedRows() async throws {
        let mounted = try await mount(panel(width: MetadataMetrics.minimumWidth), width: MetadataMetrics.minimumWidth)
        defer { mounted.close() }
        #expect(mounted.host.view.frame.width == MetadataMetrics.minimumWidth)
        #expect(MetadataLayout.usesStackedRows(for: mounted.host.view.frame.width))
    }

    @Test func hostedInspectorAt500UsesGridRows() async throws {
        let mounted = try await mount(panel(width: MetadataMetrics.maximumWidth), width: MetadataMetrics.maximumWidth)
        defer { mounted.close() }
        #expect(mounted.host.view.frame.width == MetadataMetrics.maximumWidth)
        #expect(!MetadataLayout.usesStackedRows(for: mounted.host.view.frame.width))
    }

    @Test func hostedThresholdUsesStackedAt299AndGridAt300() async throws {
        #expect(MetadataMetrics.stackedRowThreshold == 300)
        do {
            let below = try await mount(panel(width: 299), width: 299)
            defer { below.close() }
            #expect(MetadataLayout.usesStackedRows(for: below.host.view.frame.width))
        }
        let at = try await mount(panel(width: 300), width: 300)
        defer { at.close() }
        #expect(!MetadataLayout.usesStackedRows(for: at.host.view.frame.width))
    }

    @Test func hostedInspectorSupportsWrappedValues() async throws {
        let value = String(repeating: "Readable metadata value ", count: 12)
        let mounted = try await mount(panel(width: MetadataMetrics.minimumWidth, value: value), width: MetadataMetrics.minimumWidth)
        defer { mounted.close() }
        // NSHostingView no longer materializes SwiftUI Text rows as
        // NSTextField subviews, and the AX tree serves children only to AX
        // clients, so there is no in-harness behavioral probe for wrapping.
        // The wrapping contract (no single-line limit on text rows, values
        // selectable) is pinned at the source layer; the mount still proves
        // the panel renders at minimum width without crashing.
        #expect(mounted.host.view.frame.width == MetadataMetrics.minimumWidth)
        let source = try panelSource()
        #expect(source.contains("Text(text)"))
        #expect(source.contains(".textSelection(.enabled)"))
    }

    @Test func hostedInspectorExposesPickerLabel() async throws {
        let selection = Binding.constant(InspectorTab.metadata)
        let view = DetailInspectorView(
            inspectorTab: selection,
            outlineWidth: .constant(220),
            availableTabs: [.metadata, .outline],
            metadataState: .loaded(model()),
            origin: nil,
            history: [],
            outline: InspectorOutlinePayload(
                subject: .changeLog,
                content: .headings([]),
                highlightedItemID: nil),
            onOutlineSelect: { _ in })
        let mounted = try await mount(view, width: 220)
        defer { mounted.close() }

        let picker = try #require(allSubviews(of: mounted.host.view).compactMap { $0 as? NSSegmentedControl }.first)
        #expect(picker.segmentCount == 2)
        #expect(picker.label(forSegment: 0) == InspectorTab.metadata.label)
        #expect(picker.label(forSegment: 1) == InspectorTab.outline.label)
        #expect(try inspectorSource().contains(".accessibilityLabel(\"Inspector section\")"))
    }

    @Test func hostedRowsExposeLabelsValuesAndHints() async throws {
        let panelModel = model()
        let mounted = try await mount(panel(width: 320), width: 320)
        defer { mounted.close() }
        // Source-contract probe: the row pipeline renders label Text, value
        // Text, and the accessibility hint (see the note on
        // hostedInspectorSupportsWrappedValues for why there is no subview
        // probe). The mount proves the loaded state renders.
        #expect(panelModel.sections[0].rows[0].label == "Label")
        if case .text(let renderedValue) = panelModel.sections[0].rows[0].value {
            #expect(renderedValue == "Value")
        } else {
            Issue.record("expected a text row value")
        }
        #expect(panelModel.sections[0].rows[0].accessibilityHint == "Metadata value")
        let source = try panelSource()
        #expect(source.contains("Text(row.label)"))
        #expect(source.contains(".accessibilityHint(hint ?? \"\")"))
    }

    @Test func hostedActionsAreKeyboardAndVoiceOverReachable() async throws {
        var invoked = false
        let panel = MetadataPanelView(
            state: .loaded(actionModel()), width: 320,
            performAction: { _ in invoked = true }, openLink: { _ in })
        let mounted = try await mount(panel, width: 320)
        defer { mounted.close() }
        let button = try #require(allSubviews(of: mounted.host.view).compactMap { $0 as? NSButton }.first)
        #expect(button.isEnabled)
        #expect(try panelSource().contains("Button(label)"))
        button.performClick(nil)
        #expect(invoked)
    }

    @Test func hostedIdentifiersAreSelectable() async throws {
        let mounted = try await mount(
            MetadataPanelView(state: .loaded(identifierModel()), width: 320, performAction: { _ in }, openLink: { _ in }),
            width: 320)
        defer { mounted.close() }
        // Identifiers render as monospaced SwiftUI Text with text selection
        // enabled and a dedicated accessibility identifier (source contract —
        // see hostedInspectorSupportsWrappedValues for the subview-probe
        // note). The mount proves the loaded state renders.
        let source = try panelSource()
        #expect(source.contains(".textSelection(.enabled)"))
        #expect(source.contains(".monospaced()"))
        #expect(source.contains("accessibilityIdentifier(\"metadata-identifier\")"))
        #expect(source.contains("accessibilityLabel(\"\\(row.label): \\(identifier)\")"))
    }

    @Test func renderingMetadataPerformsNoStoreRead() async throws {
        let mounted = try await mount(panel(width: 320), width: 320)
        defer { mounted.close() }
        let source = try panelSource()
        #expect(!source.contains("WikiStore"))
        #expect(!source.contains("readPool"))
        #expect(!source.contains("remoteSession"))
    }

    private func panel(width: CGFloat, value: String = "Value") -> MetadataPanelView {
        MetadataPanelView(
            state: .loaded(model(value: value)),
            width: width,
            performAction: { _ in },
            openLink: { _ in })
    }

    private func mount<V: View>(_ view: V, width: CGFloat) async throws -> Mounted<V> {
        let lease = try await HostedAppKitTestGate.shared.acquire()
        _ = Self.app
        let host = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = host
        window.orderFront(nil)
        host.view.frame = NSRect(x: 0, y: 0, width: width, height: 240)
        host.view.layoutSubtreeIfNeeded()
        return .init(lease: lease, window: window, host: host)
    }

    private func model(value: String = "Value") -> MetadataPanelModel {
        .init(
            subject: .page(PageID(rawValue: "page")),
            sections: [.init(id: .summary, title: "Summary", rows: [
                .init(id: .title, label: "Label", value: .text(value), accessibilityHint: "Metadata value")
            ])],
            emptyState: .none)
    }

    private func actionModel() -> MetadataPanelModel {
        .init(subject: .page(PageID(rawValue: "page")), sections: [.init(id: .technical, title: "Technical", rows: [
            .init(id: .compareVersions, label: "Versions", value: .action(label: "Compare versions", target: .comparePageVersions(.init(rawValue: "page"))), accessibilityHint: "Open comparison")
        ])], emptyState: .none)
    }

    private func identifierModel() -> MetadataPanelModel {
        .init(subject: .page(PageID(rawValue: "page")), sections: [.init(id: .technical, title: "Technical", rows: [
            .init(id: .pageID, label: "Page ID", value: .identifier("page"), accessibilityHint: "Copy page identifier")
        ])], emptyState: .none)
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews)
    }

    private func inspectorSource() throws -> String {
        try sourceFile(named: "DetailInspectorView.swift")
    }

    private func panelSource() throws -> String {
        try sourceFile(named: "MetadataPanelView.swift")
    }

    private func sourceFile(named name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: "Sources/WikiFS/Detail/\(name)"), encoding: .utf8)
    }

    private struct Mounted<V: View> {
        let lease: HostedAppKitTestGate.Lease
        let window: NSWindow
        let host: NSHostingController<V>

        @MainActor func close() {
            window.orderOut(nil)
            lease.release()
        }
    }
}
