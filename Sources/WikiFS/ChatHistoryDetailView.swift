import SwiftUI
import WikiFSCore

/// Read-only view of one persisted conversation (issue #119). Renders through
/// the exact same `AgentTranscriptWebView` + `transcriptVisible` filter as the
/// live Query page, so a persisted chat looks identical to how it looked live.
struct ChatHistoryDetailView: View {
    @Bindable var store: WikiStoreModel
    let chatID: PageID

    @State private var messages: [ChatMessage] = []

    var body: some View {
        Group {
            if let chat {
                VStack(alignment: .leading, spacing: 0) {
                    header(for: chat)
                    Divider().opacity(PageEditorMetrics.dividerOpacity)
                    transcript
                }
            } else {
                ContentUnavailableView {
                    Label("Conversation Missing", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("This conversation is no longer available.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: chatID) {
            messages = store.chatMessages(chatID: chatID)
        }
    }

    private var chat: ChatSummary? {
        store.chats.first { $0.id == chatID }
    }

    @ViewBuilder
    private func header(for chat: ChatSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(chat.title)
                .font(.title2)
                .bold()
                .lineLimit(1)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                Text(chat.kind == .ask ? "Ask" : "Edit")
                Text("·")
                Text("\(chat.messageCount) message\(chat.messageCount == 1 ? "" : "s")")
                Text("·")
                Text(chat.updatedAt, format: .dateTime)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, PageEditorMetrics.contentInset)
        .padding(.top, PageEditorMetrics.contentInset)
        .padding(.bottom, PageEditorMetrics.sectionSpacing)
    }

    @ViewBuilder
    private var transcript: some View {
        let visible = messages.map(\.event).transcriptVisible
        if visible.isEmpty {
            VStack(spacing: 7) {
                Text("No messages were persisted for this conversation.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            AgentTranscriptWebView(
                events: visible,
                style: .chat,
                onWikiLink: WikiReaderView.onWikiLinkHandler(for: store)
            )
            .frame(maxWidth: ChatHistoryMetrics.chatColumnWidth, maxHeight: .infinity)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

private enum ChatHistoryMetrics {
    // Mirrors QueryConversationView's chat column width, which is `private` to
    // that file — kept as a local constant rather than reaching across files.
    static let chatColumnWidth: CGFloat = 900
}
