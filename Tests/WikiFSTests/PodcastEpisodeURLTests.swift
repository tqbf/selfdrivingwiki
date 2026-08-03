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

    // MARK: - displayTitle(from:) — issue #621

    @Test func displayTitleUnsluggifiesAndTitleCases() {
        // The issue #621 driving example: the slug IS the episode title as Apple
        // generates it for an episode link. Un-slug → human-readable episode
        // title, with small connector words preserved lowercase.
        let slug = "if-you-care-about-food-you-have-to-care-about-land"
        #expect(
            PodcastEpisodeURL.displayTitle(from: slug)
                == "If You Care About Food You Have to Care About Land")
    }

    @Test func displayTitlePreservesSmallWordsLowercaseExceptFirst() {
        // The first word is capitalized even when it's a small word; subsequent
        // small words stay lowercase so the result reads like an episode title.
        #expect(PodcastEpisodeURL.displayTitle(from: "to-the-moon-and-back")
                == "To the Moon and Back")
        #expect(PodcastEpisodeURL.displayTitle(from: "a-walk-in-the-park")
                == "A Walk in the Park")
    }

    @Test func displayTitleHandlesMultiHyphenRuns() {
        // Consecutive hyphens collapse to a single space.
        #expect(PodcastEpisodeURL.displayTitle(from: "foo---bar") == "Foo Bar")
    }

    @Test func displayTitleTrimsLeadingAndTrailingHyphens() {
        #expect(PodcastEpisodeURL.displayTitle(from: "-foo-bar-") == "Foo Bar")
        #expect(PodcastEpisodeURL.displayTitle(from: "--foo--") == "Foo")
    }

    @Test func displayTitleReturnsSingleWordCapitalized() {
        #expect(PodcastEpisodeURL.displayTitle(from: "chinatalk") == "Chinatalk")
    }

    @Test func displayTitleReturnsNilForNilOrEmpty() {
        #expect(PodcastEpisodeURL.displayTitle(from: nil) == nil)
        #expect(PodcastEpisodeURL.displayTitle(from: "") == nil)
        #expect(PodcastEpisodeURL.displayTitle(from: "   ") == nil)
    }

    @Test func displayTitleReturnsNilForAllHyphenInput() {
        // A slug that is only hyphens / whitespace has no words to surface.
        #expect(PodcastEpisodeURL.displayTitle(from: "---") == nil)
        #expect(PodcastEpisodeURL.displayTitle(from: "- - -") == nil)
    }

    @Test func displayTitleHandlesPercentEncodedNonASCII() {
        // `URL.pathComponents` percent-decodes the path before `parse` slices
        // it, so a non-ASCII episode title arrives intact. The helper must NOT
        // re-decode (it would mangle `%`); it just splits on hyphens and
        // capitalizes the first character of each word.
        let slug = "café-con-leche"
        #expect(PodcastEpisodeURL.displayTitle(from: slug) == "Café Con Leche")
    }

    @Test func displayTitlePreservesNumbersAndMixedCaseInput() {
        // Alphanumerics + already-lowercased input are both safe; we lowercase
        // first, then capitalize the initial of each non-small word so mixed
        // case in a stale slug (e.g. a copy-paste drift) normalizes cleanly.
        #expect(PodcastEpisodeURL.displayTitle(from: "phase-4-of-5") == "Phase 4 of 5")
        #expect(PodcastEpisodeURL.displayTitle(from: "EPISODE-7") == "Episode 7")
    }
}
#endif
