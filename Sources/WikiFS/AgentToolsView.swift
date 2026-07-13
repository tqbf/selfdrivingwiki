import SwiftUI
import WikiFSEngine
import WikiFSCore
import WikiFSEngine

/// The Chats section — a small SwiftUI `List` of the wiki's chat history.
/// Mirrors the Pages/Sources/Bookmarks tabs: single-purpose, focused on one
/// content type. Maintenance/diagnostic surfaces (Lint, Instructions,
/// Activity) moved to the app's maintenance menu (issue #282). These are
/// navigation items, so single-click selects AND opens (the binding's `set`
/// calls `store.openTab`). No per-row gesture, so no latency.
struct AgentToolsView: View {
    @Bindable var store: WikiStoreModel
    /// The chat launcher — backs the live indicator on recent-chat rows (D4).
    /// Chats are always write-capable (the read-only Ask mode was removed).
    @Bindable var chatLauncher: AgentLauncher

    /// The chat being renamed, if any. Non-nil presents the rename alert. The
    /// draft text is tracked separately so the rename can be committed on
    /// confirm. (D4)
    @State private var renamingChat: ChatSummary?
    @State private var renameDraft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            chatsHeader
            chatSearchBar
            Divider()
            ScrollViewReader { proxy in
                List(selection: Binding(
                    get: { store.activeTab?.selection },
                    set: { sel in if let sel { store.openTab(sel) } }
                )) {
                    ForEach(visibleChats) { chat in
                        RecentChatRow(
                            chat: chat,
                            isLive: isLive(chat)
                        )
                            .tag(WikiSelection.chat(chat.id))
                            .draggable(SidebarDragPayloadList([
                                SidebarDragPayload(kind: .chat, id: chat.id.rawValue)
                            ]))
                            .contextMenu {
                                Button("Rename Chat…") {
                                    renameDraft = chat.title
                                    renamingChat = chat
                                }
                                Button("Delete Chat", role: .destructive) {
                                    store.deleteChat(id: chat.id)
                                }
                            }
                    }
                }
                .overlay {
                    if visibleChats.isEmpty && !store.chatSearchQuery.isEmpty {
                        Text("No matching chats")
                            .foregroundStyle(.secondary).font(.callout)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .padding(.top, 4)
                // "Show In List" reveal: a detail-view button requested that a
                // chat be surfaced. The active tab already selects this chat
                // (we're viewing it), so the row is highlighted — we only need
                // to scroll it into view. `.onAppear` covers the freshly-mounted
                // case (SidebarView just switched to the Chats section);
                // `.onChange` covers the already-visible case.
                .onAppear { revealPendingChat(proxy: proxy) }
                .onChange(of: store.pendingSidebarRevealVersion) { _, _ in
                    revealPendingChat(proxy: proxy)
                }
            }
        }
        // Rename alert: a single `.alert` driven by `renamingChat`, with a text
        // field. Commit on the primary action, dismiss otherwise. The store
        // method (`store.renameChat`) is the first UI caller of the tested
        // `WikiStore.renameChat` path. (D4)
        .alert("Rename Chat", isPresented: Binding(
            get: { renamingChat != nil },
            set: { if !$0 { renamingChat = nil } }
        )) {
            TextField("Chat title", text: $renameDraft)
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
            Text("Enter a new title for this chat.")
        }
    }

    // MARK: - Chats header

    /// Section header: title on the leading edge, a `+` button on the trailing
    /// edge — mirrors `BookmarksContainerView`'s `bookmarksHeader` (native
    /// macOS pattern: Photos, Mail, Finder sidebar section headers). The `+`
    /// opens the draft state for a new chat by retargeting/opening a tab to
    /// `.newChat` — the same draft state `ChatView` renders with `chatID ==
    /// nil`. This reuses the existing `store.openTab` path rather than
    /// duplicating tab logic. (D4)
    private var chatsHeader: some View {
        HStack {
            Text("Chats")
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer()
            Button {
                store.openTab(.newChat)
            } label: {
                Image(systemName: "plus")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .help("New Chat")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Chats search

    /// The chats shown in the list: all chats (most-recent-first) when the
    /// search bar is empty, else the hybrid search results.
    private var visibleChats: [ChatSummary] {
        store.chatSearchQuery.isEmpty ? store.chats : store.chatSearchResults
    }

    /// Compact search bar mirroring the Pages/Sources sidebars: magnifier +
    /// plain text field + a clear button. Bound to `store.chatSearchQuery`,
    /// which debounces a hybrid (FTS + semantic) search.
    private var chatSearchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary).font(.callout)
            TextField("Search chats…", text: $store.chatSearchQuery)
                .textFieldStyle(.plain).font(.callout).disableAutocorrection(true)
            if !store.chatSearchQuery.isEmpty {
                Button { store.chatSearchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Live indicator

    /// The single chat launcher. Chats are always write-capable now (the
    /// read-only Ask mode was removed), so there is one launcher. (D4)
    private func launcher(for kind: ChatKind) -> AgentLauncher {
        chatLauncher
    }

    /// A row is live when it is the active session of the chat launcher
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

    /// Scroll to the chat row requested by the "Show In List" button, then
    /// consume the pending reveal so it fires exactly once. The scroll is
    /// deferred to the next runloop pass so the List has laid out its rows
    /// when this view was just mounted by the section switch in `SidebarView`.
    private func revealPendingChat(proxy: ScrollViewProxy) {
        guard let pending = store.pendingSidebarReveal,
              case .chat(let id) = pending else { return }
        store.consumePendingSidebarReveal()
        DispatchQueue.main.async {
            withAnimation {
                proxy.scrollTo(WikiSelection.chat(id), anchor: .center)
            }
        }
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

/// One row in the "Recent Chats" section. When `isLive` is true a
/// small tinted `circle.fill` + "responding…" caption is shown so the
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
                    .accessibilityLabel("Chat is responding")
                } else {
                    Text(chat.updatedAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } icon: {
            Image(systemName: ResourceKind.chat.systemImageName)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 18)
        }
        .padding(.vertical, 3)
    }
}
