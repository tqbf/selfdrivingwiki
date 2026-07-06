import Foundation
import Testing
@testable import WikiFSCore

/// Pure unit tests for the byteless external-embed URL recognizers (no store,
/// no network). Covers every provider (YouTube variants, Vimeo, Spotify,
/// SoundCloud) + the direct-remote media-extension heuristic, plus the
/// rejection cases (HTML / unknown / extension-less).
@MainActor
struct MediaEmbedURLTests {

    // MARK: - YouTube

    @Test func youtubeWatchURL() throws {
        let m = try #require(MediaEmbedURL.youtube("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        #expect(m.agentName == "youtube")
        #expect(m.mimeType == "video/youtube")
        #expect(m.externalIdentity == "dQw4w9WgXcQ")
        #expect(m.filename == "youtube-dQw4w9WgXcQ")
        #expect(m.activityKind == "fetch")
    }

    @Test func youtubeShortLink() throws {
        let m = try #require(MediaEmbedURL.youtube("https://youtu.be/dQw4w9WgXcQ"))
        #expect(m.externalIdentity == "dQw4w9WgXcQ")
    }

    @Test func youtubeEmbedPath() throws {
        let m = try #require(MediaEmbedURL.youtube("https://youtube.com/embed/dQw4w9WgXcQ"))
        #expect(m.externalIdentity == "dQw4w9WgXcQ")
    }

    @Test func youtubeShortsPath() throws {
        let m = try #require(MediaEmbedURL.youtube("https://www.youtube.com/shorts/dQw4w9WgXcQ"))
        #expect(m.externalIdentity == "dQw4w9WgXcQ")
    }

    @Test func youtubeMobileHost() throws {
        let m = try #require(MediaEmbedURL.youtube("https://m.youtube.com/watch?v=dQw4w9WgXcQ&t=10"))
        #expect(m.externalIdentity == "dQw4w9WgXcQ")
    }

    @Test func youtubeRejectsJunkID() throws {
        #expect(MediaEmbedURL.youtube("https://www.youtube.com/watch?v=tooshort") == nil)
    }

    @Test func youtubeRejectsNonYouTubeHost() throws {
        #expect(MediaEmbedURL.youtube("https://vimeo.com/123456") == nil)
    }

    // MARK: - Vimeo

    @Test func vimeoNumericID() throws {
        let m = try #require(MediaEmbedURL.vimeo("https://vimeo.com/76979871"))
        #expect(m.agentName == "vimeo")
        #expect(m.mimeType == "video/vimeo")
        #expect(m.externalIdentity == "76979871")
        #expect(m.filename == "vimeo-76979871")
    }

    @Test func vimeoPlayerHost() throws {
        let m = try #require(MediaEmbedURL.vimeo("https://player.vimeo.com/video/76979871"))
        #expect(m.externalIdentity == "76979871")
    }

    @Test func vimeoRejectsNonNumeric() throws {
        #expect(MediaEmbedURL.vimeo("https://vimeo.com/channels/staffpicks") == nil)
    }

    // MARK: - Spotify

    @Test func spotifyTrack() throws {
        let m = try #require(MediaEmbedURL.spotify("https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC"))
        #expect(m.agentName == "spotify")
        #expect(m.mimeType == "audio/spotify")
        #expect(m.externalIdentity == "track/4uLU6hMCjMI75M1A2tKUQC")
        #expect(m.filename == "spotify-track-4uLU6hMCjMI75M1A2tKUQC")
    }

    @Test func spotifyEpisode() throws {
        let m = try #require(MediaEmbedURL.spotify("https://open.spotify.com/episode/abc123XYZ"))
        #expect(m.externalIdentity == "episode/abc123XYZ")
    }

    @Test func spotifyPodcast() throws {
        let m = try #require(MediaEmbedURL.spotify("https://open.spotify.com/podcast/show123"))
        #expect(m.externalIdentity == "podcast/show123")
    }

    @Test func spotifyRejectsBadType() throws {
        #expect(MediaEmbedURL.spotify("https://open.spotify.com/album/abc") == nil)
    }

    // MARK: - SoundCloud

    @Test func soundcloudTrack() throws {
        let raw = "https://soundcloud.com/forss/flickermood"
        let m = try #require(MediaEmbedURL.soundcloud(raw))
        #expect(m.agentName == "soundcloud")
        #expect(m.mimeType == "audio/soundcloud")
        // externalIdentity is the full track URL (the embed needs it url-encoded).
        #expect(m.externalIdentity == raw)
        #expect(m.filename == "soundcloud-flickermood")
    }

    @Test func soundcloudRejectsSingleSegment() throws {
        #expect(MediaEmbedURL.soundcloud("https://soundcloud.com/artist") == nil)
    }

    // MARK: - Direct-remote media

    @Test func remoteMp3() throws {
        let m = try #require(MediaEmbedURL.remoteMedia("https://radio.example.com/live.mp3"))
        #expect(m.agentName == "remote-media")
        #expect(m.mimeType == "audio/mpeg")
        #expect(m.externalIdentity == "https://radio.example.com/live.mp3")
        #expect(m.filename == "live.mp3")
        #expect(m.activityKind == "import")
    }

    @Test func remoteMp4() throws {
        let m = try #require(MediaEmbedURL.remoteMedia("https://example.com/clip.mp4"))
        #expect(m.mimeType == "video/mp4")
        #expect(m.filename == "clip.mp4")
    }

    @Test func remoteHLS() throws {
        let m = try #require(MediaEmbedURL.remoteMedia("https://example.com/stream.m3u8"))
        #expect(m.mimeType == "application/vnd.apple.mpegurl")
    }

    @Test func remoteRejectsHTML() throws {
        #expect(MediaEmbedURL.remoteMedia("https://example.com/article.html") == nil)
    }

    @Test func remoteRejectsExtensionless() throws {
        #expect(MediaEmbedURL.remoteMedia("https://radio.example.com/live") == nil)
    }

    @Test func remoteRejectsUnknownExtension() throws {
        #expect(MediaEmbedURL.remoteMedia("https://example.com/data.xyz") == nil)
    }

    @Test func mediaMIMEExtensionTable() throws {
        #expect(MediaEmbedURL.mediaMIME(forExtension: "m4a") == "audio/mp4")
        #expect(MediaEmbedURL.mediaMIME(forExtension: "opus") == "audio/ogg")
        #expect(MediaEmbedURL.mediaMIME(forExtension: "mov") == "video/quicktime")
        #expect(MediaEmbedURL.mediaMIME(forExtension: "html") == nil)
        #expect(MediaEmbedURL.mediaMIME(forExtension: "") == nil)
    }
}
