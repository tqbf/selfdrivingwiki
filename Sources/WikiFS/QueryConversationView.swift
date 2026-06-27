import AppKit
import SwiftUI
import WikiFSCore

/// Whether the session can write to the wiki. Ask = read-only; Edit = can write.
/// This is a property of the mounted session, not a runtime toggle.
enum QueryMode {
    case ask, edit

    var allowsEdits: Bool { self == .edit }
}

/// Dedicated query workspace for the active wiki. It keeps a Claude session open
/// so the user can ask follow-ups and choose when an answer should become wiki
/// content, instead of every query being a one-shot background operation.
struct QueryConversationView: View {
    let mode: QueryMode
    @Bindable var launcher: AgentLauncher
    @Bindable var store: WikiStoreModel
    @Bindable var manager: WikiManager
    let fileProvider: FileProviderSpike
    @State private var draftMessage = ""
    @State private var showsInternals = false

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
            // Invariant: interactive session's isRunning only goes false when the
            // process truly exits — this observer never fires on spurious transients.
            if !isRunning { showsInternals = false }
        }
        // NOTE: the per-turn edit lock is NO LONGER driven from this view. It is
        // owned by `AgentLauncher` (via the `onTurnBoundary` callback the runner
        // installs in `startQueryConversation`), so it releases between turns even
        // when this view is unmounted — the old `.onChange(of: isGenerating)` here
        // never fired while the view was off-screen, stranding the lock. The view
        // only READS `isGenerating` now (banner, debug cluster, send gating).
    }

    private var controls: some View {
        // Only shown during an active query run or while awaiting the gate
        // (gated by `showsDebugControls`). The spinner shows only while generating;
        // the stop button shows in both states.
        HStack(spacing: 8) {
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
            // Wired to stopAgent() which cancels any pending send and terminates the process.
            Button(action: { launcher.stopAgent() }) {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.borderless)
            .help("Stop the current response")
        }
    }

    private var showsDebugControls: Bool {
        // Show controls while generating (spinner + menu + stop) OR while awaiting
        // the generation slot (stop only — the session is live but waiting its turn).
        (launcher.isGenerating || launcher.isAwaitingGenerationSlot)
            && launcher.runningKind == .query
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

    /// Shown in Edit mode while the agent is actively generating — the agent CAN
    /// write to the wiki, and ingestion is paused.
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
        .frame(maxWidth: QueryConversationMetrics.chatColumnWidth)
        .background(.orange.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.orange.opacity(0.3), lineWidth: 1)
        }
    }

    /// Pure predicate: true only when an Edit-mode session is actively generating.
    /// Kept static so tests can verify the full (mode × isGenerating) matrix without
    /// constructing a view. `mode.allowsEdits` is the sole input from the mode — there
    /// is no parallel boolean; the mode drives the banner.
    static func showsEditingBanner(allowsEdits: Bool, isGenerating: Bool) -> Bool {
        allowsEdits && isGenerating
    }

    private var showsEditingEnabledBanner: Bool {
        Self.showsEditingBanner(allowsEdits: mode.allowsEdits, isGenerating: launcher.isGenerating)
    }

    /// Top space the banner reserves so it clears the floating controls cluster,
    /// which is overlaid in the same top-trailing band. Zero when no controls show.
    private var bannerTopReservation: CGFloat {
        showsDebugControls
            ? QueryConversationMetrics.debugTopInset + QueryConversationMetrics.controlsBandHeight
            : 0
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            if showsEditingEnabledBanner {
                editingEnabledBanner
                    .padding(.top, bannerTopReservation)
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
                    .padding(.top, bannerTopReservation)
            }
            Spacer(minLength: 0)
            Text(mode == .edit ? "Edit \(activeWikiName)" : "Ask \(activeWikiName)")
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
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask a question, or ask the Agent to update the wiki…", text: $draftMessage, axis: .vertical)
                .font(.body)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(.leading, QueryConversationMetrics.composerHorizontalPadding)
                .padding(.vertical, QueryConversationMetrics.composerVerticalPadding)
                .onSubmit(sendMessage)
                .disabled(!canType)

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
            case .systemInit, .toolUse, .toolResult, .subagent, .messageStop, .raw:
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
                    allowWikiEdits: mode.allowsEdits
                )
            }
        }
    }
}

private enum QueryConversationMetrics {
    static let contentInset: CGFloat = 28
    static let sectionSpacing: CGFloat = 16
    static let debugTopInset: CGFloat = 18
    /// Vertical room the floating controls cluster (spinner/menu/stop) occupies at
    /// the top-trailing corner. The editing banner reserves this much top space when
    /// the controls are visible so the two never overlap in the top band.
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
