import SwiftUI
import WikiFSCore

// MARK: - InspectorTab

/// The selected tab in the ``DetailInspectorView``. Persisted in `@AppStorage`
/// (via a `@Binding` from the caller) so the user's last-used tab is restored
/// on reopen.
enum InspectorTab: String, CaseIterable {
    case outline
    case history
}

// MARK: - DetailInspectorView

/// Xcode-style inspector panel for detail views. Shows a segmented tab bar
/// at the top (Outline / History) and the selected tab's content below.
///
/// - **Outline tab**: renders the `@ViewBuilder` closure passed by the caller
///   (the page's `PageOutlineView` or the source's outline view).
/// - **History tab**: renders ``ProvenancePanel`` (origin + edit history).
///
/// Shared between `PageDetailView` and `SourceDetailView` so both have the
/// same tabbed inspector. The resizable width divider lives at this level
/// so both tabs share the same column width. Provenance is passed in by the
/// caller (already loaded via a `.task(id:)` — this view does no I/O).
///
/// The `inspectorTab` and `outlineWidth` are `@Binding`s so each caller can
/// persist them under its own `@AppStorage` key (page vs. source) without
/// desync when switching views.
struct DetailInspectorView<Outline: View>: View {
    @Binding var inspectorTab: InspectorTab
    @Binding var outlineWidth: Double
    let origin: ProvenanceEntry?
    let history: [ProvenanceEntry]
    var store: WikiStoreModel?
    /// Optional entry to the Versions window (#817). Passed through to
    /// `ProvenancePanel.onCompareVersions` — injected by `PageDetailView`
    /// (page-only); `SourceDetailView` leaves this `nil` so the button is
    /// hidden for sources. See `ProvenancePanel.onCompareVersions`.
    var onCompareVersions: (() -> Void)? = nil
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
        max(180, min(500, width))
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
                Picker("Inspector", selection: $inspectorTab) {
                    Label("Outline", systemImage: "list.bullet.indent")
                        .tag(InspectorTab.outline)
                    Label("History", systemImage: "clock.arrow.circlepath")
                        .tag(InspectorTab.history)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(8)

                Divider()

                switch inspectorTab {
                case .outline:
                    outline()
                case .history:
                    ScrollView {
                        ProvenancePanel(
                            origin: origin,
                            history: history,
                            store: store,
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
