#if PODCAST_TRANSCRIPTS  // Feature off for WIKIFS_APP_STORE=1 builds.
import Foundation
import Testing
@testable import WikiFSCore

/// Tests for the subprocess-based `RSSPodcastTranscriptService` — verifies the
/// pure result-mapping logic (exit code → `PodcastTranscriptError`, JSON decode
/// → `PodcastTranscript`) without spawning a real subprocess. Integration tests
/// that actually spawn the script are gated on `resolveScript()` presence.
///
/// Issue #812.
struct RSSPodcastTranscriptTests {

    /// A canonical episode ref used across tests.
    static let episode = PodcastEpisodeURL.EpisodeRef(id: "1000774368453", slug: "chinatalk")

    // MARK: - Exit code mapping

    @Test func mapResultExit0DecodesTranscript() throws {
        let json = """
        {
            "show_id": "1289062927",
            "episode_id": "1000774368453",
            "language": "en",
            "format": "vtt",
            "markdown": "Welcome to the show. Today we talk about China."
        }
        """
        let result = (stdout: json, stderr: "", status: Int32(0))
        let transcript = try RSSPodcastTranscriptService.mapResult(result, episode: Self.episode)

        #expect(transcript.episodeID == "1000774368453")
        #expect(transcript.markdown == "Welcome to the show. Today we talk about China.")
        #expect(transcript.filename == "chinatalk-1000774368453-transcript.md")
    }

    @Test func mapResultExit3ThrowsNoTranscript() {
        let result = (stdout: "", stderr: "Podcast not found", status: Int32(3))
        #expect(throws: PodcastTranscriptError.noTranscriptAvailable) {
            try RSSPodcastTranscriptService.mapResult(result, episode: Self.episode)
        }
    }

    @Test func mapResultExit4ThrowsNoTranscript() {
        let result = (stdout: "", stderr: "Episode not found in feed", status: Int32(4))
        #expect(throws: PodcastTranscriptError.noTranscriptAvailable) {
            try RSSPodcastTranscriptService.mapResult(result, episode: Self.episode)
        }
    }

    @Test func mapResultExit1ThrowsNoTranscript() {
        let result = (stdout: "", stderr: "Network error", status: Int32(1))
        #expect(throws: PodcastTranscriptError.noTranscriptAvailable) {
            try RSSPodcastTranscriptService.mapResult(result, episode: Self.episode)
        }
    }

    // MARK: - Edge cases

    @Test func mapResultEmptyOutputThrowsParseFailed() {
        let result = (stdout: "   \n  ", stderr: "", status: Int32(0))
        #expect(throws: PodcastTranscriptError.ttmlParseFailed) {
            try RSSPodcastTranscriptService.mapResult(result, episode: Self.episode)
        }
    }

    @Test func mapResultInvalidJsonThrowsParseFailed() {
        let result = (stdout: "not json at all", stderr: "", status: Int32(0))
        #expect(throws: PodcastTranscriptError.ttmlParseFailed) {
            try RSSPodcastTranscriptService.mapResult(result, episode: Self.episode)
        }
    }

    @Test func mapResultMissingEpisodeIdFallsBackToRef() throws {
        let json = """
        {"show_id": "123", "language": "en", "markdown": "text"}
        """
        let result = (stdout: json, stderr: "", status: Int32(0))
        let transcript = try RSSPodcastTranscriptService.mapResult(result, episode: Self.episode)

        #expect(transcript.episodeID == "1000774368453")
    }

    @Test func mapResultMissingMarkdownUsesEmptyString() throws {
        let json = """
        {"episode_id": "1000774368453", "language": "en"}
        """
        let result = (stdout: json, stderr: "", status: Int32(0))
        let transcript = try RSSPodcastTranscriptService.mapResult(result, episode: Self.episode)

        #expect(transcript.episodeID == "1000774368453")
        #expect(transcript.markdown == "")
    }

    // MARK: - Filename

    @Test func filenameWithSlug() {
        let ref = PodcastEpisodeURL.EpisodeRef(id: "123", slug: "my-show")
        let name = RSSPodcastTranscriptService.filename(for: ref)
        #expect(name == "my-show-123-transcript.md")
    }

    @Test func filenameWithoutSlug() {
        let ref = PodcastEpisodeURL.EpisodeRef(id: "123", slug: nil)
        let name = RSSPodcastTranscriptService.filename(for: ref)
        #expect(name == "podcast-123-transcript.md")
    }

    // MARK: - Script resolution (integration — no assertion on found/nil)

    @Test func resolveScriptDoesNotCrash() {
        _ = RSSPodcastTranscriptService.resolveScript()
    }
}
#endif
