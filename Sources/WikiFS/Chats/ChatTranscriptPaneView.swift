// pattern: Imperative Shell

import SwiftUI
import WikiFSCore
import WikiFSEngine

struct ChatTranscriptPaneView: View {
    let presentation: ChatTranscriptPanePresentation
    let renderer: ChatTranscriptRendererEnvironment
    let onIntent: (ChatTranscriptIntent) -> Void

    var body: some View {
        let rendererInput = ChatTranscriptRenderingInput(transcript: presentation.transcript.displayTranscript)
        VStack(spacing: 0) {
            if let preflightBannerMessage = presentation.preflightBannerMessage {
                preflightBanner(preflightBannerMessage)
                    .padding(.horizontal, PageEditorMetrics.contentInset + ChatMetrics.extraHorizontalMargin)
                    .padding(.top, presentation.chatID != nil ? ChatMetrics.sectionSpacing / 2 : ChatMetrics.chatTopInset)
                    .padding(.bottom, ChatMetrics.sectionSpacing / 2)
            }
            ChatTranscriptView(
                rendering: rendererInput,
                transcriptID: presentation.chatID.map(TranscriptID.chat),
                emptyStateMessage: presentation.transcript.emptyStateMessage,
                isStreaming: presentation.transcript.isAnswering,
                onIntent: onIntent,
                renderContext: renderer.renderContext,
                blobStore: renderer.blobStore,
                zoom: presentation.chatZoom,
                scrollRequest: rendererInput.webScrollRequest(for: presentation.outlineScroll),
                quoteAnchor: presentation.quoteAnchor,
                hideToolCalls: presentation.hideToolCalls
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, PageEditorMetrics.contentInset + ChatMetrics.extraHorizontalMargin)
            .padding(.top, presentation.preflightBannerMessage == nil
                ? (presentation.chatID != nil ? 0 : ChatMetrics.chatTopInset)
                : 0)
            if presentation.showsThinkingIndicator {
                thinkingIndicator
                    .padding(.horizontal, PageEditorMetrics.contentInset + ChatMetrics.extraHorizontalMargin)
                    .padding(.bottom, ChatMetrics.sectionSpacing / 2)
            }
            if let livePendingPermission = presentation.livePendingPermission {
                PermissionApprovalView(permission: livePendingPermission) { intent in
                    onIntent(.resolvePermission(intent))
                }
                .padding(.horizontal, PageEditorMetrics.contentInset + ChatMetrics.extraHorizontalMargin)
                .padding(.bottom, ChatMetrics.sectionSpacing / 2)
            }
        }
    }

    private var thinkingIndicator: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                if let runStartedAt = presentation.runStartedAt {
                    Text("Thinking… \(durationString(context.date.timeIntervalSince(runStartedAt)))")
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
}

/// Immutable values for the native transcript pane. The composition root builds
/// this once from display state, so the pane cannot query daemon or store state
/// while SwiftUI evaluates its body.
struct ChatTranscriptPanePresentation {
    let chatID: ChatID?
    let transcript: ChatDetailPresentation.Transcript
    let preflightBannerMessage: String?
    let livePendingPermission: PendingPermission?
    let showsThinkingIndicator: Bool
    let runStartedAt: Date?
    let chatZoom: Double
    let outlineScroll: ChatScrollRequest?
    let quoteAnchor: ChatHighlightRequest?
    let hideToolCalls: Bool
}

/// Renderer dependencies prepared by `ChatDetailView`. This shell contains no
/// persistence or daemon operations; it merely carries the already-authorized
/// values required by the single WebKit surface.
struct ChatTranscriptRendererEnvironment {
    let renderContext: () -> WikiRenderContext?
    let blobStore: WikiStoreModel?
}
