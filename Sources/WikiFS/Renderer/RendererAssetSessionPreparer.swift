import Foundation
import WikiFSCore
import WikiFSTypes

// pattern: Imperative Shell — explicit helper and store actor boundaries.

/// Immutable, Sendable helper-execution input. It contains no store handle.
struct RendererAssetHelperExecutionRequest: Sendable {
    let helperURL: URL?
    let extractorBytes: Data
    let entryFunction: String
    let primaryInput: Data
    let maximumExtractorInputBytes: Int
    let maximumExtractorOutputBytes: Int
    let maximumExtractorExecutionSeconds: Int
    let maximumReferenceCount: Int
    let stdoutLimit: Int
    let stderrLimit: Int
}

/// Immutable helper output crossing back to the main actor. It contains no
/// store-backed objects or readers.
struct RendererAssetHelperExecutionResult: Sendable, Equatable {
    let records: [RendererAssetReferenceExtractorClient.ExtractedRecord]
}

enum RendererAssetSessionPreparer {
    typealias HelperExecutor = @Sendable (RendererAssetHelperExecutionRequest) async throws -> RendererAssetHelperExecutionResult

    static func executeHelper(
        _ request: RendererAssetHelperExecutionRequest
    ) async throws -> RendererAssetHelperExecutionResult {
        try Task.checkCancellation()
        guard let helperURL = request.helperURL,
              RendererAssetExtractorHelperLocation.isExecutableFile(helperURL) else {
            return .init(records: [])
        }
        let outcome = try await RendererAssetReferenceExtractorClient.run(.init(
            helperURL: helperURL,
            extractorBytes: request.extractorBytes,
            entryFunction: request.entryFunction,
            primaryInput: request.primaryInput,
            maxExtractorInputBytes: request.maximumExtractorInputBytes,
            maxExtractorOutputBytes: request.maximumExtractorOutputBytes,
            maxReferenceCount: request.maximumReferenceCount,
            maxExecutionSeconds: request.maximumExtractorExecutionSeconds,
            stdoutLimit: request.stdoutLimit,
            stderrLimit: request.stderrLimit))
        try Task.checkCancellation()
        guard outcome.failureReason == nil else { return .init(records: []) }
        return .init(records: outcome.records)
    }

    /// Store-backed admission and session-reader construction. This operation
    /// is deliberately isolated from helper execution.
    @MainActor
    static func makeAssetReader(
        from result: RendererAssetHelperExecutionResult,
        siblingSources: [String: SourceID],
        store: any WikiStore,
        sourceExtensions: [SourceID: String],
        allowedRoles: Set<RendererAssetRole>,
        maximumBytesPerAsset: Int,
        maximumAggregateSessionBytes: Int,
        maximumPerRequestReadCount: Int
    ) -> RendererAuthorizedAssetReader? {
        guard result.records.isEmpty == false else { return nil }
        do {
            let admissions = try RendererAssetAdmissionProjection.buildAdmissions(
                records: result.records,
                siblingSourceMap: siblingSources,
                store: store,
                sourceExtensions: sourceExtensions,
                allowedRoles: allowedRoles,
                maximumBytesPerAsset: maximumBytesPerAsset)
            guard admissions.isEmpty == false else { return nil }
            return try RendererAuthorizedAssetReader(
                admissions: admissions,
                maximumBytesPerAsset: maximumBytesPerAsset,
                maximumAggregateSessionBytes: maximumAggregateSessionBytes,
                maximumPerRequestReadCount: maximumPerRequestReadCount,
                store: store)
        } catch {
            DebugLog.reader("Renderer asset admission failed closed; continuing without asset authority.")
            return nil
        }
    }
}
