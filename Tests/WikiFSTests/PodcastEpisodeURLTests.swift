#if PODCAST_TRANSCRIPTS  // Feature off for WIKIFS_APP_STORE=1 builds.
import Foundation
import Testing
@testable import WikiFSCore

/// Tests for `PodcastEpisodeURL` — the pure recognizer that decides whether pasted
/// text is an Apple Podcasts *episode* link (and extracts the episode ID + show
/// slug). No network. The first case is the feature's driving example (see
/// `plans/podcast-transcripts.md`).
struct PodcastEpisodeURLTests {

    @Test func recognizesChinaTalkEpisodeURL() {
        let ref = PodcastEpisodeURL.parse(
            "https://podcasts.apple.com/us/podcast/chinatalk/id1289062927?i=1000774368453")
        #expect(ref == PodcastEpisodeURL.EpisodeRef(id: "1000774368453", slug: "chinatalk"))
    }

    @Test func recognizesHTTPAndWhitespacePaddedInput() {
        let ref = PodcastEpisodeURL.parse(
            "  http://podcasts.apple.com/us/podcast/chinatalk/id1289062927?i=1000774368453\n")
        #expect(ref?.id == "1000774368453")
    }

    @Test func recognizesSchemelessPaste() {
        // Add-from-URL accepts scheme-less pastes (`normalizeURL` prepends https),
        // so the recognizer must too.
        let ref = PodcastEpisodeURL.parse(
            "podcasts.apple.com/us/podcast/chinatalk/id1289062927?i=1000774368453")
        #expect(ref?.id == "1000774368453")
    }

    @Test func extraQueryParametersDontConfuseIt() {
        let ref = PodcastEpisodeURL.parse(
            "https://podcasts.apple.com/us/podcast/chinatalk/id1289062927?l=en-US&i=1000774368453&at=xyz")
        #expect(ref == PodcastEpisodeURL.EpisodeRef(id: "1000774368453", slug: "chinatalk"))
    }

    @Test func showLinkWithoutEpisodeParameterIsNotAnEpisode() {
        // A show page (no `i=`) falls through to the normal HTML ingest path.
        #expect(PodcastEpisodeURL.parse(
            "https://podcasts.apple.com/us/podcast/chinatalk/id1289062927") == nil)
    }

    @Test func nonNumericEpisodeParameterRejected() {
        #expect(PodcastEpisodeURL.parse(
            "https://podcasts.apple.com/us/podcast/chinatalk/id1289062927?i=abc123") == nil)
    }

    @Test func nonAppleHostsRejected() {
        #expect(PodcastEpisodeURL.parse(
            "https://example.com/us/podcast/chinatalk/id1289062927?i=1000774368453") == nil)
        // Suffix matching must not accept a look-alike host.
        #expect(PodcastEpisodeURL.parse(
            "https://evilpodcasts.apple.com.example.com/x?i=1000774368453") == nil)
    }

    @Test func otherAppleHostsAreNotEpisodeLinks() {
        // Only the Podcasts site carries episode links this recognizer owns; a
        // music.apple.com URL with an `i=` param is someone else's ingest.
        #expect(PodcastEpisodeURL.parse(
            "https://music.apple.com/us/album/something/123?i=456") == nil)
    }

    @Test func nonURLTextRejected() {
        #expect(PodcastEpisodeURL.parse("hello world") == nil)
        #expect(PodcastEpisodeURL.parse("") == nil)
    }

    @Test func slugIsNilWhenPathHasNone() {
        // Minimal episode link with no /podcast/<slug>/ path — still an episode,
        // just no pretty stem for the filename.
        let ref = PodcastEpisodeURL.parse("https://podcasts.apple.com/us?i=1000774368453")
        #expect(ref?.id == "1000774368453")
        #expect(ref?.slug == nil)
    }
}
#endif
