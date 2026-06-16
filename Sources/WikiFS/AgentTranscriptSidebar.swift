import SwiftUI

/// A trailing inspector for the active agent run. It reuses the operations
/// sheet's transcript renderer so inline page queries do not disappear into a
/// silent lock state.
struct AgentTranscriptSidebar: View {
    @Bindable var launcher: AgentLauncher
    let isExpanded: Bool
    let onCollapse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(PageEditorMetrics.dividerOpacity)
            AgentActivityView(launcher: launcher)
                .padding(AgentTranscriptMetrics.padding)
        }
        .frame(width: isExpanded ? AgentTranscriptMetrics.width : 0)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipped()
        .accessibilityHidden(!isExpanded)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Transcript", systemImage: "text.bubble")
                .font(.headline)
            Spacer()
            if launcher.isRunning {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Hide Transcript", systemImage: "sidebar.trailing") {
                onCollapse()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Hide transcript")
        }
        .padding(.horizontal, AgentTranscriptMetrics.padding)
        .padding(.vertical, 10)
    }
}

private enum AgentTranscriptMetrics {
    static let width: CGFloat = 340
    static let padding: CGFloat = 12
}
