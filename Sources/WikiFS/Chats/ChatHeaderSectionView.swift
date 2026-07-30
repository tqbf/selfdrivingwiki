// pattern: Imperative Shell

import SwiftUI
import WikiFSCore

struct ChatHeaderSectionView: View {
    let chat: ChatSummary
    @Binding var isHeaderExpanded: Bool
    let fileProviderAvailable: Bool
    let revealDebugFolderEnabled: Bool
    let revealDebugFolderHelp: String
    let onRename: (String) -> Void
    let onShowInList: () -> Void
    let onShare: () -> Void
    let onRevealInFinder: () -> Void
    let onRevealDebugFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PageEditorMetrics.sectionSpacing) {
            CollapsibleDetailHeader(
                systemImage: ResourceKind.chat.systemImageName,
                title: chat.title,
                placeholder: "Untitled Chat",
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
                    Spacer(minLength: 0)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, PageEditorMetrics.contentInset)
        .padding(.top, PageEditorMetrics.contentInset)
        .padding(.bottom, ChatMetrics.sectionSpacing)
    }
}
