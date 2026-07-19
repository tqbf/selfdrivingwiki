import SwiftUI
import WikiFSCore

/// A detail-view header with a collapsible disclosure area. The title row
/// (disclosure chevron + resource icon + editable title) is always visible;
/// the caller-provided metadata and action buttons appear only when expanded.
///
/// Each detail view owns its own `@State` expand toggle and passes it as a
/// binding, so the collapse state persists per-view (survives same-type tab
/// switches — SwiftUI keeps the view alive) while every fresh detail starts
/// collapsed.
///
/// **Layout:**
/// ```
/// collapsed:  ▸  [icon]  Title
/// expanded:   ▾  [icon]  Title
///                date · metadata
///                [Action buttons]
/// ```
struct CollapsibleDetailHeader<Expanded: View>: View {
    let systemImage: String
    let title: String
    var placeholder: String = "Untitled"
    var titleLineLimit: Int? = nil
    var isTitleDisabled: Bool = false
    @Binding var isExpanded: Bool
    let onTitleCommit: (String) -> Void
    @ViewBuilder let expandedContent: () -> Expanded

    var body: some View {
        VStack(alignment: .leading, spacing: PageEditorMetrics.sectionSpacing) {
            titleRow
            if isExpanded {
                expandedContent()
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Title row (always visible)

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 6) {
            Button {
                DebugLog.tabs("CollapsibleDetailHeader: chevron tapped — wasExpanded=\(isExpanded)")
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(isExpanded ? "Collapse header" : "Expand header")

            Label {
                EditableTitle(
                    title: title,
                    placeholder: placeholder,
                    lineLimit: titleLineLimit,
                    isDisabled: isTitleDisabled,
                    onCommit: onTitleCommit
                )
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            DebugLog.tabs("CollapsibleDetailHeader: header double-tapped — wasExpanded=\(isExpanded)")
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }
    }
}
