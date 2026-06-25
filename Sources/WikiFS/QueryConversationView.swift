import AppKit
import SwiftUI
import WikiFSCore

/// Dedicated query workspace for the active wiki. It keeps a Claude session open
/// so the user can ask follow-ups and choose when an answer should become wiki
/// content, instead of every query being a one-shot background operation.
struct QueryConversationView: View {
    @Bindable var launcher: AgentLauncher
    @Bindable var store: WikiStoreModel
    @Bindable var manager: WikiManager
    let fileProvider: FileProviderSpike
    @State private var draftMessage = ""
    @State private var showsInternals = false
    @State private var allowWikiEdits = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                content
                if showsDebugControls {
                    controls
                        .padding(.top, QueryConversationMetrics.debugTopInset)
                        .padding(.trailing, QueryConversationMetrics.contentInset)
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
    }

    private var controls: some View {
        // Only shown during an active query run (gated by `showsDebugControls`).
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
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
        }
    }

    private var showsDebugControls: Bool {
        AgentLauncher.showsQueryDebugControls(
            isGenerating: launcher.isGenerating, runningKind: launcher.runningKind)
    }

    @ViewBuilder
    private var content: some View {
        // The internals view only shows during an active query run; when idle the
        // view always returns to the conversation/empty state (AC.1).
        if showsInternals && launcher.isRunning && launcher.runningKind == .query {
            AgentActivityView(launcher: launcher, showsResultEvents: false, showsInternals: true, onWikiLink: WikiReaderView.onWikiLinkHandler(for: store))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(QueryConversationMetrics.contentInset)
        } else if hasVisibleConversation {
            conversation
        } else {
            emptyState
        }
    }

    /// Shown when the query agent has "Allow wiki edits" enabled and is actively
    /// running — the agent CAN write to the wiki, and ingestion is blocked.
    private var editingEnabledBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil.and.list.clipboard")
                .font(.system(size: 13, weight: .semibold))
            Text("Editing enabled — ingestion is paused while this session is active.")
                .font(.subheadline)
                .fontWeight(.medium)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: QueryConversationMetrics.chatColumnWidth)
        .background(.orange.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.orange.opacity(0.3), lineWidth: 1)
        }
    }

    private var showsEditingEnabledBanner: Bool {
        allowWikiEdits && launcher.isInteractiveSession && launcher.isRunning
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            if showsEditingEnabledBanner {
                editingEnabledBanner
                    .padding(.bottom, QueryConversationMetrics.sectionSpacing)
            }
            QueryTranscriptView(launcher: launcher, onWikiLink: WikiReaderView.onWikiLinkHandler(for: store))
                .frame(maxWidth: QueryConversationMetrics.chatColumnWidth, maxHeight: .infinity)
                .padding(.top, showsEditingEnabledBanner ? 0 : QueryConversationMetrics.conversationTopInset)
            composer(maxWidth: QueryConversationMetrics.chatColumnWidth)
                .padding(.horizontal, QueryConversationMetrics.conversationHorizontalInset)
                .padding(.top, QueryConversationMetrics.sectionSpacing)
                .padding(.bottom, QueryConversationMetrics.contentInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var emptyState: some View {
        VStack(spacing: QueryConversationMetrics.emptyStateSpacing) {
            if showsEditingEnabledBanner {
                editingEnabledBanner
            }
            Spacer(minLength: 0)
            Text("Ask \(activeWikiName)")
                .font(.largeTitle)
                .fontWeight(.regular)
                .multilineTextAlignment(.center)
            composer(maxWidth: QueryConversationMetrics.chatColumnWidth)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, QueryConversationMetrics.emptyStateHorizontalInset)
        .padding(.bottom, QueryConversationMetrics.emptyStateBottomBias)
    }

    private func composer(maxWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $allowWikiEdits) {
                Text("Allow wiki edits")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .disabled(launcher.isInteractiveSession)
            .help(launcher.isInteractiveSession
                  ? "Edit permissions are set when the session starts."
                  : "When on, the agent can update the wiki and ingestion is paused until this session ends.")
            .padding(.horizontal, QueryConversationMetrics.composerHorizontalPadding)

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask a question, or ask the Agent to update the wiki…", text: $draftMessage, axis: .vertical)
                    .font(.body)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(.leading, QueryConversationMetrics.composerHorizontalPadding)
                    .padding(.vertical, QueryConversationMetrics.composerVerticalPadding)
                    .onSubmit(sendMessage)
                    .disabled(!canType)

                if launcher.isRunning {
                    Button(action: { launcher.stopAgent() }) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.red)
                            .frame(width: QueryConversationMetrics.sendButtonSize, height: QueryConversationMetrics.sendButtonSize)
                    }
                    .buttonStyle(.borderless)
                    .help("End this query session")
                }

                Button(action: sendMessage) {
                    Image(systemName: sendButtonIcon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(canSend ? Color.white : Color.secondary)
                        .frame(width: QueryConversationMetrics.sendButtonSize, height: QueryConversationMetrics.sendButtonSize)
                        .background(sendButtonBackground, in: Circle())
                }
                    .buttonStyle(.borderless)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(sendButtonTitle)
            }
            .padding(.trailing, QueryConversationMetrics.composerButtonInset)
            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.06), radius: 18, x: 0, y: 8)
        }
        .frame(maxWidth: maxWidth)
    }

    private var sendButtonBackground: Color {
        canSend ? .accentColor : Color(nsColor: .quaternaryLabelColor).opacity(0.25)
    }

    private var hasVisibleConversation: Bool {
        launcher.events.contains { event in
            switch event {
            case .userText:
                return true
            case .assistantText(let text), .result(_, let text):
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .systemInit, .toolUse, .toolResult, .subagent, .raw:
                return false
            }
        }
    }

    private var activeWikiName: String {
        guard let id = manager.activeWikiID,
              let descriptor = manager.wikis.first(where: { $0.id == id })
        else { return "this wiki" }
        return descriptor.displayName
    }

    private var canType: Bool {
        manager.activeWikiID != nil && (launcher.isInteractiveSession || !launcher.isRunning)
    }

    private var canSend: Bool {
        fileProvider.path != nil
            && canType
            && !draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sendButtonTitle: String {
        launcher.isInteractiveSession ? "Send" : "Start Query"
    }

    private var sendButtonIcon: String {
        launcher.isInteractiveSession ? "arrow.up.circle.fill" : "play.circle.fill"
    }

    private func sendMessage() {
        let message = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        draftMessage = ""
        if launcher.isInteractiveSession {
            launcher.sendInteractiveMessage(message)
        } else {
            Task {
                await AgentOperationRunner.startQueryConversation(
                    firstMessage: message,
                    launcher: launcher,
                    store: store,
                    manager: manager,
                    fileProvider: fileProvider,
                    allowWikiEdits: allowWikiEdits
                )
            }
        }
    }
}

private enum QueryConversationMetrics {
    static let contentInset: CGFloat = 28
    static let sectionSpacing: CGFloat = 16
    static let debugTopInset: CGFloat = 18
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
