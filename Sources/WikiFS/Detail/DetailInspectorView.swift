import SwiftUI
import WikiFSCore

// MARK: - InspectorTab

/// The selected tab in the ``DetailInspectorView``. Persisted in `@AppStorage`
/// (via a `@Binding` from the caller) so the user's last-used tab is restored
/// on reopen.
enum InspectorTab: String, CaseIterable, Codable {
    case metadata
    case outline
    case history

    static let pageAvailableTabs: [InspectorTab] = [.metadata, .outline, .history]
    static let persistedChatAvailableTabs: [InspectorTab] = [.metadata, .outline]
    static let metadataOnlyAvailableTabs: [InspectorTab] = [.metadata]

    static func sourceAvailableTabs(hasOutline: Bool) -> [InspectorTab] {
        hasOutline ? pageAvailableTabs : [.metadata, .history]
    }

    static func decodePersisted(_ rawValue: String?) -> InspectorTab {
        guard let rawValue, !rawValue.isEmpty else { return .metadata }
        return InspectorTab(rawValue: rawValue) ?? .metadata
    }

    static func normalizedFallback(selection: InspectorTab, availableTabs: [InspectorTab]) -> InspectorTab {
        guard !availableTabs.isEmpty else { return .metadata }
        if availableTabs.contains(selection) { return selection }
        return availableTabs.contains(.metadata) ? .metadata : availableTabs[0]
    }

    static func normalize(
        selection: InspectorTab,
        availableTabs: [InspectorTab],
        reportProgrammerError: () -> Void = { assertionFailure("Inspector requires at least one tab") }
    ) -> InspectorTab {
        if availableTabs.isEmpty { reportProgrammerError() }
        return normalizedFallback(selection: selection, availableTabs: availableTabs)
    }

    var label: String {
        switch self { case .metadata: "Metadata"; case .outline: "Outline"; case .history: "History" }
    }

    var symbol: String {
        switch self { case .metadata: "info.circle"; case .outline: "list.bullet.indent"; case .history: "clock.arrow.circlepath" }
    }
}

// MARK: - DetailInspectorView

/// Xcode-style inspector panel for detail views. Shows an ordered, caller-
/// supplied set of Metadata, Outline, and History tabs when more than one is
/// available.
///
/// - **Outline tab**: renders the `@ViewBuilder` closure passed by the caller
///   (the page's `PageOutlineView` or the source's outline view).
/// - **History tab**: renders ``ProvenancePanel`` (origin + edit history).
///
/// Shared between page, source, and chat details. The resizable width divider lives at this level
/// so both tabs share the same column width. Provenance is passed in by the
/// caller (already loaded via a `.task(id:)` — this view does no I/O).
///
/// The `inspectorTab` and `outlineWidth` are `@Binding`s so each caller can
/// persist them under its own `@AppStorage` key (page vs. source) without
/// desync when switching views.
struct DetailInspectorView<Outline: View>: View {
    @Binding var inspectorTab: InspectorTab
    @Binding var outlineWidth: Double
    let availableTabs: [InspectorTab]
    let metadataState: MetadataHydrationState
    let origin: ProvenanceEntry?
    let history: [ProvenanceEntry]
    var onOpenChat: (ChatID) -> Void = { _ in }
    /// Optional entry to the Versions window (#817). Passed through to
    /// `ProvenancePanel.onCompareVersions` — injected by `PageDetailView`
    /// (page-only); `SourceDetailView` leaves this `nil` so the button is
    /// hidden for sources. See `ProvenancePanel.onCompareVersions`.
    var onCompareVersions: (() -> Void)? = nil
    var performMetadataAction: (MetadataActionTarget) -> Void = { _ in }
    var openMetadataLink: (MetadataLinkTarget) -> Void = { _ in }
    @ViewBuilder let outline: () -> Outline

    @State private var dragStartWidth: Double? = nil
    /// Transient width while the divider is being dragged. Kept as local state
    /// so the live resize re-renders only this inspector subtree (and a cheap
    /// layout pass on the sibling), instead of invalidating the whole parent
    /// `PageDetailView` body + writing `@AppStorage` on every frame — which is
    /// what caused the resize flicker. Committed to `outlineWidth` on release.
    @State private var liveWidth: Double? = nil

    /// The width to render: the in-flight drag value if dragging, else the
    /// persisted `outlineWidth`.
    private var effectiveWidth: Double { liveWidth ?? outlineWidth }

    /// Clamp a proposed inspector width to the allowed range.
    private func clampedWidth(_ width: Double) -> Double {
        max(MetadataMetrics.minimumWidth, min(MetadataMetrics.maximumWidth, width))
    }

    var body: some View {
        HStack(spacing: 0) {
            // Draggable divider on the inspector's leading edge — shared by
            // both tabs so the column width is always resizable.
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                .frame(maxHeight: .infinity)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
                .onHover { isHovering in
                    if isHovering {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let start = dragStartWidth ?? outlineWidth
                            if dragStartWidth == nil { dragStartWidth = start }
                            // Update local state only — no AppStorage write,
                            // no parent body invalidation, per drag frame.
                            liveWidth = clampedWidth(start - Double(value.translation.width))
                        }
                        .onEnded { value in
                            let start = dragStartWidth ?? outlineWidth
                            // Commit the final width to the persisted store once.
                            outlineWidth = clampedWidth(start - Double(value.translation.width))
                            liveWidth = nil
                            dragStartWidth = nil
                        }
                )
                .zIndex(1)

            VStack(alignment: .leading, spacing: 0) {
                if availableTabs.count >= 2 {
                    Picker("Inspector section", selection: $inspectorTab) {
                        ForEach(availableTabs, id: \.self) { tab in
                            Label(tab.label, systemImage: tab.symbol).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("Inspector section")
                    .padding(8)

                    Divider()
                }

                switch InspectorTab.normalizedFallback(selection: inspectorTab, availableTabs: availableTabs) {
                case .metadata:
                    MetadataPanelView(
                        state: metadataState,
                        width: effectiveWidth,
                        performAction: performMetadataAction,
                        openLink: openMetadataLink)
                case .outline:
                    outline()
                case .history:
                    ScrollView {
                        ProvenancePanel(
                            origin: origin,
                            history: history,
                            onOpenChat: onOpenChat,
                            onCompareVersions: onCompareVersions)
                        .padding()
                    }
                }
            }
            .frame(width: effectiveWidth)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}
