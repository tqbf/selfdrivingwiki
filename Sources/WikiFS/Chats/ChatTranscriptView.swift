// pattern: Imperative Shell

import SwiftUI
import WikiFSCore

/// The reusable, typed chat transcript renderer. Both chat and Activity paths
/// carry `ChatDisplayRow` values into `ChatWebView`. Tool-call display is a
/// property of the transcript the caller projects, not a view-level filter:
/// the chat pane receives the human-facing projection (Summary default), and
/// Activity feeds receive the canonical detailed transcript.
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
    /// Reader-parity link-menu actions, as host-supplied closures. `.none`
    /// (the default) keeps the transcript's menu to the URL-only tab actions.
    var linkMenuCapabilities: WikiLinkMenuCapabilities = .none

    var body: some View {
        let visibleRows = rendering.rows
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
                    quoteAnchor: quoteAnchor,
                    linkMenuCapabilities: linkMenuCapabilities
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

/// A typed UI intent emitted by the transcript. The transcript view layer
/// holds NO AUTHORITY: it may carry references and closures its host supplies
/// — a blob store for scheme serving, link-menu capabilities for the context
/// menu — but it never calls a store method, reads store state to decide
/// anything, or mutates store state. Every such call happens inside a closure
/// the host built, where the host's authority already lives, and navigation
/// itself flows through these intents. A capability the host does not supply
/// is `nil`, and the corresponding UI is omitted — never shown inert.
enum ChatTranscriptIntent {
    case openWikiLink(URL, inNewTab: Bool)
    /// Open a `wiki://` link in a background tab (issue #1315, from the
    /// transcript's native link context menu). The consumer resolves the URL
    /// where the store lives — `WikiLinkMenuNSItems.selection(for:store:)`
    /// prefers the canonical `?id=` and falls back to the display name for
    /// legacy `?title=`-only links.
    case openWikiLinkInBackground(URL)
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

    func webScrollRequest(for request: ChatScrollRequest?) -> ChatWebScrollRequest? {
        guard let request,
              case .turn(_, let promptRowID) = request.target,
              let prompt = rows.first(where: { $0.id == promptRowID })
        else { return nil }
        return ChatWebScrollRequest(version: request.version, rowID: prompt.id)
    }
}
