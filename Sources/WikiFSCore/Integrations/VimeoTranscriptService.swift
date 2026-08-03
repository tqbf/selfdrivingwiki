import Foundation

/// Transcript extraction for Vimeo videos.
///
/// **Status: stubbed — NOT implemented.** Vimeo's transcripts API
/// (`GET https://api.vimeo.com/videos/{id}/transcripts`) requires an OAuth2
/// token, so extracting captions needs a Keychain credential like Zotero/ACP.
/// This file defines the interface so a future PR can fill in the fetch +
/// parse without touching the ingest plumbing in `WikiStoreModel.addURL`.
///
/// Issue #564 (Phase 4 follow-up): implement once the Vimeo API token is wired
/// through Keychain. The HTTP flow will mirror `YouTubeTranscriptService`:
///   1. Resolve the Vimeo token from Keychain (`KeychainCredentialStore`).
///   2. `GET /videos/{id}/transcripts` with `Authorization: Bearer <token>`.
///   3. Download the transcript resource (URN → a VTT/SRT URL).
///   4. Parse with `TimedTextTranscript` → markdown.

public protocol VimeoTranscriptFetching: Sendable {
    func transcript(forVideoID videoID: String) async throws -> VimeoTranscript
}

public struct VimeoTranscript: Equatable, Sendable {
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

public enum VimeoTranscriptError: Error, LocalizedError, Equatable {
    /// The Vimeo API token isn't configured. User-facing so the Add-from-URL
    /// sheet can tell the user to add it in Settings → Extraction.
    case tokenMissing
    case notImplemented
    case noTranscript
    case badResponse(Int)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .tokenMissing:
            return "Add a Vimeo API token in Settings → Extraction to extract transcripts."
        case .notImplemented:
            return "Vimeo transcript extraction isn't available yet."
        case .noTranscript:
            return "This video has no transcripts."
        case .badResponse(let code):
            return "Vimeo returned HTTP \(code)."
        case .network(let msg):
            return msg
        }
    }
}

/// Placeholder service: conforms to the fetching protocol but throws
/// `.notImplemented`. Kept so the integration point (distinguish YouTube from
/// Vimeo, call the matching fetcher) compiles today and can be filled in
/// without restructuring `addURL`.
public struct VimeoTranscriptService: VimeoTranscriptFetching {
    public init() {}

    public func transcript(forVideoID videoID: String) async throws -> VimeoTranscript {
        throw VimeoTranscriptError.notImplemented
    }
}
