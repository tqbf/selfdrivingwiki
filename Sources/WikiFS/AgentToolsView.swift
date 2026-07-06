import SwiftUI
import WikiFSCore

/// The Agent section — a small SwiftUI `List` of the agent mode entries (Ask /
/// Edit / Lint / Activity / Instructions). These are navigation items, so
/// single-click selects AND opens (the binding's `set` calls `store.openTab`),
/// restoring the behavior the shared-`List` had before the double-click
/// experiment. No per-row gesture, so no latency.
struct AgentToolsView: View {
    @Bindable var store: WikiStoreModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Agent").font(.headline).foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            List(selection: Binding(
                get: { store.activeTab?.selection },
                set: { sel in if let sel { store.openTab(sel) } }
            )) {
                SidebarModeRow(title: "Ask", subtitle: "Read-only Q&A",
                    systemImage: "bubble.left.and.text.bubble.right")
                    .tag(WikiSelection.ask)
                    .help("Chat with the agent — read-only, the agent cannot write the wiki.")

                SidebarModeRow(title: "Edit", subtitle: "Ask & update the wiki",
                    systemImage: "square.and.pencil")
                    .tag(WikiSelection.edit)
                    .help("Chat with the agent and let it update the wiki.")

                SidebarModeRow(title: "Lint", subtitle: "Health-check the wiki",
                    systemImage: "checkmark.shield")
                    .tag(WikiSelection.lint)
                    .help("Check the wiki for stale content, broken links, and inconsistencies")

                SidebarModeRow(title: "Activity", subtitle: "Operation log",
                    systemImage: "clock.arrow.circlepath")
                    .tag(WikiSelection.changeLog)
                    .help("Operation history, projected read-only as log.md")

                SidebarModeRow(title: "Instructions", subtitle: "Agent prompt",
                    systemImage: "sparkles")
                    .tag(WikiSelection.systemPrompt)
                    .help("Agent instructions, projected read-only as CLAUDE.md and AGENTS.md")

                if !store.chats.isEmpty {
                    Section("Recent Conversations") {
                        ForEach(store.chats) { chat in
                            RecentChatRow(chat: chat)
                                .tag(WikiSelection.chat(chat.id))
                                .contextMenu {
                                    Button("Delete Conversation", role: .destructive) {
                                        store.deleteChat(id: chat.id)
                                    }
                                }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }
}

/// One row in the "Recent Conversations" section — mirrors `SidebarModeRow`'s
/// layout but needs a `Text(_:format:)` subtitle (relative timestamp) instead
/// of a plain `String`, so it can't reuse that view unmodified.
private struct RecentChatRow: View {
    let chat: ChatSummary

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(chat.title)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(chat.updatedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: chat.kind == .ask ? "bubble.left.and.bubble.right" : "square.and.pencil")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 18)
        }
        .padding(.vertical, 3)
    }
}
