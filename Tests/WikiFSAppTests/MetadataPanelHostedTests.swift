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
        let host = try await host(width: MetadataMetrics.minimumWidth)
        #expect(host.view.frame.width == MetadataMetrics.minimumWidth)
        #expect(MetadataLayout.usesStackedRows(for: host.view.frame.width))
    }

    @Test func hostedInspectorAt500UsesGridRows() async throws {
        let host = try await host(width: MetadataMetrics.maximumWidth)
        #expect(host.view.frame.width == MetadataMetrics.maximumWidth)
        #expect(!MetadataLayout.usesStackedRows(for: host.view.frame.width))
    }

    @Test func hostedThresholdUsesStackedBelowAndGridAt300() async throws {
        let below = try await host(width: MetadataMetrics.stackedRowThreshold - 1)
        let at = try await host(width: MetadataMetrics.stackedRowThreshold)
        #expect(MetadataLayout.usesStackedRows(for: below.view.frame.width))
        #expect(!MetadataLayout.usesStackedRows(for: at.view.frame.width))
    }

    @Test func hostedInspectorSupportsWrappedValues() async throws {
        let host = try await host(width: MetadataMetrics.minimumWidth, value: String(repeating: "Readable metadata value ", count: 12))
        #expect(host.view.frame.height == 240)
        #expect(host.view.fittingSize.height > 0)
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
            outline: { EmptyView() })
        let host = try await host(view: view, width: 220)
        #expect(host.view.fittingSize.width > 0)
    }

    @Test func hostedRowsExposeLabelsValuesAndHints() async throws {
        let host = try await host(width: 320)
        #expect(!host.view.subviews.isEmpty)
        #expect(host.view.accessibilityRole() != nil)
    }

    @Test func hostedActionsAreKeyboardAndVoiceOverReachable() async throws {
        var invoked = false
        let panel = MetadataPanelView(
            state: .loaded(actionModel()), width: 320,
            performAction: { _ in invoked = true }, openLink: { _ in })
        let host = try await host(view: panel, width: 320)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        host.view.layoutSubtreeIfNeeded()
        let button = try #require(allSubviews(of: host.view).compactMap { $0 as? NSButton }.first)
        #expect(button.isEnabled)
        button.performClick(nil)
        #expect(invoked)
    }

    @Test func hostedIdentifiersAreSelectable() async throws {
        let panel = MetadataPanelView(state: .loaded(identifierModel()), width: 320, performAction: { _ in }, openLink: { _ in })
        let host = try await host(view: panel, width: 320)
        #expect(host.view.fittingSize.width > 0)
    }

    @Test func renderingMetadataPerformsNoStoreRead() async throws {
        let host = try await host(width: 320)
        host.view.layoutSubtreeIfNeeded()
        #expect(host.view.fittingSize.height > 0)
    }

    private func host(width: CGFloat, value: String = "Value") async throws -> NSHostingController<MetadataPanelView> {
        let panel = MetadataPanelView(
            state: .loaded(model(value: value)),
            width: width,
            performAction: { _ in },
            openLink: { _ in })
        return try await host(view: panel, width: width)
    }

    private func host<V: View>(view: V, width: CGFloat) async throws -> NSHostingController<V> {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        _ = Self.app
        let host = NSHostingController(rootView: view)
        host.view.frame = NSRect(x: 0, y: 0, width: width, height: 240)
        host.view.layoutSubtreeIfNeeded()
        return host
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
}
