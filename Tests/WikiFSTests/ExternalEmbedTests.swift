import Foundation
import Testing
@testable import WikiFSCore

/// Pure unit tests for `ExternalEmbed.target(for:)` — the single dispatch table
/// that decides what element a byteless external-embed source renders. No store,
/// no network. Covers provider iframes (exact embed URL), direct-remote native
/// tags, the Apple Podcasts host-swap, and the nil fallback cases.
struct ExternalEmbedTests {

    private func descriptor(
        id: PageID = PageID(rawValue: "01HEMBEDTEST0000000000001"),
        mimeType: String? = nil, externalIdentity: String? = nil,
        agentName: String? = nil, planURL: String? = nil
    ) -> SourceEmbedDescriptor {
        SourceEmbedDescriptor(id: id, mimeType: mimeType,
                              externalIdentity: externalIdentity,
                              agentName: agentName, planURL: planURL)
    }

    // MARK: - Provider iframes (AC.1)

    @Test func youtubeTarget() throws {
        let t = try #require(ExternalEmbed.target(for: descriptor(
            mimeType: "video/youtube", externalIdentity: "dQw4w9WgXcQ")))
        #expect(t.kind == .iframe)
        #expect(t.url == "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ")
    }

    @Test func vimeoTarget() throws {
        let t = try #require(ExternalEmbed.target(for: descriptor(
            mimeType: "video/vimeo", externalIdentity: "76979871")))
        #expect(t.kind == .iframe)
        #expect(t.url == "https://player.vimeo.com/video/76979871")
    }

    @Test func spotifyTarget() throws {
        let t = try #require(ExternalEmbed.target(for: descriptor(
            mimeType: "audio/spotify", externalIdentity: "track/4uLU6hMCjMI75M1A2tKUQC")))
        #expect(t.kind == .iframe)
        #expect(t.url == "https://open.spotify.com/embed/track/4uLU6hMCjMI75M1A2tKUQC")
    }

    @Test func soundcloudTarget() throws {
        let track = "https://soundcloud.com/forss/flickermood"
        let t = try #require(ExternalEmbed.target(for: descriptor(
            mimeType: "audio/soundcloud", externalIdentity: track)))
        #expect(t.kind == .iframe)
        #expect(t.url == "https://w.soundcloud.com/player/?url=https%3A%2F%2Fsoundcloud.com%2Fforss%2Fflickermood")
    }

    @Test func providerTargetNilWhenNoIdentity() throws {
        #expect(ExternalEmbed.target(for: descriptor(mimeType: "video/youtube")) == nil)
        #expect(ExternalEmbed.target(for: descriptor(mimeType: "audio/spotify")) == nil)
    }

    // MARK: - Direct-remote native media (AC.2)

    @Test func directRemoteAudio() throws {
        let t = try #require(ExternalEmbed.target(for: descriptor(
            mimeType: "audio/mpeg", externalIdentity: "https://radio.example.com/live.mp3")))
        #expect(t.kind == .audio)
        #expect(t.url == "https://radio.example.com/live.mp3")
    }

    @Test func directRemoteVideo() throws {
        let t = try #require(ExternalEmbed.target(for: descriptor(
            mimeType: "video/mp4", externalIdentity: "https://example.com/clip.mp4")))
        #expect(t.kind == .video)
        #expect(t.url == "https://example.com/clip.mp4")
    }

    @Test func directRemoteNilWhenNoIdentity() throws {
        #expect(ExternalEmbed.target(for: descriptor(mimeType: "audio/mpeg")) == nil)
    }

    @Test func directRemoteHLSManifestRendersAsVideo() throws {
        // HLS (.m3u8) carries an application/* mime but plays in a native <video>.
        let t = try #require(ExternalEmbed.target(for: descriptor(
            mimeType: "application/vnd.apple.mpegurl",
            externalIdentity: "https://example.com/stream.m3u8")))
        #expect(t.kind == .video)
        #expect(t.url == "https://example.com/stream.m3u8")
    }

    // MARK: - Apple Podcasts host-swap (AC.3)

    @Test func applePodcastHostSwapPreservesPathAndQuery() throws {
        let planURL = "https://podcasts.apple.com/us/podcast/chinatalk/id1289062927?i=1000774368453"
        let t = try #require(ExternalEmbed.target(for: descriptor(
            agentName: "apple-podcast", planURL: planURL)))
        #expect(t.kind == .iframe)
        // Only the host changes; path + ?i=<episodeId> are preserved.
        #expect(t.url.contains("embed.podcasts.apple.com"))
        #expect(t.url.contains("/us/podcast/chinatalk/id1289062927"))
        #expect(t.url.contains("?i=1000774368453"))
        #expect(!t.url.contains("//podcasts.apple.com"))
    }

    @Test func applePodcastEmbedHostIsIdempotent() throws {
        let planURL = "https://embed.podcasts.apple.com/us/podcast/chinatalk/id1289062927?i=1000774368453"
        let t = try #require(ExternalEmbed.target(for: descriptor(
            agentName: "apple-podcast", planURL: planURL)))
        // Already an embed URL → unchanged (host stays embed.podcasts.apple.com).
        #expect(t.url.contains("embed.podcasts.apple.com"))
        #expect(t.url.contains("?i=1000774368453"))
    }

    @Test func applePodcastNonApplePlanReturnsNil() throws {
        // A planURL that isn't podcasts.apple.com → nil (transcript still renders).
        #expect(ExternalEmbed.target(for: descriptor(
            agentName: "apple-podcast", planURL: "https://example.com/show")) == nil)
    }

    @Test func applePodcastMissingPlanReturnsNil() throws {
        #expect(ExternalEmbed.target(for: descriptor(agentName: "apple-podcast")) == nil)
    }

    @Test func applePodcastRegionalSubhost() throws {
        let planURL = "https://podcasts.apple.com/us/podcast/show/id123?i=456"
        let t = try #require(ExternalEmbed.target(for: descriptor(
            agentName: "apple-podcast", planURL: planURL)))
        #expect(t.url.contains("embed.podcasts.apple.com"))
        #expect(t.url.contains("?i=456"))
    }

    // MARK: - Nil fallback (AC.5)

    @Test func nilForNonMediaByteless() throws {
        #expect(ExternalEmbed.target(for: descriptor(mimeType: "text/plain")) == nil)
        #expect(ExternalEmbed.target(for: descriptor(mimeType: "application/json")) == nil)
    }

    @Test func nilForNilMime() throws {
        #expect(ExternalEmbed.target(for: descriptor()) == nil)
    }
}
