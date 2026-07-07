import AppKit
import SwiftUI
import WikiFSCore

/// The unified conversation surface (D2, pillar 2). One view replaces the split
/// between the live `QueryConversationView` and the read-only
/// `ChatHistoryDetailView`. Whether you see streaming deltas or a persisted
/// transcript depends on the **source-of-truth rule**: if this chat is the
/// launcher's active live session (`activeChatID == chatID`), render
/// `launcher.events` (in-memory, streaming). Otherwise render the persisted
/// `store.chatMessages(chatID:)`.
///
/// The `.ask` / `.edit` draft states also route here (with `chatID == nil`),
/// showing the empty-composer state until the first send retargets the tab to
/// `.chat(id)` (the draft-state morph, handled by `AgentOperationRunner`).
struct ConversationView: View {
    /// `.ask` / `.edit` for draft states; `.chat(id)`'s kind is resolved from
    /// the chat summary. Determines which launcher owns this surface.
    let mode: QueryMode
    /// The persisted chat id, or `nil` for the draft state (.ask/.edit). When
    /// non-nil AND equal to `launcher.activeChatID`, the view renders live.
    let chatID: PageID?

    @Bindable var store: WikiStoreModel
    @Bindable var launcher: AgentLauncher
    @Bindable var manager: WikiManager
    let fileProvider: FileProviderSpike

    @State private var draftMessage = ""
    @State private var showsInternals = false
    @State private var persistedMessages: [ChatMessage] = []

    /// True when this surface is rendering the active live session (D2
    /// source-of-truth rule). The view sources from `launcher.events`; when
    /// false, it sources from the persisted `store.chatMessages(chatID:)`.
    private var isLiveChat: Bool {
        guard let chatID else { return false }
        return launcher.activeChatID == chatID.rawValue
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                content
                if showsDebugControls || showsNewConversation {
                    controls
                        .padding(.top, ConversationMetrics.debugTopInset)
                        .padding(.trailing, ConversationMetrics.contentInset)
                }
            }
            .frame(minWidth: PageEditorMetrics.detailMinWidth)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .onChange(of: launcher.isRunning) { _, isRunning in
            // Belt-and-suspenders: clear the internals toggle when a run ends so a
            // later ingest/lint run doesn't inherit it and strand the view on
            // `AgentActivityView`. (AC.1)
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
    }

    // MARK: - Controls (debug cluster + new conversation)

    private var controls: some View {
        // Only the live chat gets the debug cluster + new conversation button.
        // A persisted non-live chat is read-only — no controls.
        HStack(spacing: 8) {
            if showsNewConversation {
                Button(action: { startNewConversation() }) {
                    Image(systemName: "trash")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.borderless)
                .help("New conversation — clears this chat. It stays available in history.")
            }
            if showsDebugControls {
                if launcher.isGenerating {
                    ProgressView()
                        .controlSize(.small)
                }
                Menu {
                    Toggle("Show internals", isOn: $showsInternals)
                    if let status = launcher.exitStatus {
                        Label(status == 0 ? "Ended" : "Exited \(status)", systemImage: status == 0 ? "checkmark.circle" : "xmark.circle")
                    }
                    if let logURL = launcher.logFileURL {
                        Button("Reveal Log", systemImage: "doc.text.magnifyingglass") {
                            NSWorkspace.shared.activateFileViewerSelecting([logURL])
                        }
                    }
                } label: {
                    Label("Activity", systemImage: "ellipsis.circle")
                }
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .help("Show activity and transcript internals")
                // Stop button: visible while generating OR awaiting the generation slot.
                Button(action: { launcher.stopAgent() }) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.borderless)
                .help("Stop the current response")
            }
        }
    }

    private var showsDebugControls: Bool {
        (launcher.isGenerating || launcher.isAwaitingGenerationSlot)
            && launcher.runningKind == .query
    }

    private var showsNewConversation: Bool {
        QueryConversationView.showsNewConversationButton(
            isRunning: launcher.isRunning,
            isInteractiveSession: launcher.isInteractiveSession,
            runningKind: launcher.runningKind,
            hasVisibleConversation: hasVisibleConversation)
    }

    // MARK: - Content routing

    @ViewBuilder
    private var content: some View {
        if showsInternals && launcher.isRunning && launcher.runningKind == .query {
            AgentActivityView(launcher: launcher, showsResultEvents: false, showsInternals: true, onWikiLink: WikiReaderView.onWikiLinkHandler(for: store))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(ConversationMetrics.contentInset)
        } else if isLiveChat || chatID == nil {
            // Live session or draft state: same path as QueryConversationView.
            if hasVisibleConversation {
                liveConversation
            } else {
                emptyState
            }
        } else {
            // Persisted non-live chat: read-only header + transcript.
            persistedConversation
        }
    }

    // MARK: - Live conversation (streaming)

    @ViewBuilder
    private var liveConversation: some View {
        VStack(spacing: 0) {
            if showsEditingEnabledBanner {
                editingEnabledBanner
                    .padding(.top, bannerTopReservation)
                    .padding(.bottom, ConversationMetrics.sectionSpacing)
            }
            QueryTranscriptView(
                launcher: launcher,
                onWikiLink: WikiReaderView.onWikiLinkHandler(for: store),
                renderContext: { [weak store] in store?.renderContext() },
                blobStore: store
            )
                .frame(maxWidth: ConversationMetrics.chatColumnWidth, maxHeight: .infinity)
                .padding(.top, showsEditingEnabledBanner ? 0 : ConversationMetrics.conversationTopInset)
            liveComposer
                .padding(.horizontal, ConversationMetrics.conversationHorizontalInset)
                .padding(.top, ConversationMetrics.sectionSpacing)
                .padding(.bottom, ConversationMetrics.contentInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var emptyState: some View {
        VStack(spacing: ConversationMetrics.emptyStateSpacing) {
            if showsEditingEnabledBanner {
                editingEnabledBanner
                    .padding(.top, bannerTopReservation)
            }
            Spacer(minLength: 0)
            Text(mode == .edit ? "Edit \(activeWikiName)" : "Ask \(activeWikiName)")
                .font(.largeTitle)
                .fontWeight(.regular)
                .multilineTextAlignment(.center)
            liveComposer
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ConversationMetrics.emptyStateHorizontalInset)
        .padding(.bottom, ConversationMetrics.emptyStateBottomBias)
    }

    private var liveComposer: some View {
        composer(enabled: isComposerEnabled)
    }

    // MARK: - Persisted conversation (read-only)

    @ViewBuilder
    private var persistedConversation: some View {
        if let chat = chatSummary {
            VStack(alignment: .leading, spacing: 0) {
                header(for: chat)
                Divider().opacity(PageEditorMetrics.dividerOpacity)
                persistedTranscript
            }
        } else {
            ContentUnavailableView {
                Label("Conversation Missing", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("This conversation is no longer available.")
            }
        }
    }

    private var chatSummary: ChatSummary? {
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
        .padding(.bottom, ConversationMetrics.sectionSpacing)
    }

    @ViewBuilder
    private var persistedTranscript: some View {
        let visible = persistedMessages.map(\.event).transcriptVisible
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
                onWikiLink: WikiReaderView.onWikiLinkHandler(for: store),
                renderContext: { [weak store] in store?.renderContext() },
                blobStore: store
            )
            .frame(maxWidth: ConversationMetrics.chatColumnWidth, maxHeight: .infinity)
            .frame(maxWidth: .infinity, alignment: .center)
            // D3: the persisted chat's composer continues the conversation
            // (seeded-fallback). Enabled when the kind's launcher is idle; disabled
            // with a slot-style caption when a different conversation is responding.
            .safeAreaInset(edge: .bottom) {
                persistedComposerFooter
            }
        }
    }

    private var persistedComposerFooter: some View {
        VStack(spacing: 4) {
            composer(enabled: isComposerEnabled)
            if let caption = persistedComposerCaption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, ConversationMetrics.conversationHorizontalInset)
        .padding(.bottom, ConversationMetrics.contentInset)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Editing banner

    @ViewBuilder
    private var editingEnabledBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil.and.list.clipboard")
                .font(.system(size: 13, weight: .semibold))
            Text("Editing enabled — ingestion is paused while the agent is responding.")
                .font(.subheadline)
                .fontWeight(.medium)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: ConversationMetrics.chatColumnWidth)
        .background(.orange.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.orange.opacity(0.3), lineWidth: 1)
        }
    }

    private var showsEditingEnabledBanner: Bool {
        QueryConversationView.showsEditingBanner(allowsEdits: mode.allowsEdits, isGenerating: launcher.isGenerating)
    }

    private var bannerTopReservation: CGFloat {
        showsDebugControls
            ? ConversationMetrics.debugTopInset + ConversationMetrics.controlsBandHeight
            : 0
    }

    // MARK: - Composer

    private func composer(enabled: Bool) -> some View {
        let sendActive = canSend && enabled
        return HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask a question, or ask the Agent to update the wiki…", text: $draftMessage, axis: .vertical)
                .font(.body)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(.leading, ConversationMetrics.composerHorizontalPadding)
                .padding(.vertical, ConversationMetrics.composerVerticalPadding)
                .onSubmit(sendMessage)
                .disabled(!enabled)

            Button(action: sendMessage) {
                Image(systemName: sendButtonIcon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(sendActive ? Color.white : Color.secondary)
                    .frame(width: ConversationMetrics.sendButtonSize, height: ConversationMetrics.sendButtonSize)
                    .background(sendButtonBackground(active: sendActive), in: Circle())
            }
                .buttonStyle(.borderless)
                .disabled(!sendActive)
                .keyboardShortcut(.return, modifiers: .command)
                .help(sendButtonTitle)
        }
        .padding(.trailing, ConversationMetrics.composerButtonInset)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.06), radius: 18, x: 0, y: 8)
        .frame(maxWidth: ConversationMetrics.chatColumnWidth)
    }

    // MARK: - Send logic

    private func sendButtonBackground(active: Bool) -> Color {
        active ? .accentColor : Color(nsColor: .quaternaryLabelColor).opacity(0.25)
    }

    private func sendMessage() {
        let message = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        draftMessage = ""
        if launcher.isInteractiveSession {
            // Live chat mid-session: append a turn to the existing session.
            launcher.sendInteractiveMessage(message)
        } else if let chatID {
            // D3: a persisted (non-live) chat — start a fresh session that
            // continues this conversation (seeded-fallback), streaming into the
            // SAME chat row. activeChatID = chat.id flips this view to live.
            Task {
                await AgentOperationRunner.continueConversation(
                    chatID: chatID,
                    message: message,
                    mode: mode,
                    store: store,
                    launcher: launcher,
                    manager: manager,
                    fileProvider: fileProvider,
                    allowWikiEdits: mode.allowsEdits
                )
            }
        } else {
            // Draft state (.ask/.edit): start a NEW conversation.
            Task {
                await AgentOperationRunner.startQueryConversation(
                    firstMessage: message,
                    launcher: launcher,
                    store: store,
                    manager: manager,
                    fileProvider: fileProvider,
                    allowWikiEdits: mode.allowsEdits
                )
            }
        }
    }

    /// Start a new conversation: clear the launcher's live state and retarget
    /// the tab back to the draft state (.ask/.edit per mode). The old chat stays
    /// in history.
    private func startNewConversation() {
        launcher.startNewConversation()
        // D2 retarget-back: morph the active tab from .chat(id) back to the draft
        // state so the user sees a fresh composer.
        if let activeID = store.activeTabID {
            store.retargetTab(id: activeID, to: mode == .edit ? .edit : .ask)
        }
    }

    // MARK: - Derived state

    private var hasVisibleConversation: Bool {
        if isLiveChat {
            return launcher.events.contains { event in
                switch event {
                case .userText:
                    return true
                case .assistantText(let text), .result(_, let text):
                    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                case .systemInit, .toolUse, .toolResult, .subagent, .messageStop, .raw, .assistantTextDelta:
                    return false
                }
            }
        }
        // Persisted chat or draft: check if there are any visible persisted rows.
        return persistedMessages.map(\.event).transcriptVisible.contains { event in
            switch event {
            case .userText: return true
            case .assistantText(let text), .result(_, let text):
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default: return false
            }
        }
    }

    private var activeWikiName: String {
        guard let id = manager.activeWikiID,
              let descriptor = manager.wikis.first(where: { $0.id == id })
        else { return "this wiki" }
        return descriptor.displayName
    }

    /// Composer is enabled for the live chat AND for a persisted (non-live) chat
    /// whose kind's launcher is idle (D3: continue a persisted conversation). A
    /// persisted chat whose launcher is mid-generation (a DIFFERENT conversation
    /// is responding) disables the composer — the takeover rules refuse a
    /// mid-generation interrupt, so the composer reflects that.
    private var isComposerEnabled: Bool {
        // Draft state (.ask/.edit with chatID == nil): always enabled (when a
        // wiki is open and nothing is generating).
        guard chatID != nil else {
            return manager.activeWikiID != nil && (launcher.isInteractiveSession || !launcher.isRunning)
        }
        // The active live chat: enabled when a turn isn't in flight.
        if isLiveChat {
            return launcher.isInteractiveSession || !launcher.isRunning
        }
        // D3: a persisted (non-live) chat is continuable when its kind's launcher
        // is idle (`!isGenerating && !isAwaitingGenerationSlot`). If that launcher
        // is mid-generation (a different conversation), the composer stays
        // disabled — `continueConversation`'s takeover guard would refuse anyway.
        return manager.activeWikiID != nil
            && !launcher.isGenerating
            && !launcher.isAwaitingGenerationSlot
    }

    /// The caption shown under a persisted chat's composer when it is disabled
    /// because the kind's launcher is responding to a DIFFERENT conversation.
    /// Mirrors the slot-style hint used elsewhere. Empty (no caption) when the
    /// composer is enabled.
    private var persistedComposerCaption: String? {
        guard chatID != nil, !isLiveChat else { return nil }
        if launcher.isGenerating || launcher.isAwaitingGenerationSlot {
            let label = mode == .edit ? "Edit" : "Ask"
            return "Another \(label) conversation is responding — wait or stop it."
        }
        return nil
    }

    private var canType: Bool {
        manager.activeWikiID != nil && (launcher.isInteractiveSession || !launcher.isRunning)
    }

    private var canSend: Bool {
        fileProvider.path != nil
            && canType
            && !launcher.isGenerating
            && !launcher.isAwaitingGenerationSlot
            && !draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    private var sendButtonIcon: String {
        launcher.isInteractiveSession ? "arrow.up.circle.fill" : "play.circle.fill"
    }
}

// Shared metrics for the conversation surface (mirrors the original
// QueryConversationMetrics, now shared between draft and persisted states).
enum ConversationMetrics {
    static let contentInset: CGFloat = 28
    static let sectionSpacing: CGFloat = 16
    static let debugTopInset: CGFloat = 18
    static let controlsBandHeight: CGFloat = 28
    static let conversationHorizontalInset: CGFloat = 48
    static let conversationTopInset: CGFloat = 56
    static let chatColumnWidth: CGFloat = 900
    static let emptyStateHorizontalInset: CGFloat = 72
    static let emptyStateSpacing: CGFloat = 28
    static let emptyStateBottomBias: CGFloat = 96
    static let composerHorizontalPadding: CGFloat = 22
    static let composerVerticalPadding: CGFloat = 16
    static let composerButtonInset: CGFloat = 8
    static let sendButtonSize: CGFloat = 42
}
