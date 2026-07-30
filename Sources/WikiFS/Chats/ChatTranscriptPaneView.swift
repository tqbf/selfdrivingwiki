// pattern: Imperative Shell

import SwiftUI
import WikiFSCore
import WikiFSEngine

struct ChatTranscriptPaneView: View {
    let chatID: ChatID?
    let transcript: ChatDetailPresentation.Transcript
    let preflightBannerMessage: String?
    let livePendingPermission: PendingPermission?
    let showsThinkingIndicator: Bool
    let runStartedAt: Date?
    let store: WikiStoreModel
    let chatZoom: Double
    let outlineScroll: ChatScrollRequest?
    let quoteAnchor: ChatHighlightRequest?
    let hideToolCalls: Bool
    let onResolvePermission: (String, Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let preflightBannerMessage {
                preflightBanner(preflightBannerMessage)
                    .padding(.horizontal, PageEditorMetrics.contentInset + ChatMetrics.extraHorizontalMargin)
                    .padding(.top, chatID != nil ? ChatMetrics.sectionSpacing / 2 : ChatMetrics.chatTopInset)
                    .padding(.bottom, ChatMetrics.sectionSpacing / 2)
            }
            ChatTranscriptView(
                events: transcript.events,
                transcriptID: chatID.map(TranscriptID.chat),
                timestamps: transcript.timestamps,
                emptyStateMessage: transcript.emptyStateMessage,
                isRunning: transcript.isRunning,
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
                ? (chatID != nil ? 0 : ChatMetrics.chatTopInset)
                : 0)
            if showsThinkingIndicator {
                thinkingIndicator
                    .padding(.horizontal, PageEditorMetrics.contentInset + ChatMetrics.extraHorizontalMargin)
                    .padding(.bottom, ChatMetrics.sectionSpacing / 2)
            }
            if let livePendingPermission {
                PermissionApprovalView(permission: livePendingPermission) { optionId in
                    let approve = livePendingPermission.options
                        .first { $0.optionId == optionId }?
                        .kind.hasPrefix("allow") ?? false
                    onResolvePermission(optionId, approve)
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
                if let runStartedAt {
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
