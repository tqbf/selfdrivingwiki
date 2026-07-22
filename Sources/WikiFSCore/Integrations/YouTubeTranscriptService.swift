import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(AppKit)
import AppKit
#endif

/// The finished transcript for a YouTube video: video ID, markdown text, and a
/// suggested source filename. Mirrors `PodcastTranscript`.
public struct YouTubeTranscript: Equatable, Sendable {
    public let videoID: String
    public let title: String
    public let markdown: String
    public let filename: String

    public init(videoID: String, title: String, markdown: String, filename: String) {
        self.videoID = videoID
        self.title = title
        self.markdown = markdown
        self.filename = filename
    }
}

/// The one thing ingest calls: video ID → transcript. Injected so `WikiStoreModel`
/// (Add from URL) and tests can substitute a fake. Mirrors
/// `PodcastTranscriptFetching`.
public protocol YouTubeTranscriptFetching: Sendable {
    func transcript(forVideoID videoID: String) async throws -> YouTubeTranscript
}

/// Errors for the YouTube video → transcript pipeline, user-readable so the
/// Add-from-URL sheet can surface them directly. Mirrors
/// `PodcastTranscriptError`.
public enum YouTubeTranscriptError: Error, LocalizedError, Equatable {
    /// The video page or caption download returned a non-2xx status.
    case badResponse(Int)
    /// `ytInitialPlayerResponse` wasn't found in the watch page HTML (YouTube
    /// changed the page, or the video is age/restricted/region-locked).
    case playerResponseNotFound
    /// The video has no caption tracks at all.
    case noCaptions
    /// The caption bytes didn't parse into any cues.
    case parseFailed
    /// A network or transport failure carrying the underlying message.
    case network(String)
    /// The youtube-transcript script wasn't found at any candidate location.
    case scriptNotFound
    /// The subprocess failed to launch.
    case processFailed(String)
    /// The subprocess returned empty output.
    case emptyOutput
    /// The subprocess returned a non-zero exit status.
    case subprocessFailed(status: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .badResponse(let code):
            return "YouTube returned HTTP \(code)."
        case .playerResponseNotFound:
            return "Couldn't read this video's data (YouTube page changed or the video is restricted)."
        case .noCaptions:
            return "This video has no captions."
        case .parseFailed:
            return "The video's captions couldn't be parsed."
        case .network(let msg):
            return msg
        case .scriptNotFound:
            return "The youtube-transcript script isn't available in this build."
        case .processFailed(let msg):
            return "Failed to launch youtube-transcript: \(msg)"
        case .emptyOutput:
            return "The youtube-transcript script produced no output."
        case .subprocessFailed(let status, let message):
            return "youtube-transcript exited \(status)\(message.isEmpty ? "" : ": \(message)")"
        }
    }
}

/// Fetches a YouTube transcript by spawning the `youtube-transcript` PEP 723
/// script (`tools/youtube-transcript/youtube-transcript`), which uses the
/// `youtube-transcript-api` Python library — no watch-page HTML scraping.
///
/// The script shares the `env -S uv run --script` shebang with `pdf2md` and is
/// spawned via `TranscriptSubprocess.run()` (mirrors `PdfExtractionService`).
/// The script accepts a video ID or URL as argv[1] and emits structured JSON
/// with `--json`: `{video_id, language, segments, markdown}`.
///
/// Exit codes are mapped to `YouTubeTranscriptError`:
///   0 → success, 2 → `.noCaptions`, 3 → `.playerResponseNotFound`,
///   4 → `.playerResponseNotFound`, 1/other → `.network(stderr)`.
///
/// Issue #811.
public struct YouTubeTranscriptService: YouTubeTranscriptFetching {

    /// The decoded JSON the `youtube-transcript --json` script emits.
    struct ScriptOutput: Decodable {
        let video_id: String
        let language: String?
        let markdown: String?
    }

    public init() {}

    /// Legacy initializer accepting a `URLResourceFetcher` — kept for source
    /// compatibility with existing call sites. The fetcher is unused in the
    /// subprocess path; the script handles all HTTP internally.
    @available(*, deprecated, message: "The fetcher is unused; YouTubeTranscriptService now spawns a subprocess. Use init().")
    public init(fetcher: any URLFetchService.URLResourceFetcher) {
        self.init()
    }

    public func transcript(forVideoID videoID: String) async throws -> YouTubeTranscript {
        guard Self.isValidVideoID(videoID) else {
            throw YouTubeTranscriptError.network("\"\(videoID)\" isn't a valid YouTube video ID.")
        }

        guard let script = Self.resolveScript() else {
            DebugLog.extraction("[youtube] transcript: script not found")
            throw YouTubeTranscriptError.scriptNotFound
        }

        DebugLog.extraction("[youtube] transcript: spawning \(script.path) for \(videoID)")

        do {
            let result = try await TranscriptSubprocess.run(
                script: script,
                arguments: [videoID, "--json"]
            )

            return try Self.mapResult(result, videoID: videoID)
        } catch let error as TranscriptSubprocessError {
            DebugLog.extraction("[youtube] transcript: subprocess error: \(error.localizedDescription)")
            switch error {
            case .processFailed(let msg):
                throw YouTubeTranscriptError.processFailed(msg)
            default:
                throw YouTubeTranscriptError.network(error.localizedDescription)
            }
        }
    }

    // MARK: - Result mapping

    /// Map the subprocess result to a `YouTubeTranscript` or throw the
    /// appropriate `YouTubeTranscriptError`. Pure — extracted for testability.
    static func mapResult(
        _ result: (stdout: String, stderr: String, status: Int32),
        videoID: String
    ) throws -> YouTubeTranscript {
        switch result.status {
        case 0:
            break
        case 2:
            throw YouTubeTranscriptError.noCaptions
        case 3:
            throw YouTubeTranscriptError.playerResponseNotFound
        case 4:
            throw YouTubeTranscriptError.playerResponseNotFound
        default:
            throw YouTubeTranscriptError.network(
                result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw YouTubeTranscriptError.emptyOutput
        }

        let output: ScriptOutput
        do {
            output = try JSONDecoder().decode(ScriptOutput.self, from: Data(trimmed.utf8))
        } catch {
            DebugLog.extraction("[youtube] transcript: JSON decode failed: \(error)")
            throw YouTubeTranscriptError.parseFailed
        }

        let resolvedID = output.video_id.isEmpty ? videoID : output.video_id
        let title = "youtube-\(resolvedID)"
        let body = output.markdown ?? ""
        let markdown = Self.header(for: title, videoID: resolvedID) + body

        return YouTubeTranscript(
            videoID: resolvedID,
            title: title,
            markdown: markdown,
            filename: Self.filename(for: title, videoID: resolvedID))
    }

    // MARK: - Script resolution

    /// Resolve the `youtube-transcript` script. Mirrors
    /// `PdfExtractionService.resolveScript()`: bundled Helpers → dev build →
    /// executable dir → repo `tools/youtube-transcript/`.
    static func resolveScript() -> URL? {
        TranscriptSubprocess.resolveScript(
            named: "youtube-transcript",
            repoSubdir: "tools/youtube-transcript")
    }

    // MARK: - Filename / header

    /// `<escaped-title>-<videoId>-transcript.md`, mirroring the podcast
    /// convention (`<slug>-<id>-transcript.md`).
    static func filename(for title: String, videoID: String) -> String {
        let stem = "\(FilenameEscaping.escapeTitle(title))-\(videoID)"
        return "\(stem)-transcript.md"
    }

    /// A small markdown header for the transcript source — the video title + a
    /// YouTube link, so the rendered reader shows context above the transcript.
    static func header(for title: String, videoID: String) -> String {
        let escaped = FilenameEscaping.escapeTitle(title)
        return "# \(escaped)\n\n[Watch on YouTube](https://www.youtube.com/watch?v=\(videoID))\n\n"
    }

    /// YouTube video IDs are exactly 11 chars from `[A-Za-z0-9_-]`.
    static func isValidVideoID(_ id: String) -> Bool {
        id.count == 11 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }
}
