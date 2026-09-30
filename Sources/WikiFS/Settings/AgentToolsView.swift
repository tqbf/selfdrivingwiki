import SwiftUI
import WikiFSEngine
import WikiFSCore

/// The Chats section — a native `NSTableView` (`ChatsListView`) of the wiki's
/// chat history. Mirrors the Pages/Sources/Bookmarks tabs structurally:
/// native multi-selection (Shift / Cmd / right-click), double-click to open,
/// drag-out, and batch context menus — so all four sidebar sections share the
/// same selection semantics — plus the same header filter/sort menu icons
/// (display-only, view-level state like Sources/Bookmarks).
/// Maintenance/diagnostic surfaces (Lint, Instructions, Activity) moved to
/// the app's maintenance menu (issue #282).
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
    /// Date-window "Show" filter backing the filter menu. `all` is the
    /// default and returns the list unchanged — view-level state like
    /// `PageDateFilter` in `PagesContainerView`.
    @State private var dateFilter: ChatDateFilter = .all
    /// Display order backing the "Sort by" menu. `lastUpdated` is the store's
    /// native `ORDER BY updated_at DESC` — today's default.
    @State private var sortOrder: ChatSortOrder = .lastUpdated

    var body: some View {
        // Touch the daemon's running-state token so SwiftUI re-renders (and
        // re-evaluates each row's "responding…" badge) when a chat starts or
        // stops. `runningStateToken` is read here — in the tracked body —
        // because `isChatGenerating(_:)` is called from the NSTableView data
        // source, which SwiftUI can't observe.
        let _ = chatDaemon?.runningStateToken
        VStack(spacing: 0) {
            chatsHeader
            chatSearchBar
            Divider()
            ZStack(alignment: .topLeading) {
                ChatsListView(store: store, chatDaemon: chatDaemon,
                              chats: visibleChats,
                              callbacks: callbacks)
                if visibleChats.isEmpty
                    && (!store.chatSearchQuery.isEmpty || dateFilter != .all) {
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
        // A sidebar reveal ("Show in Sidebar" from a chat's detail view) must
        // land on a visible row — drop the date filter if it hides the target.
        // (SidebarView drops the search query the same way; the filter is
        // view-local so it resets here. @State resets on section switch, so
        // only the already-mounted case needs this.)
        .onChange(of: store.pendingSidebarRevealVersion) { _, _ in
            guard case .chat(let id) = store.pendingSidebarReveal,
                  dateFilter != .all,
                  !visibleChats.contains(where: { $0.id == id })
            else { return }
            dateFilter = .all
        }
    }

    // MARK: - Chats header

    /// Section header: title on the leading edge, a `+` button and the
    /// filter/sort menu icons on the trailing edge — mirrors
    /// `BookmarksContainerView`'s `bookmarksHeader` and the Pages/Sources
    /// headers (native macOS pattern: Photos, Mail, Finder sidebar section
    /// headers), including the 24×24 button frame so the section rows share
    /// one height and the titles align. The `+` persists a durable empty
    /// chat via `store.beginNewChat()` and opens its `.chat(id)` tab, so the
    /// new row appears in this list immediately. The filter is a date-window
    /// "Show" menu and the sort a display-order picker — both display-only.
    private var chatsHeader: some View {
        HStack(spacing: 2) {
            Text("Chats")
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer()
            headerButton(systemImage: "plus", help: "New Chat") {
                store.beginNewChat()
            }
            filterMenu
            sortMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// The "Show" date-window filter — a filter icon whose dropdown lists
    /// All / Active Today / This Week / This Month, the same
    /// `Menu { Picker … }` pattern as the sibling sections' icons. The icon
    /// tints accent while a non-All window is active.
    private var filterMenu: some View {
        Menu {
            Picker("Filter", selection: $dateFilter) {
                Text("All").tag(ChatDateFilter.all)
                Text("Active Today").tag(ChatDateFilter.today)
                Text("This Week").tag(ChatDateFilter.week)
                Text("This Month").tag(ChatDateFilter.month)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.body)
                .frame(width: 24, height: 24)
                .foregroundStyle(dateFilter == .all ? Color.secondary : Color.accentColor)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show")
    }

    /// The "Sort by" control — a sort icon whose dropdown lists the display
    /// orders, the same `Menu { Picker … }` pattern as the filter icon. The
    /// icon tints accent while a non-default (non-Last Updated) sort is
    /// active. Last Updated is the store's native order — the default.
    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sortOrder) {
                Text("Last Updated").tag(ChatSortOrder.lastUpdated)
                Text("Newest First").tag(ChatSortOrder.newestFirst)
                Text("Title A–Z").tag(ChatSortOrder.titleAZ)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.body)
                .frame(width: 24, height: 24)
                .foregroundStyle(sortOrder == .lastUpdated ? Color.secondary : Color.accentColor)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort by")
    }

    /// A compact, borderless icon button for the header's trailing edge —
    /// the same 24×24 treatment as the Pages/Sources/Bookmarks headers.
    private func headerButton(systemImage: String, help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body)
                .frame(width: 24, height: 24)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Chats search

    /// The chats shown in the list: when the search bar is empty, the
    /// date-window filter selects and the display sort orders the store's
    /// chats (all most-recent-first natively); while searching, the hybrid
    /// search results render relevance-ranked — filter and sort do not apply
    /// (the same rule as Pages/Sources, which never sort search results).
    private var visibleChats: [ChatSummary] {
        if store.chatSearchQuery.isEmpty {
            return sortOrder.sorted(dateFilter.filtered(store.chats))
        }
        return store.chatSearchResults
    }

    /// Compact search bar mirroring the Pages/Sources sidebars: magnifier +
    /// plain text field + a clear button, same padding. Bound to
    /// `store.chatSearchQuery`, which debounces a hybrid (FTS + semantic)
    /// search.
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
        .padding(.horizontal, 4)
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
        activeChatID: ChatID?, isGenerating: Bool, chatID: ChatID
    ) -> Bool {
        isGenerating && activeChatID == chatID
    }
}
