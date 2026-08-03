#if os(macOS)
import Foundation
import Testing
import WikiFSTypes

/// PR2 §5.4: regression coverage for `SourceProvider.supportsTranscription`,
/// which now delegates to the content-type registry
/// (`ContentKind.resolve(mimeType: nil, provider: self).capabilities
///  .hasTranscriptBackend`) instead of an independent provider switch.
///
/// Pre-PR2 the property was a hand-maintained switch returning `true` for
/// `.applePodcast`, `.podcast`, `.youtube` and `false` everywhere else.
/// PR1's registry encodes the SAME decision via the resolve/`extractionPath`
/// path (`.podcastTranscript` for `.applePodcast`/`.podcast`, `.youtubeTranscript`
/// for `.youtube`). This file pins the equivalence across every provider case
/// so the delegation can't drift silently (e.g. if a future provider is
/// added to one switch but not the other).
///
/// Also pins the equivalence against the registry's `hasTranscriptBackend`
/// convenience — the half of the registry that the property routes through.
@Suite struct SourceProviderSupportsTranscriptionTests {

    /// The providers with an active transcript pipeline today (PR4 podcasts,
    /// PR5 YouTube). Anything outside this set throws `.notRefreshable` at
    /// `WikiStoreModel.transcribe(sourceID:)`.
    private static let transcriptCapable: Set<SourceProvider> = [
        .applePodcast, .podcast, .youtube,
    ]

    @Test("supportsTranscription matches the transcript-capable set")
    func matchesTranscriptCapableSet() {
        for provider in SourceProvider.allCases {
            let expected = Self.transcriptCapable.contains(provider)
            #expect(
                provider.supportsTranscription == expected,
                "\(provider).supportsTranscription should be \(expected) to match the transcript-capable set")
        }
    }

    @Test("supportsTranscription is the registry's hasTranscriptBackend")
    func matchesRegistryHasTranscriptBackend() {
        // Cross-check against the registry's `hasTranscriptBackend` for every
        // provider. This is the same equivalence the delegated property
        // computes internally — making it an explicit test pins the
        // registry's behavior contract from the provider's side.
        for provider in SourceProvider.allCases {
            let registry = ContentKind
                .resolve(mimeType: nil, provider: provider)
                .capabilities.hasTranscriptBackend
            #expect(
                provider.supportsTranscription == registry,
                "\(provider): supportsTranscription (\(provider.supportsTranscription)) must equal registry hasTranscriptBackend (\(registry))")
        }
    }

    @Test("applePodcast is the only signing-helper-dependent transcript provider")
    func applePodcastIsSigningGuardedBaseline() {
        // (PR4) `.applePodcast`'s *baseline* says true here; the runtime guard
        // (signing helper present + `#if PODCAST_TRANSCRIPTS`) is layered on
        // top at `SourceDetailView.isTranscribable` and
        // `WikiStoreModel.isSourceRefreshable(for:)`. This test only asserts
        // the static baseline — runtime-guard coverage is in IngestGateTests.
        #expect(SourceProvider.applePodcast.supportsTranscription)
    }

    @Test("podcast (generic RSS) is always transcript-capable baseline")
    func podcastBaselineAlwaysTrue() {
        // The `podcast-transcript` uv script needs only `uv` (no signing
        // helper); always available on every build (App Store included).
        #expect(SourceProvider.podcast.supportsTranscription)
    }

    @Test("youtube is the pure-Swift scrape baseline")
    func youtubeBaselineAlwaysTrue() {
        #expect(SourceProvider.youtube.supportsTranscription)
    }

    @Test("vimeo is classified as not-transcript-capable (open: #564)")
    func vimeoBaselineFalse() {
        // Future #564 (Keychain OAuth Vimeo caption pipeline) would flip
        // this to true via a registry `vimeoTranscript` kind + extractionPath
        // case — at which point the registry half of the gate would already
        // be the answer. PR2 intentionally doesn't pre-build that path.
        #expect(!SourceProvider.vimeo.supportsTranscription)
    }

    @Test("Local-file / website / zotero / folder / remoteMedia / legacyImport have no transcript pipeline")
    func byteBearingOrImportProvidersFalse() {
        #expect(!SourceProvider.localFile.supportsTranscription)
        #expect(!SourceProvider.website.supportsTranscription)
        #expect(!SourceProvider.zotero.supportsTranscription)
        #expect(!SourceProvider.markdownFolder.supportsTranscription)
        #expect(!SourceProvider.remoteMedia.supportsTranscription)
        #expect(!SourceProvider.legacyImport.supportsTranscription)
    }

    @Test("Spotify / SoundCloud — no transcript API")
    func audioEmbedsFalse() {
        #expect(!SourceProvider.spotify.supportsTranscription)
        #expect(!SourceProvider.soundcloud.supportsTranscription)
    }

    @Test("SourceProvider.closed: count is stable at 12 cases")
    func providerEnumClosedAt12() {
        // Adding a case is a deliberate decision. Pin so a future transcript-
        // capable provider added to either switch flags a re-audit here.
        #expect(SourceProvider.allCases.count == 12)
    }
}
#endif
