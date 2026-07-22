import Foundation
import Testing
@testable import WikiFSCore

/// Unit tests for `YouTubeTranscriptService` — the subprocess-based
/// implementation. Tests the pure helpers (ID validation, filename/header
/// generation, error descriptions) and the result-mapping logic. The full
/// `mapResult` mapping suite is in `YouTubeTranscriptSubprocessTests`.
///
/// The old scrape-based tests (extractPlayerResponse, bestTrack, etc.) were
/// removed with the scrape code (#811 — replaced by the youtube-transcript
/// subprocess).
struct YouTubeTranscriptServiceTests {

    // MARK: - ID validation

    @Test func isValidVideoIDAcceptsValid() {
        #expect(YouTubeTranscriptService.isValidVideoID("dQw4w9WgXcQ"))
        #expect(YouTubeTranscriptService.isValidVideoID("abc_-ABC123"))
    }

    @Test func isValidVideoIDRejectsTooShort() {
        #expect(!YouTubeTranscriptService.isValidVideoID("tooshort"))
    }

    @Test func isValidVideoIDRejectsTooLong() {
        #expect(!YouTubeTranscriptService.isValidVideoID("tooLong1234567"))
    }

    @Test func isValidVideoIDRejectsSpecialChars() {
        #expect(!YouTubeTranscriptService.isValidVideoID("contains!bad"))
    }

    // MARK: - Filename / header

    @Test func filenameEscapesTitle() {
        let name = YouTubeTranscriptService.filename(for: "Great Talk / Part 1", videoID: "dQw4w9WgXcQ")
        #expect(name == "Great Talk - Part 1-dQw4w9WgXcQ-transcript.md")
    }

    @Test func headerContainsTitleAndLink() {
        let header = YouTubeTranscriptService.header(for: "My Video", videoID: "dQw4w9WgXcQ")
        #expect(header.contains("# My Video"))
        #expect(header.contains("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
    }

    // MARK: - Error descriptions

    @Test func errorDescriptionsAreReadable() {
        #expect(YouTubeTranscriptError.noCaptions.errorDescription == "This video has no captions.")
        #expect(YouTubeTranscriptError.badResponse(500).errorDescription == "YouTube returned HTTP 500.")
        #expect(YouTubeTranscriptError.playerResponseNotFound.errorDescription?.contains("restricted") == true)
    }

    @Test func newErrorDescriptionsAreReadable() {
        #expect(YouTubeTranscriptError.scriptNotFound.errorDescription?.contains("youtube-transcript") == true)
        #expect(YouTubeTranscriptError.emptyOutput.errorDescription?.contains("no output") == true)
        #expect(YouTubeTranscriptError.subprocessFailed(status: 2, message: "fail").errorDescription?.contains("2") == true)
    }

    // MARK: - Invalid video ID throws

    @Test func invalidVideoIDThrows() async {
        let service = YouTubeTranscriptService()
        do {
            _ = try await service.transcript(forVideoID: "tooshort")
            Issue.record("Should have thrown for an invalid video ID")
        } catch YouTubeTranscriptError.network {
            // Expected
        } catch {
            Issue.record("Threw unexpected error: \(error)")
        }
    }
}
