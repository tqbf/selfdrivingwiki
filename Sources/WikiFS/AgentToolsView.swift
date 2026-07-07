import SwiftUI
import WikiFSCore

/// The Agent section — a small SwiftUI `List` of the agent mode entries (Ask /
/// Edit / Lint / Activity / Instructions). These are navigation items, so
/// single-click selects AND opens (the binding's `set` calls `store.openTab`),
/// restoring the behavior the shared-`List` had before the double-click
/// experiment. No per-row gesture, so no latency.
struct AgentToolsView: View {
    @Bindable var store: WikiStoreModel
    /// The Ask (read-only) conversation launcher — backs the live indicator on
    /// `.ask` recent-conversation rows (D4).
    @Bindable var askLauncher: AgentLauncher
    /// The Edit conversation launcher — backs the live indicator on `.edit`
    /// recent-conversation rows (D4).
    @Bindable var editLauncher: AgentLauncher

    /// The chat being renamed, if any. Non-nil presents the rename alert. The
    /// draft text is tracked separately so the rename can be committed on
    /// confirm. (D4)
    @State private var renamingChat: ChatSummary?
    @State private var renameDraft: String = ""

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
                SidebarModeRow(title: "Ask", subtitle: "New read-only conversation",
                    systemImage: "bubble.left.and.text.bubble.right")
                    .tag(WikiSelection.ask)
                    .help("Chat with the agent — read-only, the agent cannot write the wiki.")

                SidebarModeRow(title: "Edit", subtitle: "New editing conversation",
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
                    Section {
                        ForEach(store.chats) { chat in
                            RecentChatRow(
                                chat: chat,
                                isLive: isLive(chat)
                            )
                                .tag(WikiSelection.chat(chat.id))
                                .contextMenu {
                                    Button("Rename Conversation…") {
                                        renameDraft = chat.title
                                        renamingChat = chat
                                    }
                                    Button("Delete Conversation", role: .destructive) {
                                        store.deleteChat(id: chat.id)
                                    }
                                }
                        }
                    } header: {
                        recentConversationsHeader
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
        // Rename alert: a single `.alert` driven by `renamingChat`, with a text
        // field. Commit on the primary action, dismiss otherwise. The store
        // method (`store.renameChat`) is the first UI caller of the tested
        // `WikiStore.renameChat` path. (D4)
        .alert("Rename Conversation", isPresented: Binding(
            get: { renamingChat != nil },
            set: { if !$0 { renamingChat = nil } }
        )) {
            TextField("Conversation title", text: $renameDraft)
            Button("Rename") {
                let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if let chat = renamingChat, !trimmed.isEmpty {
                    store.renameChat(id: chat.id, to: trimmed)
                }
                renamingChat = nil
            }
            Button("Cancel", role: .cancel) {
                renamingChat = nil
            }
        } message: {
            Text("Enter a new title for this conversation.")
        }
    }

    // MARK: - Recent Conversations header

    /// The "Recent Conversations" header: the title on the left, a `+` menu on
    /// the right. The `+` opens the draft state for a mode (Ask default, Edit
    /// second) by retargeting/opening a tab to `.ask` / `.edit` — the same
    /// draft state `ConversationView` renders with `chatID == nil`. This reuses
    /// the existing `store.openTab` path rather than duplicating tab logic.
    /// (D4)
    private var recentConversationsHeader: some View {
        HStack {
            Text("Recent Conversations")
            Spacer()
            Menu {
                Button("Ask") { store.openTab(.ask) }
                Button("Edit") { store.openTab(.edit) }
            } label: {
                Image(systemName: "plus")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("New Conversation")
        }
        .textCase(nil)
    }

    // MARK: - Live indicator

    /// Resolve the matching launcher for a chat's kind. `.ask` → `askLauncher`,
    /// `.edit` → `editLauncher`. (D4)
    private func launcher(for kind: ChatKind) -> AgentLauncher {
        kind == .edit ? editLauncher : askLauncher
    }

    /// A row is live when it is the active session of the matching launcher
    /// AND that launcher is mid-generation. Delegates to the pure static
    /// predicate so the rule is unit-testable without driving launcher state.
    /// (D4)
    private func isLive(_ chat: ChatSummary) -> Bool {
        let match = launcher(for: chat.kind)
        return Self.isLiveRow(
            activeChatID: match.activeChatID,
            isGenerating: match.isGenerating,
            chatID: chat.id
        )
    }

    /// Pure predicate for the row live indicator: a row shows a "responding…"
    /// badge when its chat is the launcher's active live session AND that
    /// launcher is actively generating. Extracted as a pure static function so
    /// it is unit-testable without driving launcher state (mirrors
    /// `AgentLauncher.showsQueryDebugControls`). (D4)
    static func isLiveRow(
        activeChatID: String?, isGenerating: Bool, chatID: PageID
    ) -> Bool {
        isGenerating && activeChatID == chatID.rawValue
    }
}

/// One row in the "Recent Conversations" section — mirrors `SidebarModeRow`'s
/// layout but needs a `Text(_:format:)` subtitle (relative timestamp) instead
/// of a plain `String`, so it can't reuse that view unmodified. When `isLive`
/// is true a small tinted `circle.fill` + "responding…" caption is shown so the
/// one-per-kind live-session constraint is *visible* instead of surprising.
/// (D4)
private struct RecentChatRow: View {
    let chat: ChatSummary
    let isLive: Bool

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(chat.title)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if isLive {
                    HStack(spacing: 3) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.tint)
                        Text("responding…")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                    .lineLimit(1)
                    .accessibilityLabel("Conversation is responding")
                } else {
                    Text(chat.updatedAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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
