// pattern: Imperative Shell

import SwiftUI
import WikiFSCore

struct ChatHeaderSectionView: View {
    let chat: ChatSummary
    @Binding var isHeaderExpanded: Bool
    let fileProviderAvailable: Bool
    let revealDebugFolderEnabled: Bool
    let revealDebugFolderHelp: String
    /// True while this chat's query is answering or queued — the window in
    /// which the relocated run-diagnostics controls used to appear through
    /// the floating Activity menu
    /// (`ChatDetailPresentation.showsDebugControls`).
    let showsDebugControls: Bool
    @Binding var showsInternals: Bool
    let exitStatus: Int32?
    let debugFolderURL: URL?
    let onRename: (String) -> Void
    let onShowInList: () -> Void
    let onShare: () -> Void
    let onRevealInFinder: () -> Void
    let onRevealDebugFolder: () -> Void
    let onCopyDiagnostics: () -> Void
    let onWriteDiagnosticsJSONL: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PageEditorMetrics.sectionSpacing) {
            CollapsibleDetailHeader(
                systemImage: ResourceKind.chat.systemImageName,
                title: chat.title,
                placeholder: "New Chat",
                titleLineLimit: 1,
                isExpanded: $isHeaderExpanded,
                onTitleCommit: onRename
            ) {
                Text(chat.updatedAt, style: .date)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if isHeaderExpanded {
                HStack(spacing: 10) {
                    Button("Show in List", systemImage: "sidebar.left", action: onShowInList)
                        .help("Reveal this chat in the sidebar")
                    if fileProviderAvailable {
                        Button("Share", systemImage: "square.and.arrow.up", action: onShare)
                            .help("Share this chat")
                        Button("Reveal in Finder", systemImage: "folder", action: onRevealInFinder)
                            .help("Reveal this chat file in Finder")
                    }
                    Button("Reveal Debug Folder", systemImage: "folder.badge.gearshape", action: onRevealDebugFolder)
                        .disabled(revealDebugFolderEnabled == false)
                        .help(revealDebugFolderHelp)
                    if showsDebugControls {
                        runDiagnosticsControls
                    }
                    Spacer(minLength: 0)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, PageEditorMetrics.contentInset)
        .padding(.top, PageEditorMetrics.contentInset)
        .padding(.bottom, ChatMetrics.sectionSpacing)
    }

    /// The former floating Activity menu, relocated: the raw-activity
    /// toggle, the redacted snapshot exports, and the process exit status.
    /// Shown only while the chat is answering or queued.
    @ViewBuilder
    private var runDiagnosticsControls: some View {
        Toggle("Show Full Activity", systemImage: "activity", isOn: $showsInternals)
            .toggleStyle(.button)
            .help("Swap the transcript for the raw live activity view")
        Button("Copy Diagnostics", systemImage: "doc.on.doc", action: onCopyDiagnostics)
            .help("Copy a redacted app and daemon diagnostic snapshot")
        if let debugFolderURL {
            Button("Write Redacted Diagnostics JSONL", systemImage: "doc.text") {
                onWriteDiagnosticsJSONL(debugFolderURL.appendingPathComponent("chat-diagnostics.jsonl"))
            }
            .help("Append redacted trace records to the debug folder")
        }
        if let exitStatus {
            Label(
                exitStatus == 0 ? "Ended" : "Exited \(exitStatus)",
                systemImage: exitStatus == 0 ? "checkmark.circle" : "xmark.circle"
            )
            .foregroundStyle(.secondary)
            .help("Chat process exit status")
        }
    }
}
