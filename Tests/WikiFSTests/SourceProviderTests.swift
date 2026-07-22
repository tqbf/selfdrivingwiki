import Foundation
import Testing
@testable import WikiFSCore

/// `SourceProvider` enum — typed taxonomy for source origin. Exercises
/// rawValue round-trip identity, the parse-with-fallback for unknown/nil
/// values, the enum-carried display properties (displayLabel / systemImage /
/// helpVerb / supportsRefresh), and the `SourceOrigin.provider` /
/// `MediaEmbedMatch.provider` / `SourceEmbedDescriptor.provider` computed
/// properties' resolution for known + unknown agent names.
///
/// #source-provider-enum — see `plans/source-provider-enum.md`. The stored
/// `agents.name` bytes are byte-identical to the pre-enum strings, so existing
/// suite tests still exercise the construction + parse paths.
@Suite struct SourceProviderTests {

    // MARK: - AC.1: round-trip identity

    /// `SourceProvider(rawValue: p.rawValue) == p` for every case. Also
    /// exercises CaseIterable coverage so a future case is automatically
    /// caught by this test (the parameter list will need updating).
    @Test("SourceProvider round-trips every case through rawValue",
          arguments: SourceProvider.allCases)
    func roundTripIdentity(_ provider: SourceProvider) {
        let parsed = SourceProvider(rawValue: provider.rawValue)
        #expect(parsed == provider,
                "\(provider.rawValue) should round-trip (got \(parsed.map(String.init(describing:)) ?? "nil"))")
    }

    // MARK: - AC.2: init(rawValue:) edge cases

    @Test("init(rawValue:) returns nil for empty + nil input")
    func parsesNilAndEmptyAsNil() {
        #expect(SourceProvider(rawValue: nil as String?) == nil)
        #expect(SourceProvider(rawValue: "") == nil)
    }

    @Test("init(rawValue:) returns nil for unknown values (forward compat)")
    func parsesUnknownAsNil() {
        // A future code path that writes an unmigrated provider's `agents.name`
        // (or a test value) parses as nil — the switch sites degrade to their
        // default arm. This is the intentional "graceful fallback" rule from
        // `plans/source-provider-enum.md` §Type changes (verifying nil here
        // documents the contract: unknown ≠ .legacyImport, unlike PageAuthor).
        #expect(SourceProvider(rawValue: "test") == nil)
        #expect(SourceProvider(rawValue: "unknown-provider") == nil)
        #expect(SourceProvider(rawValue: "Website") == nil, // case-sensitive
                "rawValue matching is case-sensitive (stored values are lowercase)")
    }

    // MARK: - AC.3: enum-carried display values

    @Test("rawValue matches the canonical stored string for each case")
    func rawValueLiterals() {
        // Pins the rawValues so a future rename to the enum case name doesn't
        // silently shift the stored bytes (no DB migration). The stored
        // values use kebab-case; the Swift case names use camelCase.
        #expect(SourceProvider.localFile.rawValue == "local-file")
        #expect(SourceProvider.website.rawValue == "website")
        #expect(SourceProvider.zotero.rawValue == "zotero")
        #expect(SourceProvider.markdownFolder.rawValue == "markdown-folder")
        #expect(SourceProvider.applePodcast.rawValue == "apple-podcast")
        #expect(SourceProvider.podcast.rawValue == "podcast")
        #expect(SourceProvider.youtube.rawValue == "youtube")
        #expect(SourceProvider.vimeo.rawValue == "vimeo")
        #expect(SourceProvider.spotify.rawValue == "spotify")
        #expect(SourceProvider.soundcloud.rawValue == "soundcloud")
        #expect(SourceProvider.remoteMedia.rawValue == "remote-media")
        #expect(SourceProvider.legacyImport.rawValue == "legacy-import")
    }

    @Test("displayLabel returns the canonical UI label for each case")
    func displayLabelMapping() {
        // AC.6: collapses disagreements across the 4 switch sites. The enum
        // carries ONE canonical label per provider.
        #expect(SourceProvider.localFile.displayLabel == "File")
        #expect(SourceProvider.website.displayLabel == "Website")
        #expect(SourceProvider.zotero.displayLabel == "Zotero")
        #expect(SourceProvider.markdownFolder.displayLabel == "Folder",
                "markdown-folder displays as 'Folder' (not 'Markdown folder') — matches DetailView UI")
        #expect(SourceProvider.applePodcast.displayLabel == "Apple Podcast")
        #expect(SourceProvider.podcast.displayLabel == "Podcast")
        #expect(SourceProvider.youtube.displayLabel == "YouTube",
                "YouTube brand casing (not 'Youtube')")
        #expect(SourceProvider.vimeo.displayLabel == "Vimeo")
        #expect(SourceProvider.spotify.displayLabel == "Spotify")
        #expect(SourceProvider.soundcloud.displayLabel == "SoundCloud",
                "SoundCloud brand casing (not 'Soundcloud')")
        #expect(SourceProvider.remoteMedia.displayLabel == "Media")
        #expect(SourceProvider.legacyImport.displayLabel == "Imported")
    }

    @Test("systemImage returns a non-empty SF Symbol name for each case",
          arguments: SourceProvider.allCases)
    func systemImageNonEmpty(_ provider: SourceProvider) {
        let symbol = provider.systemImage
        #expect(!symbol.isEmpty,
                "systemImage must be non-empty for \(provider.rawValue)")
    }

    @Test("helpVerb returns a non-empty help text for each case",
          arguments: SourceProvider.allCases)
    func helpVerbNonEmpty(_ provider: SourceProvider) {
        let verb = provider.helpVerb
        #expect(!verb.isEmpty,
                "helpVerb must be non-empty for \(provider.rawValue)")
    }

    @Test("helpVerb covers Reveal vs Open semantics")
    func helpVerbSemantics() {
        // Local paths (file/folder) "Reveal" in Finder; URL providers "Open"
        // (or subclasses like "Open episode" for podcasts). The verb lets
        // the UI chip phrase its tooltip consistently.
        #expect(SourceProvider.localFile.helpVerb.hasPrefix("Reveal"))
        #expect(SourceProvider.markdownFolder.helpVerb.hasPrefix("Reveal"))
        #expect(SourceProvider.website.helpVerb.hasPrefix("Open"))
        #expect(SourceProvider.applePodcast.helpVerb.hasPrefix("Open"))
        #expect(SourceProvider.podcast.helpVerb.hasPrefix("Open"))
        #expect(SourceProvider.youtube.helpVerb.hasPrefix("Open"))
        #expect(SourceProvider.remoteMedia.helpVerb.hasPrefix("Open"))
    }

    // MARK: - AC.7: supportsRefresh baseline

    @Test("supportsRefresh is true only for website + applePodcast (baseline)")
    func supportsRefreshBaseline() {
        // AC.7: `supportsRefresh` collapses the refreshability switch into one
        // enum property. This is BASELINE ONLY — `WikiStoreModel.isSourceRefreshable`
        // layers runtime guards (hasImageSiblings for websites; the bundled
        // signing helper for podcasts) on top of this predicate.
        #expect(SourceProvider.website.supportsRefresh == true)
        #expect(SourceProvider.applePodcast.supportsRefresh == true)
        #expect(SourceProvider.podcast.supportsRefresh == true,
                "generic .podcast is refreshable (re-fetch transcript via RSS script)")
        // Everything else is import-only or byteless-embed-only — no URL to
        // re-fetch. (Direct-remote media could in principle be re-fetched, but
        // the refresh service doesn't implement it today.)
        #expect(SourceProvider.localFile.supportsRefresh == false)
        #expect(SourceProvider.zotero.supportsRefresh == false)
        #expect(SourceProvider.markdownFolder.supportsRefresh == false)
        #expect(SourceProvider.youtube.supportsRefresh == false)
        #expect(SourceProvider.vimeo.supportsRefresh == false)
        #expect(SourceProvider.spotify.supportsRefresh == false)
        #expect(SourceProvider.soundcloud.supportsRefresh == false)
        #expect(SourceProvider.remoteMedia.supportsRefresh == false)
        #expect(SourceProvider.legacyImport.supportsRefresh == false)
    }

    // MARK: - AC.8 (PR5): supportsTranscription baseline

    @Test("supportsTranscription is true only for applePodcast + youtube (PR5 baseline)")
    func supportsTranscriptionBaseline() {
        // Issue #799 PR5 — `supportsTranscription` is a sister property to
        // `supportsRefresh`, gating the byteless-embed providers whose only
        // path to a transcript markdown is the on-demand Transcribe button
        // (`WikiStoreModel.transcribe(sourceID:)` — the unified provider-
        // dispatch entry point). This is BASELINE ONLY —
        // `SourceDetailView.isTranscribable` layers runtime guards on top
        // (the bundled signing helper for podcasts; always-available for
        // YouTube). `supportsTranscription` differs from `supportsRefresh`:
        // YouTube is transcribable but not refreshable; a website is
        // refreshable but not transcribable.
        #expect(SourceProvider.applePodcast.supportsTranscription == true)
        #expect(SourceProvider.podcast.supportsTranscription == true,
                "generic .podcast is transcribable (RSS <podcast:transcript> via uv script)")
        #expect(SourceProvider.youtube.supportsTranscription == true)
        // Every other provider has no transcript pipeline today — Vimeo is
        // a future extension (needs a Keychain OAuth token; #564 Phase 4);
        // Spotify/SoundCloud/remote-media have no public transcript API;
        // local-file / Zotero / folder / website / legacy-import have no
        // network fetch to perform.
        #expect(SourceProvider.localFile.supportsTranscription == false)
        #expect(SourceProvider.website.supportsTranscription == false)
        #expect(SourceProvider.zotero.supportsTranscription == false)
        #expect(SourceProvider.markdownFolder.supportsTranscription == false)
        #expect(SourceProvider.vimeo.supportsTranscription == false)
        #expect(SourceProvider.spotify.supportsTranscription == false)
        #expect(SourceProvider.soundcloud.supportsTranscription == false)
        #expect(SourceProvider.remoteMedia.supportsTranscription == false)
        #expect(SourceProvider.legacyImport.supportsTranscription == false)
    }

    @Test("supportsTranscription and supportsRefresh differ only for website + youtube")
    func supportsTranscriptionVsRefreshDivergence() {
        // Pins the documented divergence (issue #799 PR5):
        // - website is refreshable but NOT transcribable (HTML→md re-extract
        //   lives on a separate, queue-coupled extraction path; the
        //   `transcribe` dispatch switch throws `.notRefreshable` for it).
        // - youtube is transcribable but NOT refreshable (the byteless embed
        //   has no source URL to "re-fetch"; the captions scrape is the only
        //   on-demand transcript pipeline, and it runs through `transcribe`).
        // - applePodcast is BOTH refreshable AND transcribable (the signing
        //   helper runs both a refresh fetch AND a fresh transcription).
        // - every other provider is neither.
        #expect(SourceProvider.website.supportsRefresh)
        #expect(!SourceProvider.website.supportsTranscription)
        #expect(!SourceProvider.youtube.supportsRefresh)
        #expect(SourceProvider.youtube.supportsTranscription)
        #expect(SourceProvider.applePodcast.supportsRefresh)
        #expect(SourceProvider.applePodcast.supportsTranscription)
    }

    // MARK: - AC.4: SourceOrigin.provider

    /// Build a minimal `SourceOrigin` for testing the `provider` computed
    /// property — only `agentName` matters; the other columns are filler.
    private func origin(agentName: String) -> SourceOrigin {
        SourceOrigin(
            versionID: "01JTESTVERSION000000",
            agentName: agentName,
            agentKind: "software",
            activityKind: "import",
            plan: nil, externalRef: nil, externalIdentity: nil,
            runTitle: nil,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("SourceOrigin.provider resolves each known provider")
    func sourceOriginProviderKnown() {
        // Round-trip: each known rawValue parses to its case via SourceOrigin.provider.
        #expect(origin(agentName: "local-file").provider == .localFile)
        #expect(origin(agentName: "website").provider == .website)
        #expect(origin(agentName: "zotero").provider == .zotero)
        #expect(origin(agentName: "markdown-folder").provider == .markdownFolder)
        #expect(origin(agentName: "apple-podcast").provider == .applePodcast)
        #expect(origin(agentName: "podcast").provider == .podcast)
        #expect(origin(agentName: "youtube").provider == .youtube)
        #expect(origin(agentName: "vimeo").provider == .vimeo)
        #expect(origin(agentName: "spotify").provider == .spotify)
        #expect(origin(agentName: "soundcloud").provider == .soundcloud)
        #expect(origin(agentName: "remote-media").provider == .remoteMedia)
        #expect(origin(agentName: "legacy-import").provider == .legacyImport)
    }

    @Test("SourceOrigin.provider returns nil for unknown agentName")
    func sourceOriginProviderUnknown() {
        #expect(origin(agentName: "").provider == nil)
        #expect(origin(agentName: "unknown").provider == nil)
        #expect(origin(agentName: "test").provider == nil)
        #expect(origin(agentName: "Website").provider == nil,
                "case-sensitive parse — 'Website' (capital W) is NOT 'website'")
    }

    // MARK: - AC.4 + AC.6: SourceOrigin.displayLabel delegates to provider

    @Test("SourceOrigin.displayLabel delegates to provider.displayLabel")
    func sourceOriginDisplayLabelDelegates() {
        // The label disagreements are resolved: SourceOrigin.displayLabel
        // returns the enum's canonical label (Folder, YouTube, SoundCloud).
        #expect(origin(agentName: "markdown-folder").displayLabel == "Folder")
        #expect(origin(agentName: "youtube").displayLabel == "YouTube")
        #expect(origin(agentName: "soundcloud").displayLabel == "SoundCloud")
        #expect(origin(agentName: "local-file").displayLabel == "File")
        #expect(origin(agentName: "legacy-import").displayLabel == "Imported")
    }

    @Test("SourceOrigin.displayLabel falls back to agentName.capitalized for unknown")
    func sourceOriginDisplayLabelUnknownFallback() {
        // Unknown agents use the pre-enum fallback: agentName.capitalized.
        // Swift's .capitalized capitalizes the first char of EACH word AND
        // lowercases the rest; word breaks happen at punctuation (e.g. `-`).
        #expect(origin(agentName: "custom-bot").displayLabel == "Custom-Bot")
        #expect(origin(agentName: "futureProvider").displayLabel == "Futureprovider")
        #expect(origin(agentName: "").displayLabel == "")
    }

    // MARK: - AC.4 extension: MediaEmbedMatch.provider + SourceEmbedDescriptor.provider

    @Test("MediaEmbedMatch.provider resolves byteless providers")
    func mediaEmbedMatchProvider() {
        // MediaEmbedMatch's agentName is always set by MediaEmbedURL's
        // recognizers (SourceProvider.X.rawValue), so provider is non-nil for
        // any real match — but the property degrades safely for unknown.
        let youtube = MediaEmbedMatch(
            agentName: "youtube", mimeType: "video/youtube",
            externalIdentity: "abc", filename: "youtube-abc",
            planURL: "https://youtu.be/abc", activityKind: "fetch")
        #expect(youtube.provider == .youtube)

        let remoteMedia = MediaEmbedMatch(
            agentName: "remote-media", mimeType: "audio/mpeg",
            externalIdentity: "https://example.com/x.mp3", filename: "x.mp3",
            planURL: "https://example.com/x.mp3", activityKind: "import")
        #expect(remoteMedia.provider == .remoteMedia)

        let unknown = MediaEmbedMatch(
            agentName: "future-provider", mimeType: "video/future",
            externalIdentity: "x", filename: "future-x",
            planURL: "https://example.com/x", activityKind: "fetch")
        #expect(unknown.provider == nil)
    }

    @Test("SourceEmbedDescriptor.provider resolves byteless provider descriptors")
    func sourceEmbedDescriptorProvider() {
        // agentName is an Optional<String> on SourceEmbedDescriptor, so provider
        // is nil for any of {nil, "", "unknown"}.
        let podcastDescriptor = SourceEmbedDescriptor(
            id: PageID(rawValue: "01JTESTDESC00000000"),
            mimeType: "text/markdown",
            externalIdentity: nil,
            agentName: "apple-podcast",
            planURL: "https://podcasts.apple.com/podcast/episode?id=123")
        #expect(podcastDescriptor.provider == .applePodcast)

        let nilAgent = SourceEmbedDescriptor(
            id: PageID(rawValue: "01JTESTDESC00000001"),
            mimeType: "audio/mpeg",
            externalIdentity: "https://example.com/x.mp3",
            agentName: nil,
            planURL: nil)
        #expect(nilAgent.provider == nil)

        let emptyAgent = SourceEmbedDescriptor(
            id: PageID(rawValue: "01JTESTDESC00000002"),
            mimeType: "audio/mpeg",
            externalIdentity: "https://example.com/y.mp3",
            agentName: "",
            planURL: "https://example.com/y.mp3")
        #expect(emptyAgent.provider == nil,
                "agentName = '' parses to nil (SourceProvider's init rejects empty)")
    }

    // MARK: - CaseIterable coverage

    @Test("SourceProvider.allCases covers 12 cases")
    func allCasesCount() {
        #expect(SourceProvider.allCases.count == 12)
        // Spot-check membership so adding a case without updating the count
        // assertion doesn't silently regress coverage.
        #expect(SourceProvider.allCases.contains(.localFile))
        #expect(SourceProvider.allCases.contains(.website))
        #expect(SourceProvider.allCases.contains(.zotero))
        #expect(SourceProvider.allCases.contains(.markdownFolder))
        #expect(SourceProvider.allCases.contains(.applePodcast))
        #expect(SourceProvider.allCases.contains(.podcast))
        #expect(SourceProvider.allCases.contains(.youtube))
        #expect(SourceProvider.allCases.contains(.vimeo))
        #expect(SourceProvider.allCases.contains(.spotify))
        #expect(SourceProvider.allCases.contains(.soundcloud))
        #expect(SourceProvider.allCases.contains(.remoteMedia))
        #expect(SourceProvider.allCases.contains(.legacyImport))
    }
}
