import Foundation
import WikiFSCore

/// The local pdf2md backend as a `MarkdownExtractor`.
///
/// `PdfExtractionService` itself is a caseless `@MainActor enum` used as a
/// namespace of static subprocess methods, so it can't be an instance conformer.
/// This thin non-isolated value type is the conformer: it delegates to those
/// statics (awaiting across the main-actor boundary, which is allowed for async)
/// and carries the `displayName`. The `MarkdownExtractor` protocol is PID-free,
/// so the subprocess PID the static `convert` reports via `onStart` is funneled
/// through `onProgress`. The ingest-path download UI keeps using
/// `PdfExtractionService.preDownload` directly.
///
/// Moved from the app target (`Sources/WikiFS/`) to `WikiFSEngine` so the
/// `wikid` daemon can use the same local pdf2md extractor — it only depends on
/// Foundation + WikiFSCore (PdfExtractionService is now also in WikiFSEngine).
public struct LocalPdf2MarkdownExtractor: MarkdownExtractor {
    public let displayName = "Local pdf2md"

    public init() {}

    public func readiness() async -> ExtractionReadiness {
        if await PdfExtractionService.checkReady() {
            return .ready
        }
        return .notInstalled(
            "Local pdf2md dependencies aren't installed. Use the Download button for the one-time ~2 GB setup (docling, granite model, torch).")
    }

    public func convert(
        pdfData: Data,
        filename: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> String {
        try await PdfExtractionService.convert(
            pdfData: pdfData,
            filename: filename,
            onProgress: onProgress,
            onStart: { pid in onProgress?("Started pdf2md (pid \(pid)).\n") })
    }
}
