// pattern: Imperative Shell

import SwiftUI
import WikiFSCore

/// The reusable, typed chat transcript renderer. Both chat and Activity paths
/// carry `ChatDisplayRow` values into `ChatWebView`.
struct ChatTranscriptView: View {
    let rendering: ChatTranscriptRenderingInput
    var transcriptID: TranscriptID? = nil
    var emptyStateMessage: String
    var isStreaming: Bool = false
    var onIntent: (ChatTranscriptIntent) -> Void
    var renderContext: (() -> WikiRenderContext?)? = nil
    var blobStore: WikiStoreModel? = nil
    var zoom: Double = Double(ZoomScale.defaultScale)
    var scrollRequest: ChatWebScrollRequest? = nil
    var quoteAnchor: ChatHighlightRequest? = nil
    var hideToolCalls: Bool = false

    var body: some View {
        let visibleRows = rendering.visibleRows(hidingToolCalls: hideToolCalls)
        Group {
            if visibleRows.isEmpty {
                placeholder
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ChatWebView(
                    chatRows: visibleRows,
                    transcriptID: transcriptID,
                    onChatIntent: onIntent,
                    renderContext: renderContext,
                    blobStore: blobStore,
                    zoom: zoom,
                    scrollRequest: scrollRequest,
                    quoteAnchor: quoteAnchor
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: ChatTranscriptMetrics.placeholderSpacing) {
            Text(isStreaming ? "Waiting for the Agent…" : emptyStateMessage)
                .font(.headline.weight(.medium))
                .foregroundStyle(.primary)
            if isStreaming {
                Text("Answers appear here as separate blocks. Tool activity stays attached to the turn that produced it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(ChatTranscriptMetrics.emptyStatePadding)
    }
}

private enum ChatTranscriptMetrics {
    static let emptyStatePadding: CGFloat = 24
    static let placeholderSpacing: CGFloat = 7
}

/// A typed UI intent emitted by the transcript. `ChatDetailView` owns the
/// authority required to resolve it; neither this view nor its pane reaches
/// into the store or daemon on its own.
enum ChatTranscriptIntent {
    case openWikiLink(URL, inNewTab: Bool)
    case resolvePermission(ChatPermissionResolutionIntent)
}

/// Narrow renderer bridge over the typed Phase 3 display projection. It keeps
/// the renderer boundary explicit without converting the app transcript back
/// into event arrays or parallel timestamp arrays.
struct ChatTranscriptRenderingInput: Hashable, Sendable {
    let rows: [ChatDisplayRow]

    init(transcript: ChatDisplayTranscript) {
        rows = transcript.rows
    }

    func visibleRows(hidingToolCalls: Bool) -> [ChatDisplayRow] {
        hidingToolCalls ? rows.filter { row in
            if case .toolCall = row { return false }
            return true
        } : rows
    }

    func webScrollRequest(for request: ChatScrollRequest?) -> ChatWebScrollRequest? {
        guard let request,
              case .turn(_, let promptRowID) = request.target,
              let prompt = rows.first(where: { $0.id == promptRowID })
        else { return nil }
        return ChatWebScrollRequest(version: request.version, rowID: prompt.id)
    }
}
