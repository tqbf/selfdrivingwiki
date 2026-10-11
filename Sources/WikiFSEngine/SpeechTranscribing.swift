#if os(macOS)
import Foundation

// pattern: Functional Core

/// The setup guidance a speech readiness probe reports. Typed so the UI can
/// offer exactly one next step — never a raw error string.
public enum SpeechSetupGuidance: Error, Sendable, Equatable {
    /// On-device speech is not available on this machine (hardware/OS).
    case speechUnavailable
    /// The requested locale is not supported by the on-device engine.
    case localeUnsupported
    /// The locale is supported but its model assets are not installed.
    /// Installing is a separate, explicit, user-confirmed action.
    case assetsNotInstalled
    /// The engine is present but refused to start (rare; a signed-app
    /// diagnostic). `detail` is a fixed redacted string.
    case engineSetupFailed

    /// The fixed, user-facing message. Never upstream error text.
    public var message: String {
        switch self {
        case .speechUnavailable:
            return "On-device speech transcription is not available on this Mac."
        case .localeUnsupported:
            return "This language is not supported by on-device speech transcription."
        case .assetsNotInstalled:
            return "The speech model for this language is not installed yet."
        case .engineSetupFailed:
            return "The on-device speech engine could not start."
        }
    }
}

/// The readiness answer for one speech request.
public enum SpeechReadiness: Sendable, Equatable {
    case ready
    case needsSetup(SpeechSetupGuidance)
}

/// One completed on-device transcription: the transcript text plus the
/// honest engine facts provenance persists.
public struct SpeechTranscription: Sendable, Equatable {
    /// The transcript text. Bounded by the engine's own limits; never
    /// includes timing markup.
    public let text: String
    /// The engine identifier (e.g. `speechanalyzer`).
    public let engine: String
    /// The locale identifier the transcription ran with (BCP 47).
    public let localeID: String
    /// The analyzed audio duration in seconds, when the engine reports it.
    public let durationSeconds: Double?

    public init(
        text: String,
        engine: String,
        localeID: String,
        durationSeconds: Double?
    ) {
        self.text = text
        self.engine = engine
        self.localeID = localeID
        self.durationSeconds = durationSeconds
    }
}

/// Errors the speech floor raises. Fixed redacted messages — never upstream
/// error text, never audio content.
public enum SpeechTranscriptionError: Error, Equatable, LocalizedError {
    /// The transcript exceeded the host bound.
    case transcriptTooLong
    /// The engine finished with no speech content.
    case emptyTranscription
    /// The analysis deadline passed.
    case deadlineExceeded
    /// The staged audio could not be opened as a decodable audio file.
    case unreadableAudio
    /// The engine returned no locale identity.
    case missingLocale

    public var errorDescription: String? {
        switch self {
        case .transcriptTooLong:
            return "The transcription exceeded the supported length."
        case .emptyTranscription:
            return "No speech was detected in this audio."
        case .deadlineExceeded:
            return "The transcription ran out of time."
        case .unreadableAudio:
            return "The downloaded audio could not be analyzed."
        case .missingLocale:
            return "The speech engine reported no language for this transcription."
        }
    }
}

/// The injectable on-device speech engine seam. One implementation talks to
/// the system speech analyzer; tests inject a scripted engine so the queue
/// pipeline stays deterministic.
public protocol SpeechTranscribing: Sendable {
    /// The readiness answer for one locale (BCP 47 identifier). Never
    /// launches asset installation and never prompts.
    func readiness(localeID: String) async -> SpeechReadiness

    /// Transcribes one audio file. The file is HOST-OWNED (the private
    /// analysis stage); implementations must not copy, move, or retain the
    /// path beyond the call. Progress reports 0...1. Cancellation must
    /// stop the engine and remove partial work.
    func transcribeFile(
        at audioURL: URL,
        localeID: String,
        deadline: ContinuousClock.Instant,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> SpeechTranscription

    /// The missing-model asset installation for one locale. Called ONLY
    /// from the explicit user-confirmed setup action — never from import,
    /// viewing, or a queue item. Progress reports 0...1.
    func installMissingAssets(
        localeID: String,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws
}

public enum SpeechTranscribers {
    /// The engine identifier provenance records for the system speech
    /// implementation.
    public static let systemEngineIdentifier = "speechanalyzer"
    /// The transcript bound: comfortably above any spoken two-hour audio,
    /// hard enough to bound memory.
    public static let maximumTranscriptCharacters = 2_000_000
}

/// Named policy bounds for one explicit speech job.
public enum SpeechExtractionPolicy {
    /// The on-device analysis deadline for one staged audio file (a 2-hour
    /// maximum-duration video). The acquisition carries its own manifest
    /// deadline; this bounds the HOST analysis phase only.
    public static let analysisDeadline: Duration = .seconds(45 * 60)
}
#endif
