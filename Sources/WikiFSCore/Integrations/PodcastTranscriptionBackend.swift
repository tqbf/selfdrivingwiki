import Foundation

/// A Podcast→transcript backend — the user's chosen engine for fetching a
/// transcript of an Apple Podcasts episode. Persisted in
/// `extraction-config.json` as `ExtractionConfig.podcastBackend` (issue #799:
/// no auto-transcription at ingest — the user picks a backend and triggers
/// transcription explicitly).
///
/// Mirrors `ExtractionBackend` (PDF) and `HtmlExtractionBackend` (HTML) for
/// parity, but is intentionally a **separate** type — podcast transcription is
/// architecturally different from the other two (PR4 detail):
///
/// - **Not bytes→markdown**: the transcript comes from Apple's network API
///   (signed bearer token → AMP metadata → TTML download → parse). There are no
///   stored bytes to convert; the "backend" picks the network pipeline, not a
///   converter. The trigger is therefore a separate code path, NOT through
///   the PDF-coupled queue engine (`ExtractionResolution.pdfData` etc.).
/// - **Behind `#if PODCAST_TRANSCRIPTS`**: the signing helper
///   (`HelperPodcastTokenProvider`, shells out to `podcast-token-helper`) may
///   not be present in app-store builds. The enum itself is unconditional
///   (PR1 only adds the typed config field + Settings picker — no behavior
///   change); the actual transcription behind it is gated, and the Transcribe
///   button is disabled when the helper is unavailable (PR4).
///
/// `nil` (no backend chosen yet) is a valid state, mirroring
/// `htmlBackend`: a fresh install decodes `podcastBackend` as nil and the UI
/// prompts the user to pick one before the first transcription. Currently only
/// `appleTranscript` exists, but the enum is extensible — Whisper / Rev.ai / etc.
/// backends will be added as future PRs.
public enum PodcastTranscriptionBackend: String, CaseIterable, Sendable, Codable {
    /// Apple Podcasts' native transcript pipeline (signed bearer token → AMP
    /// metadata → TTML download → parse → markdown). The only option today;
    /// behind `#if PODCAST_TRANSCRIPTS` at the call site (PR4).
    case appleTranscript

    /// A short label for the Settings picker and the Transcribe menu.
    public var displayName: String {
        switch self {
        case .appleTranscript: return "Apple Podcasts transcript"
        }
    }
}
