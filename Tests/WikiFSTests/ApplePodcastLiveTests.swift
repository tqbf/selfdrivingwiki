#if PODCAST_TRANSCRIPTS  // Feature off for WIKIFS_APP_STORE=1 builds.
import Foundation
import Testing
@testable import WikiFSCore

/// LIVE integration test for the full Apple Podcasts transcript pipeline — hits
/// Apple's real endpoints AND runs the private-framework signing helper, so it is
/// gated behind `WIKIFS_LIVE_PODCAST_TESTS=1` (macOS only, needs the built
/// `podcast-token-helper` beside the test binary). Run with:
///
///     WIKIFS_LIVE_PODCAST_TESTS=1 swift test --filter ApplePodcastLiveTests
///
/// The subject is the feature's driving example — the ChinaTalk episode.
struct ApplePodcastLiveTests {

    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["WIKIFS_LIVE_PODCAST_TESTS"] == "1"
    }

    @Test(.enabled(if: enabled))
    func fetchesChinaTalkTranscriptEndToEnd() async throws {
        let ref = try #require(PodcastEpisodeURL.parse(
            "https://podcasts.apple.com/us/podcast/chinatalk/id1289062927?i=1000774368453"))

        // The test runs inside WikiFSPackageTests.xctest, so the helper isn't a
        // sibling of the test binary — walk up the build tree to the
        // `.build/debug/podcast-token-helper` product (build it first with
        // `swift build --product podcast-token-helper`).
        let helper = try #require(
            Self.locateHelper(), "podcast-token-helper not built (run swift build --product podcast-token-helper)")
        let service = ApplePodcastTranscriptService(helperURL: helper)

        let transcript = try await service.transcript(for: ref)

        #expect(transcript.episodeID == "1000774368453")
        #expect(transcript.filename == "chinatalk-1000774368453-transcript.md")
        // The real transcript is long prose — sanity-check it decoded to real words
        // with spaces (the word-span joining), not a run-on blob.
        #expect(transcript.markdown.count > 1000)
        #expect(transcript.markdown.contains(" "))
    }

    /// Walk up from the test binary looking for a sibling `debug`/`release` build
    /// dir that contains `podcast-token-helper`.
    private static func locateHelper() -> URL? {
        let name = "podcast-token-helper"
        let fm = FileManager.default
        // `swift test` runs from the package root — the built helper is under
        // `.build/<triple>/{debug,release}/podcast-token-helper`.
        let buildRoot = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".build")
        guard let walker = fm.enumerator(at: buildRoot, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let url as URL in walker where url.lastPathComponent == name {
            if fm.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
}
#endif
