import SwiftUI
import WikiFSEngine
import WikiFSCore
import WikiFSEngine

/// The Chats section — a native `NSTableView` (`ChatsListView`) of the wiki's
/// chat history. Mirrors the Pages/Sources/Bookmarks tabs structurally:
/// native multi-selection (Shift / Cmd / right-click), double-click to open,
/// drag-out, and batch context menus — so all four sidebar sections share the
/// same selection semantics. Maintenance/diagnostic surfaces (Lint,
/// Instructions, Activity) moved to the app's maintenance menu (issue #282).
struct AgentToolsView: View {
    @Bindable var store: WikiStoreModel
    /// The chat daemon coordinator — backs the live "responding…" indicator on
    /// rows (Phase C4: chat is daemon-hosted). `nil` when the daemon is down;
    /// rows then never show the live badge.
    @Environment(\.chatDaemonCoordinator) private var chatDaemon

    /// The chat being renamed, if any. Non-nil presents the rename alert. The
    /// draft text is tracked separately so the rename can be committed on
    /// confirm.
    @State private var renamingChat: ChatSummary?
    @State private var renameDraft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            chatsHeader
            chatSearchBar
            Divider()
            ZStack(alignment: .topLeading) {
                ChatsListView(store: store, chatDaemon: chatDaemon,
                              callbacks: callbacks)
                if visibleChats.isEmpty && !store.chatSearchQuery.isEmpty {
                    Text("No matching chats")
                        .foregroundStyle(.secondary).font(.callout)
                        .padding(.vertical, 8).padding(.horizontal, 4)
                }
            }
        }
        // Rename alert: driven by `renamingChat`. The `ChatsListViewController`
        // calls `onRename` with the clicked `ChatSummary`; the container owns
        // the alert text field so the rename can be edited before committing.
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
    /// `.newChat` — the same draft state `ChatDetailView` renders with `chatID ==
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

    // MARK: - Callbacks

    private var callbacks: ChatsListCallbacks {
        ChatsListCallbacks(
            onOpen: { ids in
                for id in ids { store.openTab(.chat(id)) }
            },
            onOpenBackground: { ids in
                for id in ids { store.openTabInBackground(.chat(id)) }
            },
            onRename: { chat in beginRename(chat) },
            onDelete: { ids in
                for id in ids { store.deleteChat(id: id) }
            })
    }

    private func beginRename(_ chat: ChatSummary) {
        renameDraft = chat.title
        renamingChat = chat
    }

    // MARK: - Live indicator (pure predicate, unit-tested)

    /// Pure predicate for the row live indicator: a row shows a "responding…"
    /// badge when its chat is the launcher's active live session AND that
    /// launcher is actively generating. Extracted as a pure static function so
    /// it is unit-testable without driving launcher state (mirrors
    /// `AgentLauncher.showsQueryDebugControls`). The native
    /// `ChatsListViewController.isLive` delegates to this.
    static func isLiveRow(
        activeChatID: String?, isGenerating: Bool, chatID: PageID
    ) -> Bool {
        isGenerating && activeChatID == chatID.rawValue
    }
}
