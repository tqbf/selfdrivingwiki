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
    @ViewBuilder let outline: () -> Outline

    @State private var dragStartWidth: Double? = nil

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
                            if dragStartWidth == nil {
                                dragStartWidth = outlineWidth
                            }
                            if let start = dragStartWidth {
                                let newWidth = start - Double(value.translation.width)
                                outlineWidth = max(180, min(500, newWidth))
                            }
                        }
                        .onEnded { _ in
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
                            store: store)
                        .padding()
                    }
                }
            }
            .frame(width: outlineWidth)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}
