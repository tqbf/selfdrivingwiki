import Foundation
import Testing
@testable import WikiFSCore

/// Tests for the subprocess-based `YouTubeTranscriptService` — verifies the
/// pure result-mapping logic (exit code → `YouTubeTranscriptError`, JSON decode
/// → `YouTubeTranscript`) without spawning a real subprocess. Integration tests
/// that actually spawn the script are gated on `resolveScript()` presence.
///
/// Issue #811.
struct YouTubeTranscriptSubprocessTests {

    // MARK: - Exit code mapping

    @Test func mapResultExit0DecodesTranscript() throws {
        let json = """
        {
            "video_id": "dQw4w9WgXcQ",
            "language": "en",
            "segments": [],
            "markdown": "Hello world. Second cue."
        }
        """
        let result = (stdout: json, stderr: "", status: Int32(0))
        let transcript = try YouTubeTranscriptService.mapResult(result, videoID: "dQw4w9WgXcQ")

        #expect(transcript.videoID == "dQw4w9WgXcQ")
        #expect(transcript.title == "youtube-dQw4w9WgXcQ")
        #expect(transcript.markdown.contains("[Watch on YouTube](https://www.youtube.com/watch?v=dQw4w9WgXcQ)"))
        #expect(transcript.markdown.contains("Hello world. Second cue."))
        #expect(transcript.filename == "youtube-dQw4w9WgXcQ-dQw4w9WgXcQ-transcript.md")
    }

    @Test func mapResultExit2ThrowsNoCaptions() {
        let result = (stdout: "", stderr: "No transcript available", status: Int32(2))
        #expect(throws: YouTubeTranscriptError.noCaptions) {
            try YouTubeTranscriptService.mapResult(result, videoID: "dQw4w9WgXcQ")
        }
    }

    @Test func mapResultExit3ThrowsPlayerResponseNotFound() {
        let result = (stdout: "", stderr: "Transcripts disabled", status: Int32(3))
        #expect(throws: YouTubeTranscriptError.playerResponseNotFound) {
            try YouTubeTranscriptService.mapResult(result, videoID: "dQw4w9WgXcQ")
        }
    }

    @Test func mapResultExit4ThrowsPlayerResponseNotFound() {
        let result = (stdout: "", stderr: "Video unavailable", status: Int32(4))
        #expect(throws: YouTubeTranscriptError.playerResponseNotFound) {
            try YouTubeTranscriptService.mapResult(result, videoID: "dQw4w9WgXcQ")
        }
    }

    @Test func mapResultExit1ThrowsNetwork() {
        let result = (stdout: "", stderr: "Connection error", status: Int32(1))
        #expect(throws: YouTubeTranscriptError.network("Connection error")) {
            try YouTubeTranscriptService.mapResult(result, videoID: "dQw4w9WgXcQ")
        }
    }

    // MARK: - Edge cases

    @Test func mapResultEmptyOutputThrowsEmptyOutput() {
        let result = (stdout: "   \n  ", stderr: "", status: Int32(0))
        #expect(throws: YouTubeTranscriptError.emptyOutput) {
            try YouTubeTranscriptService.mapResult(result, videoID: "dQw4w9WgXcQ")
        }
    }

    @Test func mapResultInvalidJsonThrowsParseFailed() {
        let result = (stdout: "not json at all", stderr: "", status: Int32(0))
        #expect(throws: YouTubeTranscriptError.parseFailed) {
            try YouTubeTranscriptService.mapResult(result, videoID: "dQw4w9WgXcQ")
        }
    }

    @Test func mapResultMissingMarkdownUsesEmptyString() throws {
        let json = """
        {"video_id": "abc12345678", "language": "en"}
        """
        let result = (stdout: json, stderr: "", status: Int32(0))
        let transcript = try YouTubeTranscriptService.mapResult(result, videoID: "abc12345678")

        #expect(transcript.videoID == "abc12345678")
        // Header is still present even with empty body
        #expect(transcript.markdown.contains("[Watch on YouTube]"))
    }

    @Test func mapResultEmptyVideoIdFallsBackToInput() throws {
        let json = """
        {"video_id": "", "language": "en", "markdown": "text"}
        """
        let result = (stdout: json, stderr: "", status: Int32(0))
        let transcript = try YouTubeTranscriptService.mapResult(result, videoID: "dQw4w9WgXcQ")

        #expect(transcript.videoID == "dQw4w9WgXcQ")
    }

    // MARK: - Helpers

    @Test func isValidVideoIDAcceptsValid() {
        #expect(YouTubeTranscriptService.isValidVideoID("dQw4w9WgXcQ"))
        #expect(YouTubeTranscriptService.isValidVideoID("abc_-ABC123"))
    }

    @Test func isValidVideoIDRejectsInvalid() {
        #expect(!YouTubeTranscriptService.isValidVideoID("short"))
        #expect(!YouTubeTranscriptService.isValidVideoID("tooLong1234567"))
        #expect(!YouTubeTranscriptService.isValidVideoID("special!@#"))
    }

    @Test func headerContainsTitleAndLink() {
        let header = YouTubeTranscriptService.header(for: "My Talk", videoID: "dQw4w9WgXcQ")
        #expect(header.contains("# My Talk"))
        #expect(header.contains("[Watch on YouTube](https://www.youtube.com/watch?v=dQw4w9WgXcQ)"))
    }

    @Test func filenameHasCorrectShape() {
        let name = YouTubeTranscriptService.filename(for: "My Talk", videoID: "dQw4w9WgXcQ")
        // FilenameEscaping escapes slashes but preserves spaces
        #expect(name == "My Talk-dQw4w9WgXcQ-transcript.md")
    }

    // MARK: - Script resolution (integration — no assertion on found/nil)

    @Test func resolveScriptDoesNotCrash() {
        // May or may not find the script depending on the build environment.
        // Just verify it doesn't crash.
        _ = YouTubeTranscriptService.resolveScript()
    }
}
