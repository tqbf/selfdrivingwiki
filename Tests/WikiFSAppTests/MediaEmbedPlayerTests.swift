#if os(macOS)
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

    // MARK: - MediaTitleFetcher.parseMetadata (#646)

    @Test func parseMetadataDecodesFullBlob() throws {
        // Vimeo-shaped: title + author + description + duration + thumbnail.
        let json = """
        {"title":"Orientation","author_name":"Vimeo Staff","author_url":"https://vimeo.com/staff",
         "provider_name":"Vimeo","thumbnail_url":"https://i.vimeocdn.com/x.jpg",
         "description":"A short orientation","duration":42}
        """
        let m = try #require(MediaTitleFetcher.parseMetadata(from: Data(json.utf8)))
        #expect(m.title == "Orientation")
        #expect(m.authorName == "Vimeo Staff")
        #expect(m.authorURL == "https://vimeo.com/staff")
        #expect(m.providerName == "Vimeo")
        #expect(m.thumbnailURL == "https://i.vimeocdn.com/x.jpg")
        #expect(m.descriptionText == "A short orientation")
        #expect(m.durationSeconds == 42)
    }

    @Test func parseMetadataTolerantOfMissingFields() {
        // YouTube-shape: title + author + provider + thumbnail, NO description/duration.
        let json = #"{"title":"Wave","author_name":"Channel","provider_name":"YouTube"}"#
        let m = MediaTitleFetcher.parseMetadata(from: Data(json.utf8))
        #expect(m?.title == "Wave")
        #expect(m?.authorName == "Channel")
        #expect(m?.providerName == "YouTube")
        #expect(m?.descriptionText == nil)
        #expect(m?.durationSeconds == nil)
    }

    @Test func parseMetadataTrimsAndRejectsWhitespaceOnly() {
        let json = #"{"title":"  Padded  ","description":"\n  \t"}"#
        let m = MediaTitleFetcher.parseMetadata(from: Data(json.utf8))
        #expect(m?.title == "Padded")
        #expect(m?.descriptionText == nil)  // whitespace-only ⇒ nil
    }

    @Test func parseMetadataNilForNonJSON() {
        #expect(MediaTitleFetcher.parseMetadata(from: Data("not json".utf8)) == nil)
    }

    @Test func parseMetadataDurationAcceptsNumericString() {
        let json = #"{"title":"x","duration":"90"}"#
        let m = MediaTitleFetcher.parseMetadata(from: Data(json.utf8))
        #expect(m?.durationSeconds == 90)
    }

    // MARK: - MediaMarkdownSynthesizer (#646)

    @Test func synthesizeIncludesAllMetadataFieldsWhenPresent() {
        let m = MediaTitleFetcher.MediaOEmbedMetadata(
            title: "Orientation", authorName: "Vimeo Staff",
            authorURL: "https://vimeo.com/staff", providerName: "Vimeo",
            thumbnailURL: "https://i.vimeocdn.com/x.jpg",
            descriptionText: "A short orientation", durationSeconds: 3661)
        let md = MediaMarkdownSynthesizer.synthesize(
            url: "https://vimeo.com/1", metadata: m, fallbackTitle: "fallback")
        #expect(md.hasPrefix("# Orientation\n"))
        #expect(md.contains("[https://vimeo.com/1](https://vimeo.com/1)"))
        #expect(md.contains("**Provider:** Vimeo"))
        #expect(md.contains("**Author:** [Vimeo Staff](https://vimeo.com/staff)"))
        #expect(md.contains("**Duration:** 1:01:01"))
        #expect(md.contains("A short orientation"))
        // No transcript section when none provided.
        #expect(!md.contains("## Transcript"))
    }

    @Test func synthesizeFallsBackToTitleWhenMetadataNil() {
        let md = MediaMarkdownSynthesizer.synthesize(
            url: "https://example.com/a.mp3", metadata: nil,
            fallbackTitle: "remote-example.com")
        #expect(md.hasPrefix("# remote-example.com\n"))
        #expect(md.contains("[https://example.com/a.mp3](https://example.com/a.mp3)"))
        #expect(!md.contains("**Provider:**"))
        #expect(!md.contains("**Author:**"))
        #expect(!md.contains("**Duration:**"))
        #expect(!md.contains("## Transcript"))
    }

    @Test func synthesizeUsesMetadataTitleOverFallback() {
        let m = MediaTitleFetcher.MediaOEmbedMetadata(
            title: "Real Title", authorName: nil, authorURL: nil,
            providerName: nil, thumbnailURL: nil,
            descriptionText: nil, durationSeconds: nil)
        let md = MediaMarkdownSynthesizer.synthesize(
            url: "https://x", metadata: m, fallbackTitle: "fallback-name")
        #expect(md.hasPrefix("# Real Title\n"))
    }

    @Test func synthesizeAppendsTranscriptSectionWhenTranscriptProvided() {
        let md = MediaMarkdownSynthesizer.synthesize(
            url: "https://x", metadata: nil, fallbackTitle: "fallback",
            transcript: "Hello world\nSecond cue")
        #expect(md.contains("---"))
        #expect(md.contains("## Transcript"))
        #expect(md.contains("Hello world"))
        #expect(md.contains("Second cue"))
    }

    @Test func synthesizeOmitsTranscriptSectionForEmptyTranscript() {
        let md = MediaMarkdownSynthesizer.synthesize(
            url: "https://x", metadata: nil, fallbackTitle: "fallback",
            transcript: "")
        #expect(!md.contains("## Transcript"))
    }

    @Test func synthesizeAuthorWithoutURLRendersPlain() {
        let m = MediaTitleFetcher.MediaOEmbedMetadata(
            title: "T", authorName: "Channel", authorURL: nil,
            providerName: nil, thumbnailURL: nil,
            descriptionText: nil, durationSeconds: nil)
        let md = MediaMarkdownSynthesizer.synthesize(
            url: "https://x", metadata: m, fallbackTitle: "fallback")
        #expect(md.contains("**Author:** Channel"))
        #expect(!md.contains("[Channel]"))
    }

    @Test func formatDurationHandlesMinutesAndHours() {
        #expect(MediaMarkdownSynthesizer.formatDuration(0) == "0:00")
        #expect(MediaMarkdownSynthesizer.formatDuration(59) == "0:59")
        #expect(MediaMarkdownSynthesizer.formatDuration(90) == "1:30")
        #expect(MediaMarkdownSynthesizer.formatDuration(3661) == "1:01:01")
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
#endif
