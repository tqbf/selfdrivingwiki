#if os(macOS)
import Foundation
import WikiFSCore
import WikiFSTypes

// pattern: Functional Core

/// Failures the speech arm's host-side acquisition boundary raises. Fixed
/// redacted text: never a source URL, never package stderr, never media.
public enum AudioAcquireError: Error, Equatable, LocalizedError {
    /// The fetcher answered with a `markdown` result — an audio-acquire
    /// registration can never produce one.
    case notSourceBytesResult
    /// The `source-bytes` result named a MIME other than `audio/mp4` (or
    /// named none). The speech floor cannot identify the media.
    case wrongResultMIMEType

    public var errorDescription: String? {
        switch self {
        case .notSourceBytesResult:
            return "The audio acquisition did not return source bytes."
        case .wrongResultMIMEType:
            return "The audio acquisition returned an unexpected media type."
        }
    }
}

/// The speech arm's typed view over one acquisition fetcher. This is host
/// glue — NOT a second package resolver: the fetcher route, its reviewed
/// selection, and the process execution all stay in `ProcessPackageFetcher`.
/// This adapter only validates the fetcher's typed `source-bytes` outcome
/// against the speech contract (`audio/mp4`) before the host stages the
/// bytes for analysis, and records the exact fetcher identity for
/// provenance.
public struct AudioAcquireAdapter: Sendable, ProcessPackageProvenanceProviding {
    /// The only media MIME the speech arm accepts from the fetcher.
    public static let audioResultMIME = "audio/mp4"

    /// The synthetic source MIME the speech arm claims. The fetcher must
    /// declare this input — the check guards against a selection that
    /// drifted from the reviewed claims.
    public static var claimedMIMEType: ExtractorMIMEType? {
        ExtractorMIMEType(rawValue: MimeType.audioXWikiAudioAcquire)
    }

    public var displayName: String { fetcher.displayName }
    public var packageProvenance: ExtractorPackageExecutionProvenance {
        fetcher.packageProvenance
    }

    let fetcher: ProcessPackageFetcher

    /// Fails closed when the resolved fetcher does not claim the synthetic
    /// audio-acquire source MIME.
    public init(fetcher: ProcessPackageFetcher) throws {
        guard let claimed = Self.claimedMIMEType,
              fetcher.claimsInputMIMEType(claimed) else {
            throw ExtractionServicesError.selectedFetcherUnavailable(
                route: .canonicalAudioAcquire,
                reference: LogicalExtractorReference(
                    packageID: fetcher.packageProvenance.revision.packageID,
                    registrationID: fetcher.packageProvenance.registrationID))
        }
        self.fetcher = fetcher
    }

    /// The shared operation-level readiness answer (runtime resolution,
    /// entry-point presence).
    public func readiness() async -> ExtractionReadiness {
        await fetcher.readiness()
    }

    /// One outcome of one audio acquisition: the M4A bytes plus the
    /// package-reported metadata for provenance. The bytes live only in
    /// memory here — persistence is the speech stage's job, never a source
    /// blob.
    public struct AcquiredAudio: Sendable {
        public let bytes: Data
        public let reportedMetadata: ExtractorReportedMetadata
        /// The exact fetcher identity that acquired the audio (revision,
        /// registration, protocol revision).
        public let provenance: ExtractorPackageExecutionProvenance
    }

    /// Acquires the audio-only stream for `sourceURL` through the resolved
    /// fetcher. Progress lines are package-controlled text already redacted
    /// by the operation.
    public func acquireAudio(
        for sourceURL: URL,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> AcquiredAudio {
        guard let claimed = Self.claimedMIMEType else {
            throw ExtractionServicesError.unavailable
        }
        let outcome = try await fetcher.fetch(
            for: sourceURL,
            claimedMIMEType: claimed,
            displayFilename: "audio",
            onProgress: onProgress)
        let bytes = try Self.validatedAudioBytes(from: outcome)
        return AcquiredAudio(
            bytes: bytes.bytes,
            reportedMetadata: bytes.reportedMetadata,
            provenance: fetcher.packageProvenance)
    }

    /// The host-side validation edge for one fetch outcome. The prepared
    /// operation's protocol boundary (`ProcessPackageFetcher.interpretedOutcome`)
    /// already rejects size mismatches, missing result tags, empty bytes,
    /// and contradictory frames; this function adds the SPEECH contract on
    /// top: the result must be `source-bytes` declared as `audio/mp4`.
    /// Binary bytes pass through untouched — never decoded as text.
    public static func validatedAudioBytes(
        from outcome: ProcessPackageFetchOutcome
    ) throws -> ProcessPackageFetchSourceBytes {
        switch outcome {
        case .markdown:
            throw AudioAcquireError.notSourceBytesResult
        case .sourceBytes(let bytes):
            guard bytes.mimeType.rawValue == Self.audioResultMIME else {
                throw AudioAcquireError.wrongResultMIMEType
            }
            return bytes
        }
    }
}
#endif
