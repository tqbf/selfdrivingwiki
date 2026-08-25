import SwiftUI
import WebKit
import WikiFSCore

/// A self-contained WKWebView that renders one provider player iframe for a
/// byteless media source (YouTube/Vimeo/Spotify/SoundCloud). Used by
/// `SourceDetailView` to show the player above the transcript. A source detail
/// page has no authored embed syntax, so the document resolver cannot create
/// this player.
///
/// Mirrors the reader's origin discipline (`WikiReaderOrigin`): the document is
/// loaded under the same synthetic https origin that the YouTube embed URL's
/// `?origin=` param claims, so YouTube's parent-origin check does not 153-error
/// (issue #206). The iframe attributes match the typed reader media lowerer.
///
/// Issue #572.
struct MediaEmbedPlayerView: View {
    let target: EmbedTarget

    var body: some View {
        EmbedWebViewRep(target: target)
            .frame(maxWidth: .infinity)
            .frame(height: target.kind == .iframe ? playerHeight : 220)
            .background(.regularMaterial)
    }

    /// Use the embed URL host to select a video or audio-player height.
    private var playerHeight: CGFloat {
        let url = target.url
        if url.contains("open.spotify.com")
            || url.contains("w.soundcloud.com")
            || url.contains("embed.podcasts.apple.com") {
            return 152
        }
        // A 16:9 aspect at a 760pt readable width is ~427pt; clamp so it stays
        // comfortable at narrow widths and never crowds the transcript.
        return 360
    }
}

/// The `NSViewRepresentable` wrapping a plain `WKWebView`. Kept minimal — no
/// navigation delegate, no blob scheme, no link handling; the iframe is the
/// whole document. `underPageBackgroundColor = .clear` (macOS) so the rounded
/// container's material shows through the letterboxing.
private struct EmbedWebViewRep: NSViewRepresentable {
    let target: EmbedTarget

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        let webView = WKWebView(frame: .zero, configuration: config)
        // macOS idiom (mirrors `ChatWebView`): clear the page background so the
        // rounded material container shows through the letterboxing.
        webView.underPageBackgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        loadHTML(into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Reload only when the embed target URL changed (e.g. a different source
        // reuses this view). Coordinator holds the last-loaded URL.
        guard context.coordinator.loadedURL != target.url else { return }
        loadHTML(into: webView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func loadHTML(into webView: WKWebView) {
        let html = MediaEmbedPlayerHTML.document(for: target)
        webView.loadHTMLString(html, baseURL: WikiReaderOrigin.url)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedURL: String?
    }
}

/// Pure HTML builder for the single-player document. YouTube uses eager loading
/// and a referrer policy. Other providers use lazy loading.
enum MediaEmbedPlayerHTML {

    /// The full HTML document for one embed target. Loads under
    /// `WikiReaderOrigin.url` (passed by the caller) so YouTube's `?origin=`
    /// check passes.
    static func document(for target: EmbedTarget) -> String {
        let body = element(for: target)
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <style>
          html, body { margin: 0; padding: 0; height: 100%; background: transparent; }
          .wiki-embed { width: 100%; border: none; border-radius: 8px; display: block; }
          iframe.wiki-embed-video { aspect-ratio: 16/9; height: auto; }
          iframe.wiki-embed-audio { height: 152px; }
          .wiki-embed-fallback { padding: 16px; font: -apple-system-body; color: -apple-system-secondary-label; }
        </style></head>
        <body>\(body)</body></html>
        """
    }

    /// The HTML element for the embed target. This function is pure.
    static func element(for target: EmbedTarget) -> String {
        let sizeClass = sizeClass(for: target.url)
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
             .replacingOccurrences(of: "\"", with: "&quot;")
             .replacingOccurrences(of: "<", with: "&lt;")
        }
        switch target.kind {
        case .iframe:
            let isYouTube = target.url.contains("youtube-nocookie.com")
                || target.url.contains("youtube.com")
            if isYouTube {
                return "<iframe src=\"\(esc(target.url))\" class=\"wiki-embed \(sizeClass)\" allow=\"encrypted-media; picture-in-picture; fullscreen\" referrerpolicy=\"strict-origin-when-cross-origin\" allowfullscreen></iframe>"
            }
            return "<iframe src=\"\(esc(target.url))\" class=\"wiki-embed \(sizeClass)\" allow=\"encrypted-media; picture-in-picture; fullscreen\" loading=\"lazy\"></iframe>"
        case .audio:
            return "<audio src=\"\(esc(target.url))\" controls class=\"wiki-embed\"></audio>"
        case .video:
            return "<video src=\"\(esc(target.url))\" controls class=\"wiki-embed\"></video>"
        case .diagram:
            // The typed reader lowers diagrams. The source detail media view
            // does not show a player for Mermaid sources.
            return ""
        }
    }

    /// Video iframes use a 16:9 ratio. Audio-player iframes use a fixed height.
    static func sizeClass(for url: String) -> String {
        if url.contains("open.spotify.com")
            || url.contains("w.soundcloud.com")
            || url.contains("embed.podcasts.apple.com") {
            return "wiki-embed-audio"
        }
        return "wiki-embed-video"
    }
}
