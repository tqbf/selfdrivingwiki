import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFS

/// Pure unit tests for the issue #572 additions: the YouTube start-time parser
/// (resume-at-timestamp), the oEmbed display-title fetcher, and the standalone
/// embed-player HTML builder. No store, no network, no WKWebView — the live
/// player paint is covered by `YouTubeEmbedWebViewTests`.
struct MediaEmbedPlayerTests {

    // MARK: - YouTube start time (ExternalEmbed.youTubeStartTime)

    @Test(arguments: [
        ("https://www.youtube.com/watch?v=-mwLAjsdgVM&t=569s", 569),
        ("https://youtu.be/-mwLAjsdgVM?t=120", 120),
        ("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1m30s", 90),
        ("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1h2m30s", 3750),
        ("https://www.youtube.com/watch?v=dQw4w9WgXcQ&start=42", 42),
        ("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=100", 100),
    ])
    func youTubeStartTimeParses(url: String, expected: Int) throws {
        let start = try #require(ExternalEmbed.youTubeStartTime(from: url))
        #expect(start == expected)
    }

    @Test(arguments: [
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://youtu.be/dQw4w9WgXcQ",
        nil,
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=",
    ])
    func youTubeStartTimeNilWhenAbsent(url: String?) {
        #expect(ExternalEmbed.youTubeStartTime(from: url) == nil)
    }

    @Test func youTubeStartTimeRejectsGarbage() {
        #expect(ExternalEmbed.youTubeStartTime(
            from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=abc") == nil)
        #expect(ExternalEmbed.youTubeStartTime(
            from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1x2y") == nil)
    }

    @Test func youTubeStartStampedIntoEmbedURL() throws {
        let d = SourceEmbedDescriptor(
            id: PageID(rawValue: "01HEMBEDTEST0000000000002"),
            mimeType: "video/youtube",
            externalIdentity: "-mwLAjsdgVM",
            agentName: "youtube",
            planURL: "https://www.youtube.com/watch?v=-mwLAjsdgVM&t=569s")
        let t = try #require(ExternalEmbed.target(for: d))
        #expect(t.kind == .iframe)
        #expect(t.url.contains("&start=569"))
        #expect(t.url.contains("youtube-nocookie.com/embed/-mwLAjsdgVM"))
    }

    @Test func youTubeStartOmittedWhenNoTimestamp() {
        let d = SourceEmbedDescriptor(
            id: PageID(rawValue: "01HEMBEDTEST0000000000003"),
            mimeType: "video/youtube",
            externalIdentity: "dQw4w9WgXcQ",
            agentName: "youtube",
            planURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        let t = ExternalEmbed.target(for: d)
        #expect(t?.url.contains("&start=") == false)
    }

    // MARK: - MediaTitleFetcher (oEmbed URL building + title parse)

    @Test func oembedURLForYouTube() throws {
        let m = MediaEmbedURL.youtube("https://www.youtube.com/watch?v=-mwLAjsdgVM&t=569s")!
        let url = try #require(MediaTitleFetcher.oembedURL(for: m))
        // The pasted URL's own ?& must not split the oEmbed request query.
        #expect(url.absoluteString.hasPrefix("https://www.youtube.com/oembed?url="))
        #expect(url.absoluteString.contains("format=json"))
        #expect(url.absoluteString.contains("watch%3Fv%3D-mwLAjsdgVM"))
    }

    @Test func oembedURLForVimeo() throws {
        let m = MediaEmbedURL.vimeo("https://vimeo.com/76979871")!
        let url = try #require(MediaTitleFetcher.oembedURL(for: m))
        #expect(url.absoluteString.contains("vimeo.com/api/oembed.json?url="))
    }

    @Test func oembedURLNilForRemoteMedia() {
        let m = MediaEmbedURL.remoteMedia("https://example.com/audio.mp3")!
        #expect(MediaTitleFetcher.oembedURL(for: m) == nil)
    }

    @Test func parseTitleFromJSON() throws {
        let json = #"{"title":"My Cool Video","author_name":"Channel"}"#
        let title = try #require(MediaTitleFetcher.parseTitle(from: Data(json.utf8)))
        #expect(title == "My Cool Video")
    }

    @Test func parseTitleTrimsWhitespace() throws {
        let json = #"{"title":"  Padded Title  "}"#
        let title = try #require(MediaTitleFetcher.parseTitle(from: Data(json.utf8)))
        #expect(title == "Padded Title")
    }

    @Test func parseTitleNilForEmptyOrMissing() {
        #expect(MediaTitleFetcher.parseTitle(from: Data(#"{"title":""}"#.utf8)) == nil)
        #expect(MediaTitleFetcher.parseTitle(from: Data(#"{"author_name":"x"}"#.utf8)) == nil)
        #expect(MediaTitleFetcher.parseTitle(from: Data("not json".utf8)) == nil)
    }

    // MARK: - MediaEmbedPlayerHTML (iframe element + document)

    @Test func youTubeIframeEagerLoadsAndForwardsReferrer() throws {
        let target = EmbedTarget(
            kind: .iframe,
            url: "https://www.youtube-nocookie.com/embed/abc?enablejsapi=1")
        let el = MediaEmbedPlayerHTML.element(for: target)
        #expect(el.contains("allowfullscreen"))
        #expect(el.contains("referrerpolicy=\"strict-origin-when-cross-origin\""))
        #expect(!el.contains("loading=\"lazy\""))
    }

    @Test func nonYouTubeIframeLazyLoads() throws {
        let target = EmbedTarget(
            kind: .iframe,
            url: "https://player.vimeo.com/video/76979871")
        let el = MediaEmbedPlayerHTML.element(for: target)
        #expect(el.contains("loading=\"lazy\""))
        #expect(!el.contains("referrerpolicy"))
    }

    @Test func sizeClassDistinguishesAudioFromVideo() {
        #expect(MediaEmbedPlayerHTML.sizeClass(for: "https://open.spotify.com/embed/track/x")
               == "wiki-embed-audio")
        #expect(MediaEmbedPlayerHTML.sizeClass(for: "https://www.youtube-nocookie.com/embed/x")
               == "wiki-embed-video")
        #expect(MediaEmbedPlayerHTML.sizeClass(for: "https://player.vimeo.com/video/123")
               == "wiki-embed-video")
    }

    @Test func audioAndVideoTargetsUseNativeTags() {
        #expect(MediaEmbedPlayerHTML.element(for: EmbedTarget(kind: .audio, url: "https://x/a.mp3"))
               .hasPrefix("<audio"))
        #expect(MediaEmbedPlayerHTML.element(for: EmbedTarget(kind: .video, url: "https://x/v.mp4"))
               .hasPrefix("<video"))
    }

    @Test func documentWrapsElementWithTransparentBackground() throws {
        let target = EmbedTarget(kind: .iframe, url: "https://player.vimeo.com/video/1")
        let html = MediaEmbedPlayerHTML.document(for: target)
        #expect(html.contains("background: transparent"))
        #expect(html.contains("<iframe"))
    }

    @Test func elementEscapesAmpersandInURL() {
        // An embed URL already carrying ?& must be HTML-attribute-escaped.
        let target = EmbedTarget(
            kind: .iframe,
            url: "https://www.youtube-nocookie.com/embed/x?enablejsapi=1&origin=y")
        let el = MediaEmbedPlayerHTML.element(for: target)
        #expect(el.contains("&amp;origin=y"))
        #expect(!el.contains("&origin=y"))
    }
}
