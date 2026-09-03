import Foundation
import WikiFSCore
import WikiFSTypes

// pattern: Imperative Shell — prepares the per-session asset admission.

/// Prepares the session asset reader for an installed renderer that declares
/// revision-5 `assetRead` authority.
///
/// Flow:
/// 1. Run the hash-approved reference-extractor helper against the pinned
///    primary input bytes, bounded by the descriptor's declared limits
///    (deadline, stdout/stderr caps, reference count).
/// 2. Resolve the extracted records against the EXACT sibling/File Provider
///    projection supplied by the caller (never broadened to all sources),
///    pinning each to SourceID + SourceVersionID + MIME + size + digest.
/// 3. Build the immutable `RendererAuthorizedAssetReader` for the session.
///
/// Any failure — missing helper, timeout, malformed output, undeclared role,
/// unresolved/ambiguous reference, budget — fails closed to `nil` (zero
/// admitted assets) while preserving normal non-image rendering and
/// source/raw fallback.
public enum RendererAssetSessionPreparer {
    public static func makeAssetReader(
        helperURL: URL?,
        extractorBytes: Data,
        entryFunction: String,
        primaryInput: Data,
        maxExtractorInputBytes: Int,
        maxExtractorOutputBytes: Int,
        maxExtractorExecutionSeconds: Int,
        maxReferenceCount: Int,
        stdoutLimit: Int,
        stderrLimit: Int,
        siblingSources: [String: SourceID],
        store: any WikiStore,
        sourceExtensions: [SourceID: String],
        allowedRoles: Set<RendererAssetRole>,
        maximumBytesPerAsset: Int,
        maximumAggregateSessionBytes: Int,
        maximumPerRequestReadCount: Int
    ) async -> RendererAuthorizedAssetReader? {
        guard let helperURL, RendererAssetExtractorHelperLocation.isExecutableFile(helperURL) else {
            DebugLog.reader("Renderer asset session skipped: no reference-extractor helper.")
            return nil
        }
        let request = RendererAssetReferenceExtractorClient.Request(
            helperURL: helperURL,
            extractorBytes: extractorBytes,
            entryFunction: entryFunction,
            primaryInput: primaryInput,
            maxExtractorInputBytes: maxExtractorInputBytes,
            maxExtractorOutputBytes: maxExtractorOutputBytes,
            maxReferenceCount: maxReferenceCount,
            maxExecutionSeconds: maxExtractorExecutionSeconds,
            stdoutLimit: stdoutLimit,
            stderrLimit: stderrLimit)
        let outcome: RendererAssetReferenceExtractorClient.Outcome
        do {
            outcome = try await RendererAssetReferenceExtractorClient.run(request)
        } catch {
            DebugLog.reader("Renderer asset session failed closed: extractor helper error.")
            return nil
        }
        guard outcome.failureReason == nil else {
            DebugLog.reader("Renderer asset session failed closed: \(outcome.failureReason ?? "extraction failed")")
            return nil
        }
        let admissions: [RendererAuthorizedAssetReader.Admission]
        do {
            admissions = try RendererAssetAdmissionProjection.buildAdmissions(
                records: outcome.records,
                siblingSourceMap: siblingSources,
                store: store,
                sourceExtensions: sourceExtensions,
                allowedRoles: allowedRoles,
                maximumBytesPerAsset: maximumBytesPerAsset)
        } catch {
            DebugLog.reader("Renderer asset session failed closed: admission resolution failed.")
            return nil
        }
        guard admissions.isEmpty == false else { return nil }
        do {
            return try RendererAuthorizedAssetReader(
                admissions: admissions,
                maximumBytesPerAsset: maximumBytesPerAsset,
                maximumAggregateSessionBytes: maximumAggregateSessionBytes,
                maximumPerRequestReadCount: maximumPerRequestReadCount,
                store: store)
        } catch {
            DebugLog.reader("Renderer asset session failed closed: reader construction failed.")
            return nil
        }
    }
}
