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

    /// Landscape aspect ratio shared by provider video iframes (YouTube/Vimeo).
    /// The native container is sized to this ratio so the iframe can fill it
    /// exactly; `MediaEmbedPlayerHTML`'s video CSS fills the container in turn.
    private static let videoAspect: CGFloat = 16.0 / 9.0

    /// Height for native `<audio>` elements (direct-remote audio).
    private static let nativeAudioHeight: CGFloat = 220

    var body: some View {
        switch target.kind {
        case .iframe where MediaEmbedPlayerHTML.sizeClass(for: target.url) == .video:
            // Provider video iframes fill the pane with the largest box at the
            // video aspect ratio, so resizing the window grows the player
            // instead of centering a fixed-height band with empty gaps above
            // and below it.
            EmbedWebViewRep(target: target)
                .aspectRatio(Self.videoAspect, contentMode: .fit)
                .background(.regularMaterial)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .iframe:
            // Audio/podcast player iframes (Spotify, SoundCloud, Apple
            // Podcasts) fill the pane too: their widgets use the extra height
            // for artwork, descriptions, and episode lists instead of a
            // centered compact band with empty gaps around it.
            EmbedWebViewRep(target: target)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
        case .video:
            // Native <video> elements (direct-remote media) fill the pane; the
            // element letterboxes the content to the video's own ratio
            // (object-fit: contain), so any aspect ratio — not just 16:9 —
            // renders as large as the window allows.
            EmbedWebViewRep(target: target)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
        case .audio:
            // A native <audio> element is a bare controls bar — it stays
            // compact instead of stretching empty space to the window height.
            EmbedWebViewRep(target: target)
                .frame(maxWidth: .infinity)
                .frame(height: Self.nativeAudioHeight)
                .background(.regularMaterial)
        }
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
          iframe.wiki-embed-video { height: 100%; }
          iframe.wiki-embed-audio { height: 100%; }
          video.wiki-embed { height: 100%; object-fit: contain; }
          .wiki-embed-fallback { padding: 16px; font: -apple-system-body; color: -apple-system-secondary-label; }
        </style></head>
        <body>\(body)</body></html>
        """
    }

    /// The HTML element for the embed target. This function is pure.
    static func element(for target: EmbedTarget) -> String {
        let sizeClass = sizeClass(for: target.url).rawValue
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
        }
    }

    /// Player shape for an embed URL: video iframes are sized by the native
    /// view to the video aspect ratio (16:9); audio-player iframes fill the
    /// pane at full height. Selects the iframe's CSS class and the native
    /// sizing branch.
    enum SizeClass: String {
        case video = "wiki-embed-video"
        case audio = "wiki-embed-audio"
    }

    static func sizeClass(for url: String) -> SizeClass {
        if url.contains("open.spotify.com")
            || url.contains("w.soundcloud.com")
            || url.contains("embed.podcasts.apple.com") {
            return .audio
        }
        return .video
    }
}
