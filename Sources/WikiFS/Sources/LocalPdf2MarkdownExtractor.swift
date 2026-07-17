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
struct LocalPdf2MarkdownExtractor: MarkdownExtractor {
    let displayName = "Local pdf2md"

    func readiness() async -> ExtractionReadiness {
        if await PdfExtractionService.checkReady() {
            return .ready
        }
        return .notInstalled(
            "Local pdf2md dependencies aren't installed. Use the Download button for the one-time ~2 GB setup (docling, granite model, torch).")
    }

    func convert(
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
