import AppKit
import WikiFSEngine
import SwiftUI
import WikiFSEngine
import WikiFSCore

/// The unified chat surface (D2, pillar 2). One view replaces the split
/// between the live `ChatView` and the read-only
/// `ChatHistoryDetailView`. Whether you see streaming deltas or a persisted
/// transcript depends on the **source-of-truth rule**: if this chat is the
/// launcher's active live session (`activeChatID == chatID`), render
/// `launcher.events` (in-memory, streaming). Otherwise render the persisted
/// `store.chatMessages(chatID:)`.
///
/// The `.newChat` draft state also routes here (with `chatID == nil`),
/// showing the empty-composer state until the first send retargets the tab to
/// `.chat(id)` (the draft-state morph, handled by `AgentOperationRunner`).
/// Chats are always write-capable (the read-only Ask mode was removed).
struct ChatView: View {
    /// The persisted chat id, or `nil` for the draft state (.newChat). When
    /// non-nil AND equal to `launcher.activeChatID`, the view renders live.
    let chatID: PageID?

    @Bindable var store: WikiStoreModel
    @Bindable var launcher: AgentLauncher
    /// The per-active-wiki session (store + launchers + descriptor).
    var session: WikiSession
    let fileProvider: FileProviderFacade

    @State private var showsInternals = false
    @State private var composerHeight: CGFloat = ComposerTextView.oneLineHeight(for: ChatMetrics.composerFont)
    @State private var persistedMessages: [ChatMessage] = []
    /// Items dragged from the sidebar onto the chat composer, attached as
    /// context for the next message (issue #385).
    @State private var attachments: [ChatAttachment] = []
    @AppStorage("chat.zoom") private var chatZoom = Double(ZoomScale.defaultScale)
    /// Outline starts collapsed on every new chat view instance — not a
    /// persisted global toggle (was @AppStorage). Each time you switch to a
    /// chat tab the outline is closed by default; the user can expand it
    /// within that view's lifetime.
    @State private var chatOutlineExpanded = false
    /// Per-view collapse state for the header. Starts collapsed; persists
    /// across same-type tab switches (SwiftUI keeps the view alive).
    @State private var isHeaderExpanded = false
    /// Persisted toggle to hide tool-call rows from the chat transcript
    /// (issue #381). Independent of "Show internals" which gates the full
    /// raw activity feed.
    @AppStorage("chat.hideToolCalls") private var hideToolCalls = false
    @State private var outlineScroll: ChatScrollRequest? = nil
    @State private var quoteAnchor: ChatHighlightRequest? = nil
    /// The chat's always-ask/yolo mode (shared with the launcher, read at spawn).
    /// v1 app-wide, default off (yolo). Applies to the next conversation.
    ///
    /// #607: chat reads its OWN `chatPermissionMode` key (was the shared
    /// `agentPermissionMode` before the per-operation split). Ingest/lint have
    /// their own pickers in Settings → Agents → Permissions. This chip governs
    /// interactive chat only.
    @AppStorage(AgentLauncher.PermissionModeKey.chat) private var permissionModeRaw = PermissionPolicy.bypass.rawValue

    /// True when this surface is rendering the active live session (D2
    /// source-of-truth rule). The view sources from `launcher.events`; when
    /// false, it sources from the persisted `store.chatMessages(chatID:)`.
    private var isLiveChat: Bool {
        guard let chatID else { return false }
        return launcher.activeChatID == chatID.rawValue
    }

    /// Pure source-of-truth selector (D2): the live session streams from
    /// `launcher.events`; everything else renders the persisted rows. Both are
    /// `transcriptVisible`-filtered. Extracted as a static func so the selection
    /// logic is unit-testable without a SwiftUI view tree.
    ///
    /// `nonisolated`: this is a pure array selector (no view/actor state), so it
    /// can be called from nonisolated test contexts without crossing the main actor.
    nonisolated static func displayMessages(
        isLiveChat: Bool,
        launcherEvents: [AgentEvent],
        persistedEvents: [AgentEvent]
    ) -> [AgentEvent] {
        (isLiveChat ? launcherEvents : persistedEvents).transcriptVisible
    }

    /// The transcript-visible events this surface renders — `launcher.events`
    /// when live, the persisted rows otherwise. Fed to the single
    /// `ChatTranscriptView` (replacing the old live/persisted dual render sites).
    private var displayMessages: [AgentEvent] {
        Self.displayMessages(
            isLiveChat: isLiveChat,
            launcherEvents: launcher.events,
            persistedEvents: persistedMessages.map(\.event))
    }

    /// Wall-clock timestamps parallel to `displayMessages`. Live path:
    /// `launcher.eventTimestamps` (same indices as `launcher.events`); persisted
    /// path: `persistedMessages.map(\.createdAt)`. Filtered through
    /// `transcriptVisibleIndices` to stay parallel after tool-call/etc.
    /// filtering. `nil` entries (misaligned arrays from test setups or partial
    /// state) are preserved — they produce no footer.
    private var displayTimestamps: [Date?] {
        let indices: [Int]
        if isLiveChat {
            let events = launcher.events
            indices = events.transcriptVisibleIndices
            return indices.map { idx in
                idx < launcher.eventTimestamps.count ? launcher.eventTimestamps[idx] : nil
            }
        } else {
            let events = persistedMessages.map(\.event)
            indices = events.transcriptVisibleIndices
            return indices.map { idx in
                idx < persistedMessages.count ? persistedMessages[idx].createdAt : nil
            }
        }
    }

    /// Empty-state message for the transcript placeholder. The live streaming
    /// case overlays "Waiting for the Agent…" via `transcriptIsRunning`; the
    /// idle/persisted cases show their own message here.
    private var transcriptEmptyMessage: String {
        if chatID == nil {
            return "Ask a question, or ask the Agent to update the wiki…"
        }
        return isLiveChat ? "Ask a question to start a chat." : "No messages were persisted for this chat."
    }

    /// True only when THIS surface is the active live stream — so a persisted
    /// chat never shows the "Waiting for the Agent…" placeholder even while its
    /// launcher is generating a different chat.
    private var transcriptIsRunning: Bool {
        isLiveChat && launcher.isRunning
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                content
                if showsDebugControls {
                    controls
                        .padding(.top, ChatMetrics.debugTopInset)
                        .padding(.trailing, ChatMetrics.contentInset)
                }
            }
            .frame(minWidth: PageEditorMetrics.detailMinWidth)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .zoomShortcuts($chatZoom)
        .zoomScroll($chatZoom)
        .onChange(of: chatZoom) { _, _ in
            composerHeight = ComposerTextView.oneLineHeight(for: composerFont)
        }
        .onChange(of: launcher.isRunning) { _, isRunning in
            // Belt-and-suspenders: clear the internals toggle when a run ends so a
            // later ingest/lint run doesn't inherit it and strand the view on
            // `AgentQueueView`. (AC.1)
            if !isRunning { showsInternals = false }
        }
        .task(id: chatID) {
            // Reload persisted messages whenever the chatID changes (or the store
            // changes them). The live path doesn't use these, but a persisted chat
            // needs them, and a session-end flip from live→persisted must pick up
            // the committed transcript.
            if let chatID {
                persistedMessages = store.chatMessages(chatID: chatID)
            } else {
                persistedMessages = []
                // Omnibox "Ask" action (#288): if a pending question was set
                // (from the omnibox Ask action), pre-fill the composer and
                // auto-send it. This starts a new chat with the question.
                if let question = store.pendingChatQuestion {
                    store.pendingChatQuestion = nil
                    store.draftChatMessage = question
                }
            }
        }
        // D2: when the live session ends (activeChatID clears), re-read from the
        // store so the view flips source WITHOUT a visible change (the final
        // flush has already committed by the time activeChatID clears — see the
        // flip-timing gate in AgentLauncher.finish).
        .onChange(of: launcher.activeChatID) { _, _ in
            if let chatID, !isLiveChat {
                persistedMessages = store.chatMessages(chatID: chatID)
            }
        }
        // Reload persisted messages when the store changes (e.g. a new message
        // appended to a persisted chat — D3 continues append here, and this keeps
        // the persisted view live for renames/count updates when not live).
        .onChange(of: store.chats) { _, _ in
            if let chatID, !isLiveChat {
                persistedMessages = store.chatMessages(chatID: chatID)
            }
        }
        // Resolve a `[[chat:Title#"quote"]]` quote anchor (issue #281) to a
        // message highlight. Keyed on (chatID, anchorVersion, messageCount):
        // the anchorVersion dimension re-fires on a re-click to the same chat,
        // and the messageCount dimension re-fires once a persisted chat's
        // messages load — so the set-once anchor is consumed only when the
        // transcript is ready (it survives the 0→N load).
        .task(id: ChatAnchorTaskKey(
            chatID: chatID,
            anchorVersion: store.pendingScrollAnchorVersion,
            messageCount: displayMessages.count)) {
            guard let chatID, !displayMessages.isEmpty else { return }
            guard let fragment = store.consumePendingScrollAnchor(for: .chat(chatID)) else { return }
            let quote = ChatQuoteResolver.quoteText(fragment)
            guard !quote.isEmpty,
                  ChatQuoteResolver.messageIndex(of: fragment, in: displayMessages) != nil
            else { return }
            quoteAnchor = ChatHighlightRequest(
                version: (quoteAnchor?.version ?? 0) + 1,
                quote: quote)
        }
    }

    // MARK: - Controls (debug cluster + new chat)

    private var controls: some View {
        // Only the live chat gets the debug cluster + new chat button.
        // A persisted non-live chat is read-only — no controls.
        HStack(spacing: 8) {
            if showsDebugControls {
                if launcher.isGenerating {
                    ProgressView()
                        .controlSize(.small)
                }
                Menu {
                    Toggle("Show internals", isOn: $showsInternals)
                    Toggle("Hide tool calls", isOn: $hideToolCalls)
                    if let status = launcher.exitStatus {
                        Label(status == 0 ? "Ended" : "Exited \(status)", systemImage: status == 0 ? "checkmark.circle" : "xmark.circle")
                    }
                    if let debugURL = launcher.debugFolderURL {
                        Button("Reveal Debug Folder", systemImage: "folder.badge.gearshape") {
                            NSWorkspace.shared.activateFileViewerSelecting([debugURL])
                        }
                        .help("Open the complete debug trace folder (ACP messages, permissions, usage)")
                    }
                } label: {
                    Label("Activity", systemImage: "ellipsis.circle")
                }
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .help("Show activity and transcript internals")
            }
        }
    }

    private var showsDebugControls: Bool {
        (launcher.isGenerating || launcher.isAwaitingGenerationSlot)
            && launcher.runningKind == .query
    }

    /// The pending permission to surface as an inline Approve/Reject affordance,
    /// or nil when nothing is awaiting approval. Only the LIVE chat renders it
    /// (a persisted chat can't resolve a request); the first pending request is
    /// shown — ACP agents gate one write at a time, so there is at most one.
    private var livePendingPermission: PendingPermission? {
        guard isLiveChat, let first = launcher.pendingPermissions.first else { return nil }
        return first
    }

    // MARK: - Thinking indicator

    /// An inline "thinking" row shown in the transcript area while the agent is
    /// generating. Displays an animated spinner and an incrementing elapsed-time
    /// counter so it's obvious the agent is actively working (issue #384).
    private var thinkingIndicator: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                if let startedAt = launcher.runStartedAt {
                    Text("Thinking… \(durationString(context.date.timeIntervalSince(startedAt)))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Thinking…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    /// Formats a time interval as a compact duration string (e.g. "7s", "2m 30s").
    private func durationString(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        if seconds < 60 {
            return "\(seconds)s"
        }
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        if minutes < 60 {
            return remainingSeconds == 0 ? "\(minutes)m" : "\(minutes)m \(remainingSeconds)s"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
    }

    // MARK: - Content routing

    @ViewBuilder
    private var content: some View {
        if showsInternals && launcher.isRunning && launcher.runningKind == .query {
            AgentQueueView(launcher: launcher, showsResultEvents: false, showsInternals: true, onWikiLink: WikiReaderView.onWikiLinkHandler(for: store))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(ChatMetrics.contentInset)
        } else if chatID != nil && !isLiveChat && chatSummary == nil {
            // Persisted chat that no longer exists in the store.
            ContentUnavailableView {
                Label("Chat Missing", systemImage: ResourceKind.chat.systemImageName)
            } description: {
                Text("This chat is no longer available.")
            }
        } else {
            // Live, persisted, or draft (.newChat) chat: one transcript + one
            // composer (the D2 source-of-truth rule selects launcher.events vs
            // persisted rows). The draft state shows the empty-transcript
            // placeholder + composer at the bottom (no centered "Ask X" page).
            chatSurface
        }
    }

    // MARK: - Content + outline

    /// Wraps `content` with the optional right-side chat outline. Placed BELOW
    /// the header so the title pane spans full width and the outline sits beside
    /// the transcript (matching the page detail's content+outline layout).
    @ViewBuilder
    private func withChatOutline<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 0) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
            if chatOutlineExpanded {
                ChatOutlineView(entries: chatOutlineEntries) { turnIndex in
                    outlineScroll = ChatScrollRequest(
                        version: (outlineScroll?.version ?? 0) + 1,
                        turnIndex: turnIndex)
                }
            }
        }
    }

    // MARK: - Unified chat surface (live + persisted)

    /// One transcript + one composer for both the live (streaming) and persisted
    /// (read-only) chat. The D2 source-of-truth rule picks the event source via
    /// `displayMessages`; only the empty-state message + the composer's caption
    /// differ (persisted shows "No messages…" / the "another chat is responding"
    /// caption; live shows the streaming placeholder).
    @ViewBuilder
    private var chatSurface: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let chat = chatSummary {
                header(for: chat)
                Divider().opacity(PageEditorMetrics.dividerOpacity)
            }
            withChatOutline {
                VStack(spacing: 0) {
                    // Pre-spawn failure banner (#613): surfaces a previously
                    // captured `launcher.preflightError` so a rolled-back chat
                    // doesn't silently revert to the empty draft composer. The
                    // rollback (deleting the dead chat row) still happens — this
                    // only explains WHY the draft is visible. Mirrors the amber
                    // turn-failed banner visual from `ChatWebView`.
                    if let bannerError = preflightBannerMessage {
                        preflightBanner(bannerError)
                            .padding(.horizontal, PageEditorMetrics.contentInset + ChatMetrics.extraHorizontalMargin)
                            .padding(.top, chatSummary != nil ? ChatMetrics.sectionSpacing / 2 : ChatMetrics.chatTopInset)
                            .padding(.bottom, ChatMetrics.sectionSpacing / 2)
                    }
                    ChatTranscriptView(
                        events: displayMessages,
                        timestamps: displayTimestamps,
                        emptyStateMessage: transcriptEmptyMessage,
                        isRunning: transcriptIsRunning,
                        onWikiLink: WikiReaderView.onWikiLinkHandler(for: store),
                        renderContext: { [weak store] in store?.renderContext() },
                        blobStore: store,
                        zoom: chatZoom,
                        scrollRequest: outlineScroll,
                        quoteAnchor: quoteAnchor,
                        hideToolCalls: hideToolCalls
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, PageEditorMetrics.contentInset + ChatMetrics.extraHorizontalMargin)
                        .padding(.top, preflightBannerMessage == nil
                            ? (chatSummary != nil ? 0 : ChatMetrics.chatTopInset)
                            : 0)
                    if transcriptIsRunning && launcher.isGenerating {
                        thinkingIndicator
                            .padding(.horizontal, PageEditorMetrics.contentInset + ChatMetrics.extraHorizontalMargin)
                            .padding(.bottom, ChatMetrics.sectionSpacing / 2)
                    }
                    if let pending = livePendingPermission {
                        PermissionApprovalView(permission: pending) { optionId in
                            Task { await launcher.resolvePendingPermission(optionId: optionId) }
                        }
                        .padding(.horizontal, PageEditorMetrics.contentInset + ChatMetrics.extraHorizontalMargin)
                        .padding(.bottom, ChatMetrics.sectionSpacing / 2)
                    }
                    chatComposer
                        .padding(.horizontal, PageEditorMetrics.contentInset + ChatMetrics.extraHorizontalMargin)
                        .padding(.top, ChatMetrics.sectionSpacing)
                        .padding(.bottom, ChatMetrics.contentInset)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// The composer, placed once as a VStack sibling below the transcript (the
    /// live placement). For a persisted (non-live) chat it also carries the
    /// "another chat is responding" caption when the kind's launcher is busy.
    private var chatComposer: some View {
        VStack(spacing: 4) {
            composer(enabled: isComposerEnabled)
            if let caption = composerCaption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// The paseo-style toolbar row that sits INSIDE the composer box, along its
    /// bottom edge: the provider/model chip + the permission-mode chip on the
    /// leading side, then the send button on the trailing side. The selector
    /// chips are hidden when no wiki is active (no provider context); the send
    /// button is always present.
    @ViewBuilder
    private func composerToolbar(sendActive: Bool) -> some View {
        HStack(spacing: 10) {
            // Click-to-add context: a "+" that opens a searchable picker of the
            // wiki's pages/sources/chats. Selecting one attaches it as context
            // (same currency as the sidebar drag-and-drop path, issue #385).
            AddContextPicker(store: store) { payload in
                let attachment = ChatAttachment(payload: payload, store: store)
                if !attachments.contains(attachment) {
                    attachments.append(attachment)
                }
            }
            // Inside ContentView the session is always non-nil (a wiki is
            // open), so the provider/model chips are always shown.
            ProviderSelector(launcher: launcher)
            ThinkingEffortSelector(launcher: launcher)
            PermissionModeSelector(rawValue: $permissionModeRaw)
            Spacer(minLength: 0)
            if showsStopButton {
                stopButton
            } else if hasDraftText {
                // Paseo: the send button appears only once there's something to
                // send — an empty composer shows no action glyph at all.
                sendButton(active: sendActive)
            }
        }
        // Reserve the button's height so the box doesn't grow on the first
        // keystroke when the button appears.
        .frame(minHeight: ChatMetrics.sendButtonSize)
    }

    // MARK: - Persisted chat summary

    private var chatSummary: ChatSummary? {
        store.chats.first { $0.id == chatID }
    }

    /// Paired (question, response summary) entries for the chat outline. Each
    /// user turn is paired with the first assistant text that follows it
    /// (extracted to one sentence, elided), so the outline shows both sides of
    /// the conversation. Sourced from `displayMessages` (same events as the
    /// transcript).
    ///
    /// **Per-message summary (chat-summary plan §6.3):** for persisted chats,
    /// a cached `chat_messages.summary` wins over on-the-fly extraction — read
    /// once, never recomputed. The live (streaming) path has no row yet, so it
    /// always computes the default truncation on the fly (free); the summary is
    /// cached after the turn persists.
    private var chatOutlineEntries: [ChatOutlineEntry] {
        let msgs = displayMessages
        let timestamps = displayTimestamps
        // Align cached per-message summaries with `displayMessages` for the
        // persisted path. `visiblePersistedMessages` applies the same
        // `.transcriptVisible` filter as `displayMessages`, so indices match.
        // The live path returns all-nil (no row yet).
        let cachedSummaries: [String?] = isLiveChat
            ? Array(repeating: nil, count: msgs.count)
            : visiblePersistedMessages.map(\.summary)
        var entries: [ChatOutlineEntry] = []
        var pendingQuestion: String?
        var pendingQuestionTS: Date?
        for (i, event) in msgs.enumerated() {
            let ts = i < timestamps.count ? timestamps[i] : nil
            switch event {
            case .userText(let text):
                if let q = pendingQuestion {
                    entries.append(ChatOutlineEntry(question: q, response: nil,
                                                    questionTimestamp: pendingQuestionTS, responseTimestamp: nil))
                }
                pendingQuestion = humanizeAttachmentRefs(in: text)
                pendingQuestionTS = ts
            case .assistantText(let text):
                if let q = pendingQuestion {
                    let cached = i < cachedSummaries.count ? cachedSummaries[i] : nil
                    let summary = cached ?? ChatSummary.summaryExtract(from: text, maxLength: 200)
                    entries.append(ChatOutlineEntry(question: q, response: summary.isEmpty ? nil : summary,
                                                    questionTimestamp: pendingQuestionTS, responseTimestamp: ts))
                    pendingQuestion = nil
                    pendingQuestionTS = nil
                }
            case .result(_, let text):
                if let q = pendingQuestion {
                    let cached = i < cachedSummaries.count ? cachedSummaries[i] : nil
                    let summary = cached ?? ChatSummary.summaryExtract(from: text, maxLength: 200)
                    entries.append(ChatOutlineEntry(question: q, response: summary.isEmpty ? nil : summary,
                                                    questionTimestamp: pendingQuestionTS, responseTimestamp: ts))
                    pendingQuestion = nil
                    pendingQuestionTS = nil
                }
            default:
                break
            }
        }
        if let q = pendingQuestion {
            entries.append(ChatOutlineEntry(question: q, response: nil,
                                            questionTimestamp: pendingQuestionTS, responseTimestamp: nil))
        }
        return entries
    }

    /// The `.transcriptVisible` subset of `persistedMessages`, aligned with
    /// `displayMessages` for the persisted path (chat-summary plan §6.3). Used
    /// to read cached per-message summaries. Empty on the live path (no row
    /// exists yet — the view sources from `launcher.events`).
    private var visiblePersistedMessages: [ChatMessage] {
        guard !isLiveChat else { return [] }
        let indices = persistedMessages.map(\.event).transcriptVisibleIndices
        return indices.compactMap { idx in
            idx < persistedMessages.count ? persistedMessages[idx] : nil
        }
    }

    @ViewBuilder
    private func header(for chat: ChatSummary) -> some View {
        // The header is split into two rows:
        //
        //   1. Title + date (inside `CollapsibleDetailHeader`'s expanded
        //      content) — constrained to `readableContentWidth` so the
        //      editable title and date stay readable.
        //
        //   2. The action toolbar row (Show in List / Share / Reveal in
        //      Finder / Reveal Debug Folder + outline toggle) — rendered as
        //      a SIBLING of `CollapsibleDetailHeader`, NOT inside its
        //      expanded content, so it can span the FULL view width. The
        //      outline toggle (pinned to the trailing edge via `Spacer`)
        //      therefore aligns to the view edge, not the readable column
        //      edge. Previously this HStack lived inside the
        //      `readableContentWidth` frame, so the Spacer only reached the
        //      right edge of that constrained column and the toggle appeared
        //      wedged in the middle-right.
        //
        // Both rows are still gated on `isHeaderExpanded` so the collapse
        // chevron hides the actions exactly as before.
        VStack(alignment: .leading, spacing: PageEditorMetrics.sectionSpacing) {
            CollapsibleDetailHeader(
                systemImage: ResourceKind.chat.systemImageName,
                title: chat.title,
                placeholder: "Untitled Chat",
                titleLineLimit: 1,
                isExpanded: $isHeaderExpanded,
                onTitleCommit: { newTitle in
                    store.renameChat(id: chat.id, to: newTitle)
                }
            ) {
                Text(chat.updatedAt, style: .date)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: PageEditorMetrics.readableContentWidth, alignment: .leading)

            if isHeaderExpanded {
                chatActionBar
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, PageEditorMetrics.contentInset)
        .padding(.top, PageEditorMetrics.contentInset)
        .padding(.bottom, ChatMetrics.sectionSpacing)
    }

    // MARK: - Header action bar (full-width toolbar row)

    /// The chat detail action toolbar row. Rendered as a sibling of
    /// `CollapsibleDetailHeader` — NOT inside its expanded content — so this
    /// HStack spans the FULL view width. The trailing `Spacer(minLength: 0)`
    /// therefore pushes the outline toggle all the way to the view's right
    /// edge (Bug 1 fix), instead of only the readable-column edge.
    @ViewBuilder
    private var chatActionBar: some View {
        HStack(spacing: 10) {
            if let chatID {
                Button("Show in List", systemImage: "sidebar.left") {
                    DebugLog.tabs("ChatView: Show in List tapped — id=\(chatID.rawValue)")
                    store.requestSidebarReveal(.chat(chatID))
                }
                .help("Reveal this chat in the sidebar")
            }
            if fileProvider.path != nil, let chatID {
                Button("Share", systemImage: "square.and.arrow.up") {
                    DebugLog.fileprovider("ChatView: Share tapped — id=\(chatID.rawValue)")
                    Task {
                        guard let url = await fileProvider.resolveChatByNameURL(id: chatID, wikiID: session.wikiID) else {
                            DebugLog.fileprovider("Share chat detail: resolveChatByNameURL returned nil — id=\(chatID.rawValue) wikiID=\(session.wikiID)")
                            return
                        }
                        DebugLog.fileprovider("Share chat detail: \(url.lastPathComponent)")
                        let picker = NSSharingServicePicker(items: [url])
                        let mouseScreen = NSEvent.mouseLocation
                        guard let window = NSApplication.shared.keyWindow,
                              let contentView = window.contentView else { return }
                        let windowPoint = window.convertPoint(fromScreen: mouseScreen)
                        let viewPoint = contentView.convert(windowPoint, from: nil)
                        picker.show(
                            relativeTo: NSRect(origin: viewPoint,
                                               size: NSSize(width: 1, height: 1)),
                            of: contentView, preferredEdge: .minY)
                    }
                }
                .help("Share this chat")
                Button("Reveal in Finder", systemImage: "folder") {
                    DebugLog.fileprovider("ChatView: Reveal in Finder tapped — id=\(chatID.rawValue)")
                    Task { await fileProvider.revealChatInFinder(id: chatID, wikiID: session.wikiID) }
                }
                .help("Reveal this chat file in Finder")
            }
            revealDebugFolderButton
            // Pin action buttons at the leading edge and the outline
            // toggle at the trailing edge (Spacer reaches the view's right
            // edge because this row is outside the readableContentWidth
            // frame — Bug 1 fix).
            Spacer(minLength: 0)
            Button {
                DebugLog.tabs("ChatView: Toggle Outline tapped")
                chatOutlineExpanded.toggle()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .help("Toggle Outline")
        }
    }

    // MARK: - Reveal Debug Folder button (#671)

    /// The "Reveal Debug Folder" button. ALWAYS rendered when there is a
    /// `chatID` — previously the button was gated on
    /// `launcher.debugFolderURL(forChat:) ?? launcher.debugFolderURL`,
    /// which read from an in-memory map populated only at spawn commit. A
    /// persisted chat reopened from history (that ran in a previous app
    /// session) had no entry, so the button never appeared — the operator
    /// couldn't tell the feature existed (Bug 2, #671).
    ///
    /// #681 made `debugFolderURL(forChat:)` a pure function of chatID: it
    /// resolves `<Caches>/Self Driving Wiki-agent/<chatULID>/runs/<latest>/debug/`
    /// from disk at read time. So a chat that ran in ANY prior session now
    /// resolves correctly after restart — the only disabled case is a chat
    /// that has never spawn-committed (no `<chatULID>/runs/` directory on
    /// disk: a draft chat, or one whose preflight failed before scratch-dir
    /// creation).
    ///
    /// When the launcher resolves a debug URL for this chat (from the
    /// disk-derived pure function, with a fallback to the live session's
    /// `debugFolderURL` while a spawn is in progress), the button is enabled
    /// and reveals the folder. When there is no URL, the button is DISABLED
    /// with a help tooltip explaining the limitation — so the feature is
    /// always discoverable.
    @ViewBuilder
    private var revealDebugFolderButton: some View {
        if let chatID {
            revealDebugFolderButton(
                chatID: chatID,
                debugURL: launcher.debugFolderURL(forChat: chatID.rawValue)
                    ?? (isLiveChat ? launcher.debugFolderURL : nil))
        }
    }

    @ViewBuilder
    private func revealDebugFolderButton(chatID: PageID, debugURL: URL?) -> some View {
        Button("Reveal Debug Folder", systemImage: "folder.badge.gearshape") {
            DebugLog.agent("ChatView: Reveal Debug Folder tapped — id=\(chatID.rawValue)")
            if let debugURL {
                NSWorkspace.shared.activateFileViewerSelecting([debugURL])
            } else {
                // No debug URL for this chat — no `<chatULID>/runs/`
                // directory exists on disk. The chat was either created but
                // never spawn-committed (draft / preflight failure), or the
                // spawn's createDirectory hasn't completed yet (extremely
                // brief; the disabled state should already prevent this).
                // Log so the click is visible in Console.app (belt-and-
                // suspenders).
                DebugLog.agent("ChatView: no debug folder available for chat — id=\(chatID.rawValue) (no runs on disk)")
            }
        }
        .disabled(debugURL == nil)
        .help(Self.debugFolderButtonHelpText(debugURL: debugURL))
    }

    /// Pure predicate returning the help tooltip text for the Reveal Debug
    /// Folder button. Extracted as a static func so the visibility/help-text
    /// contract is unit-testable without a SwiftUI view tree (following the
    /// `composerCaptionText` / `canSendPredicate` / `preflightBannerMessage`
    /// pattern). Returns the disabled-state explanation when `debugURL` is
    /// nil, or the enabled-state description when a folder is available.
    nonisolated static func debugFolderButtonHelpText(debugURL: URL?) -> String {
        if debugURL != nil {
            return "Open the complete debug trace folder (ACP messages, permissions, usage)"
        }
        return "No debug folder on disk for this chat"
    }

    // MARK: - Preflight-error banner (issue #613)

    /// Pure predicate for whether the chat surface should render a preflight-error
    /// banner. Returns true when `launcher.preflightError` is non-empty AND the
    /// surface is NOT the active live session — i.e. the chat reverted to the
    /// draft composer after `AgentOperationRunner.startChat` rolled back a dead
    /// chat row. A live chat never shows a preflight banner because a live
    /// session implies the spawn succeeded (`preflightError` would be nil).
    ///
    /// Mirrors the existing pattern in `AgentQueueView.preflightBanner` (the
    /// ingest activity window) but applies it to the chat surface so a failed
    /// Ask/Edit spawn doesn't silently revert to an empty composer. The banner
    /// surface is purely additive — the rollback (deleting the dead chat row)
    /// still happens in `AgentOperationRunner.startChat:114`; this only
    /// explains WHY the draft is visible.
    nonisolated static func shouldShowPreflightBanner(
        preflightError: String?,
        chatID: PageID?,
        isLiveChat: Bool
    ) -> Bool {
        guard let message = preflightError, !message.isEmpty else { return false }
        return chatID == nil || !isLiveChat
    }

    /// The preflight error message to surface in the banner, or nil when the
    /// banner should not render. Forwards `preflightError` verbatim — the textual
    /// content the user sees is the message captured at the spawn choke-point
    /// (`AgentLauncher.startInteractiveQuery` / `backend.start` catch). Kept
    /// static so tests can verify the text-pass-through without a SwiftUI view
    /// tree (following the `composerCaptionText` / `canSendPredicate` pattern).
    nonisolated static func preflightBannerMessage(
        preflightError: String?,
        chatID: PageID?,
        isLiveChat: Bool
    ) -> String? {
        guard shouldShowPreflightBanner(
            preflightError: preflightError,
            chatID: chatID,
            isLiveChat: isLiveChat) else { return nil }
        return preflightError
    }

    /// The instance-level read of the banner message used by `chatSurface`.
    private var preflightBannerMessage: String? {
        Self.preflightBannerMessage(
            preflightError: launcher.preflightError,
            chatID: chatID,
            isLiveChat: isLiveChat)
    }

    /// Pre-spawn failure banner for the chat surface. Mirrors the amber
    /// turn-failed banner visual from `ChatWebView.turnFailedBannerHTML`
    /// (`rgba(255, 159, 10, 0.12)` background, 3pt amber left border, amber
    /// warning icon, amber bold label + primary body) so this reads as a
    /// sibling of the chat's existing turn-failure banner rather than the
    /// red `AgentQueueView.preflightBanner` (the ingest activity window's
    /// separate visual language).
    @ViewBuilder
    private func preflightBanner(_ error: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't start the chat")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.orange)
                .frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: - Composer caption predicates

    /// Pure predicate for the composer caption. Returns the visible caption text
    /// shown under the composer, or nil when nothing is queued/busy. Kept static
    /// so tests can verify the full state matrix without a view tree.
    static func composerCaptionText(
        isAwaitingGenerationSlot: Bool,
        hasChatID: Bool,
        isLiveChat: Bool,
        isGenerating: Bool
    ) -> String? {
        if isAwaitingGenerationSlot {
            return "Waiting for the other session to finish before sending…"
        }
        if isGenerating {
            // Live chat: agent is responding. Persisted chat: a different chat
            // is generating and the launcher is busy.
            return isLiveChat
                ? "Agent is responding…"
                : "Another chat is responding — wait or stop it."
        }
        return nil
    }

    // MARK: - Composer

    /// The composer's AppKit font, scaled by the persisted chat zoom so
    /// ⌘+/⌘− resize the input alongside the transcript (parity with the page
    /// editor's `editor.zoom`).
    private var composerFont: NSFont {
        let base = ChatMetrics.composerFont
        return base.withSize(base.pointSize * CGFloat(chatZoom))
    }

    /// Wiki-link autocomplete hooks (#436 / #638). Returns `nil` when no
    /// Tantivy service is attached (no wiki open) — the composer then behaves
    /// exactly as before. The `fetch` closure runs the distance-2 fuzzy query
    /// on the live Tantivy index; `format` builds the canonical
    /// `[[kind:ULID|Title]]` form via `DroppedLinkFormatter`. The coordinator
    /// wraps `fetch` in a debounced + cancellable Task (AC #5).
    private var chatAutocompleteHooks: ComposerTextView.AutocompleteHooks? {
        guard let search = store.tantivySearch else { return nil }
        return ComposerTextView.AutocompleteHooks(
            fetch: { partial, kind in
                let tantivyKind = Self.tantivyKind(for: kind)
                return await search.autocomplete(
                    partial: partial,
                    kinds: [tantivyKind],
                    distance: 2,
                    limit: 8)
            },
            format: { hit in
                // Map the search hit back to a ParsedLink.LinkType for the
                // formatter (single source of truth for the `[[kind:ULID|…]]`
                // prefix string).
                let linkType = Self.linkType(for: hit.kind)
                return DroppedLinkFormatter.link(
                    for: linkType,
                    id: hit.ulid,
                    displayName: hit.title)
            }
        )
    }

    /// Pure: map `ParsedLink.LinkType` (the prefix vocabulary) →
    /// `TantivyDocumentKind` (the search index vocabulary). Single source of
    /// truth so a prefix-rename hits both sides. `nonisolated` for test reach.
    nonisolated static func tantivyKind(for kind: ParsedLink.LinkType) -> TantivyDocumentKind {
        switch kind {
        case .page:   return .page
        case .source: return .source
        case .chat:   return .chat
        }
    }

    /// Pure inverse of ``tantivyKind(for:)``. Same single-source-of-truth goal.
    nonisolated static func linkType(for kind: TantivyDocumentKind) -> ParsedLink.LinkType {
        switch kind {
        case .page:   return .page
        case .source: return .source
        case .chat:   return .chat
        }
    }

    private func composer(enabled: Bool) -> some View {
        let sendActive = canSend && enabled
        // Paseo-style: ONE rounded box wrapping the text (top) and a toolbar row
        // (bottom) — model chip · permission chip · send button. Replaces the old
        // capsule-with-inline-send + separate selector bar below.
        return VStack(alignment: .leading, spacing: ChatMetrics.composerRowSpacing) {
            if !attachments.isEmpty {
                attachmentChips
            }
            ComposerTextView(
                text: $store.draftChatMessage,
                isEditable: enabled,
                font: composerFont,
                onSubmit: sendMessage,
                measuredHeight: $composerHeight,
                autoFocus: chatID == nil,
                autocomplete: chatAutocompleteHooks
            )
                .frame(height: composerHeight)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topLeading) {
                    if store.draftChatMessage.isEmpty {
                        Text("Ask a question, or ask to update the wiki…")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                            // Zero leading padding: `lineFragmentPadding=0` +
                            // `textContainerInset.width=0` mean typed text starts
                            // at the text view's left edge, so the overlay must too.
                            .padding(.vertical, ComposerTextView.Metrics.verticalInsetPerSide)
                    }
                }

            composerToolbar(sendActive: sendActive)
        }
        .padding(.horizontal, ChatMetrics.composerHorizontalPadding)
        .padding(.top, ChatMetrics.composerTopPadding)
        .padding(.bottom, ChatMetrics.composerBottomPadding)
        .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: ChatMetrics.composerCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ChatMetrics.composerCornerRadius, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.9), lineWidth: 1.5)
        }
        .shadow(color: Color.black.opacity(0.10), radius: 20, x: 0, y: 8)
        .frame(maxWidth: .infinity)
        // Accept sidebar drags anywhere in the composer box. This is the
        // innermost drop target for SidebarDragPayloadList — it intercepts the
        // drag before WikiDetailView's broader drop destination (which opens a
        // new tab) can handle it. Must be on the composer container (not just
        // attachmentChips) so it exists even when there are no attachments yet
        // (issue #385 regression).
        .dropDestination(for: SidebarDragPayloadList.self) { lists, _ in
            let payloads = lists.flatMap(\.items)
            for payload in payloads {
                let attachment = ChatAttachment(payload: payload, store: store)
                if !attachments.contains(attachment) {
                    attachments.append(attachment)
                }
            }
            return !payloads.isEmpty
        }
    }

    /// True while the agent is actively generating or queued for the generation
    /// slot — the stop button replaces the send button in the composer toolbar.
    private var showsStopButton: Bool {
        (launcher.isGenerating || launcher.isAwaitingGenerationSlot)
            && launcher.runningKind == .query
    }

    /// The stop button shown in the composer toolbar while the agent is
    /// responding. Sits in the same position as the send button (trailing edge
    /// of the composer's bottom toolbar row).
    private var stopButton: some View {
        Button(action: { launcher.stopAgent() }) {
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: ChatMetrics.sendButtonSize, height: ChatMetrics.sendButtonSize)
                .background(Color.red.opacity(0.85), in: Circle())
        }
        .buttonStyle(.borderless)
        .help("Stop the current response")
    }

    /// The trailing send button in the composer's bottom toolbar — a green
    /// circle with a white up-arrow (paseo). Only shown when the composer has
    /// text (see `composerToolbar`).
    private func sendButton(active: Bool) -> some View {
        Button(action: sendMessage) {
            Image(systemName: "arrow.up")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: ChatMetrics.sendButtonSize, height: ChatMetrics.sendButtonSize)
                .background(sendButtonBackground(active: active), in: Circle())
        }
        .buttonStyle(.borderless)
        .disabled(!active)
        .keyboardShortcut(.return, modifiers: .command)
        .help(sendButtonTitle)
    }

    // MARK: - Attachments

    /// Attachment chips shown above the composer. Each chip shows the item's
    /// name + a remove button. Drop sidebar items here to attach them as
    /// context for the next message (issue #385).
    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 4) {
                        Image(systemName: attachment.systemImage)
                            .font(.caption2)
                        Text(attachment.displayName)
                            .font(.caption)
                            .lineLimit(1)
                        Button {
                            attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.1), in: Capsule())
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - Send logic

    /// True once the composer holds non-whitespace text — drives the send
    /// button's visibility (paseo shows no glyph until you type).
    private var hasDraftText: Bool {
        !store.draftChatMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Green when the message can be sent, a muted grey while it can't (e.g. a
    /// response is still generating). The button is only visible with text, so
    /// green is the usual state.
    private func sendButtonBackground(active: Bool) -> Color {
        active ? Color.green : Color(nsColor: .quaternaryLabelColor).opacity(0.4)
    }

    private func sendMessage() {
        // Guard: don't clear the draft or attempt to send when the agent is
        // generating or waiting for a slot. The Send button is already gated
        // by `canSend`, but the Return key in ComposerTextView calls this
        // unconditionally — so the same guard here prevents the message from
        // being silently dropped (issue #380). The draft is preserved so the
        // user can send it once the agent finishes.
        guard canSend else { return }
        let message = store.draftChatMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        store.clearActiveChatDraft()
        // Build the wire message: prepend attachment references so the agent
        // has context about the dragged-in pages/sources (issue #385).
        let wireMessage: String
        if !attachments.isEmpty {
            let refs = attachments.map { $0.referenceText }.joined(separator: "\n")
            wireMessage = "\(refs)\n\n\(message)"
            attachments = []
        } else {
            wireMessage = message
        }
        if launcher.isInteractiveSession {
            // Live chat mid-session: append a turn to the existing session.
            launcher.sendInteractiveMessage(wireMessage)
        } else if let chatID {
            // D3: a persisted (non-live) chat — start a fresh session that
            // continues this chat (seeded-fallback), streaming into the
            // SAME chat row. activeChatID = chat.id flips this view to live.
            Task {
                await AgentOperationRunner.continueChat(
                    chatID: chatID,
                    message: wireMessage,
                    store: store,
                    launcher: launcher,
                    wikiID: session.wikiID,
                    changeSignaler: fileProvider,
                    wikictlDirectory: HelpersLocation.wikictlDirectory
                )
            }
        } else {
            // Draft state (.newChat): start a NEW chat.
            Task {
                await AgentOperationRunner.startChat(
                    firstMessage: wireMessage,
                    launcher: launcher,
                    store: store,
                    wikiID: session.wikiID,
                    changeSignaler: fileProvider,
                    wikictlDirectory: HelpersLocation.wikictlDirectory
                )
            }
        }
    }

    /// Start a new chat: clear the launcher's live state and retarget
    /// the tab back to the draft state (.newChat). The old chat stays
    /// in history.
    private func startNewChat() {
        launcher.startNewChat()
        // D2 retarget-back: morph the active tab from .chat(id) back to the draft
        // state so the user sees a fresh composer.
        if let activeID = store.activeTabID {
            store.retargetTab(id: activeID, to: .newChat)
        }
    }

    // MARK: - Derived state

    /// Composer is enabled for the live chat AND for a persisted (non-live) chat
    /// whose kind's launcher is idle (D3: continue a persisted chat). A
    /// persisted chat whose launcher is mid-generation (a DIFFERENT chat
    /// is responding) disables the composer — the takeover rules refuse a
    /// mid-generation interrupt, so the composer reflects that.
    private var isComposerEnabled: Bool {
        // Draft state (.newChat with chatID == nil): always enabled (a wiki
        // is open inside ContentView; nothing is generating).
        guard chatID != nil else {
            return launcher.isInteractiveSession || !launcher.isRunning
        }
        // The active live chat: enabled when a turn isn't in flight.
        if isLiveChat {
            return launcher.isInteractiveSession || !launcher.isRunning
        }
        // D3: a persisted (non-live) chat is continuable when its kind's launcher
        // is idle (`!isGenerating && !isAwaitingGenerationSlot`). If that launcher
        // is mid-generation (a different chat), the composer stays
        // disabled — `continueChat`'s takeover guard would refuse anyway.
        // (A session is only alive when a wiki is open, so the activeWikiID
        // check the old code had is always true here.)
        return !launcher.isGenerating
            && !launcher.isAwaitingGenerationSlot
    }

    /// Visible caption shown under the composer when the session is waiting or
    /// busy. Covers both the generation-gate queue (any session) and the
    /// persisted-chat "another chat is responding" case. Empty (no caption)
    /// when the composer is enabled and nothing is queued (issue #235).
    private var composerCaption: String? {
        Self.composerCaptionText(
            isAwaitingGenerationSlot: launcher.isAwaitingGenerationSlot,
            hasChatID: chatID != nil,
            isLiveChat: isLiveChat,
            isGenerating: launcher.isGenerating)
    }

    private var canType: Bool {
        // A session is always alive when ChatView is rendered inside
        // ContentView, so the old `activeWikiID != nil` check is
        // always true here.
        launcher.isInteractiveSession || !launcher.isRunning
    }

    private var canSend: Bool {
        Self.canSendPredicate(
            hasMount: fileProvider.path != nil,
            canType: canType,
            isGenerating: launcher.isGenerating,
            isAwaitingSlot: launcher.isAwaitingGenerationSlot,
            hasDraftText: !store.draftChatMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    /// Pure predicate for whether the composer can send a message. Extracted as a
    /// static func so it is unit-testable without a SwiftUI view tree (following
    /// the `composerCaptionText` pattern). The `hasMount` parameter is accepted
    /// for API clarity but intentionally ignored — the mount guard was removed
    /// (issue #441): the agent reads via `wikictl` (DB-direct), not the mount.
    nonisolated static func canSendPredicate(
        hasMount: Bool,
        canType: Bool,
        isGenerating: Bool,
        isAwaitingSlot: Bool,
        hasDraftText: Bool
    ) -> Bool {
        canType
            && !isGenerating
            && !isAwaitingSlot
            && hasDraftText
    }

    private var sendButtonTitle: String {
        if launcher.isAwaitingGenerationSlot {
            return "Waiting for the other session to finish before sending…"
        }
        if launcher.isGenerating {
            return "Wait for the response before sending the next message"
        }
        return launcher.isInteractiveSession ? "Send" : "Start Query"
    }
}

/// A sidebar item dragged onto the chat composer as context for the next
/// message (issue #385). Resolves the display name and builds a reference
/// string prepended to the wire message so the agent knows about the
/// attached page/source/chat.
private struct ChatAttachment: Identifiable, Hashable {
    let kind: SidebarDragPayload.Kind
    let itemID: String
    let displayName: String

    var hashableID: String { "\(kind.rawValue):\(itemID)" }

    @MainActor
    init(payload: SidebarDragPayload, store: WikiStoreModel) {
        self.kind = payload.kind
        self.itemID = payload.id
        self.displayName = store.resolveAttachmentName(for: payload) ?? payload.id
    }

    var id: String { hashableID }

    func hash(into hasher: inout Hasher) { hasher.combine(hashableID) }

    static func == (lhs: ChatAttachment, rhs: ChatAttachment) -> Bool {
        lhs.hashableID == rhs.hashableID
    }

    var systemImage: String {
        switch kind {
        case .page: return "doc.text"
        case .source: return "doc"
        case .chat: return "bubble.left.and.bubble.right"
        }
    }

    /// The reference text prepended to the wire message so the agent knows
    /// which wiki resource to use as context. Uses the display name (not the
    /// raw ULID) so the agent can understand the reference — the system prompt
    /// instructs the agent to use `[[source:DisplayName]]` / `[[page:Title]]` /
    /// `[[chat:Title]]` wikilinks with human-readable names.
    var referenceText: String {
        switch kind {
        case .page:   return "[[page:\(displayName)]]"
        case .source: return "[[source:\(displayName)]]"
        case .chat:   return "[[chat:\(displayName)]]"
        }
    }
}

/// `Hashable` key for the `ChatView` quote-anchor consume task (issue #281).
/// Re-fires the task when the chat changes, a new anchor is pending, or the
/// transcript's message count changes (so the anchor is consumed only once the
/// persisted messages have loaded).
private struct ChatAnchorTaskKey: Hashable {
    let chatID: PageID?
    let anchorVersion: Int
    let messageCount: Int
}

// Shared metrics for the chat surface (mirrors the original
// QueryChatMetrics, now shared between draft and persisted states).
enum ChatMetrics {
    static let contentInset: CGFloat = 28
    static let sectionSpacing: CGFloat = 16
    static let debugTopInset: CGFloat = 18
    static let controlsBandHeight: CGFloat = 28
    static let chatTopInset: CGFloat = 56
    /// Extra horizontal breathing room added to the transcript + composer on
    /// top of `PageEditorMetrics.contentInset`, so the chat content (numbered
    /// lists especially) sits well clear of the window edges.
    static let extraHorizontalMargin: CGFloat = 18
    /// Horizontal inset of the composer box's contents (paseo-style). Also the
    /// effective left margin for the text, since `ComposerTextView` uses zero
    /// line-fragment padding.
    static let composerHorizontalPadding: CGFloat = 18
    /// Top inset above the text inside the composer box.
    static let composerTopPadding: CGFloat = 14
    /// Bottom inset below the toolbar row inside the composer box.
    static let composerBottomPadding: CGFloat = 12
    /// Vertical gap between the text and the toolbar row inside the box.
    static let composerRowSpacing: CGFloat = 10
    /// Corner radius of the unified composer box (paseo uses a soft rounded
    /// rectangle, not a full pill).
    static let composerCornerRadius: CGFloat = 18
    static let sendButtonSize: CGFloat = 34
    /// Font for `ComposerTextView` — matches the previous `TextField`'s
    /// `.font(.body)`, expressed as an `NSFont` since the composer is
    /// AppKit-backed.
    static var composerFont: NSFont { .preferredFont(forTextStyle: .body) }
}

/// One entry in the chat outline: a user question paired with a one-line
/// summary of the model's response (if any). The `question` is the
/// humanized user text; `response` is the first-sentence extract of the
/// first `.assistantText` or `.result` that followed, elided to 60 chars.
struct ChatOutlineEntry: Hashable {
    let question: String
    let response: String?
    let questionTimestamp: Date?
    let responseTimestamp: Date?
}

/// Right-side outline for a chat: lists the user's turns (questions) in
/// order, each paired with a one-line summary of the model's response.
/// Clicking a turn scrolls the transcript web view to that message via a
/// versioned `ChatScrollRequest`. Mirrors the page outline's shape (divider +
/// "Outline" header + scrollable list).
struct ChatOutlineView: View {
    let entries: [ChatOutlineEntry]
    let onSelect: (Int) -> Void

    @AppStorage("chatOutlineWidth") private var outlineWidth: Double = 240
    @State private var dragStartWidth: Double? = nil

    var body: some View {
        HStack(spacing: 0) {
            // Draggable divider on the outline's leading edge. A 1pt separator
            // line with a wider invisible hit area so it's easy to grab.
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                .frame(maxHeight: .infinity)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
                .onHover { isHovering in
                    if isHovering {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if dragStartWidth == nil {
                                dragStartWidth = outlineWidth
                            }
                            if let start = dragStartWidth {
                                let newWidth = start - Double(value.translation.width)
                                outlineWidth = max(60, min(600, newWidth))
                            }
                        }
                        .onEnded { _ in
                            dragStartWidth = nil
                        }
                )
                .zIndex(1)

            VStack(alignment: .leading, spacing: 0) {
                Text("Outline")
                    .font(.headline)
                    .padding()

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                            Button {
                                onSelect(index)
                            } label: {
                                VStack(alignment: .leading, spacing: 0) {
                                    // Timestamp header for the turn
                                    if let ts = entry.questionTimestamp {
                                        Text(ts, format: .dateTime.hour().minute())
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .padding(.bottom, 2)
                                    }
                                    // User question line item
                                    HStack(alignment: .top, spacing: 4) {
                                        Text("•")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(entry.question.isEmpty ? "(empty)" : entry.question)
                                            .font(.callout)
                                            .foregroundStyle(.primary)
                                            .multilineTextAlignment(.leading)
                                    }
                                    // Agent response line item
                                    if let response = entry.response {
                                        HStack(alignment: .top, spacing: 4) {
                                            Text("•")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Text(response)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(3)
                                                .multilineTextAlignment(.leading)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .frame(width: outlineWidth)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

/// Humanize the leading `[[page:…]]` / `[[source:…]]` / `[[chat:…]]`
/// wikilink lines that `sendMessage` prepends as attachment references, so
/// the chat outline shows readable names instead of raw `[[…]]` syntax.
/// In the transcript WebView, user text is run through the markdown renderer
/// so wikilinks render as clickable links there; this helper is only used by
/// the plain-text outline (issue #385).
func humanizeAttachmentRefs(in text: String) -> String {
    let pattern = #"\[\[(page|source|chat):([^\]]+)\]\]"#
    let result = text.replacingOccurrences(of: pattern,
                                            with: "$2",
                                            options: .regularExpression)
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}
