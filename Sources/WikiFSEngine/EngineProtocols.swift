import Foundation
import WikiFSCore

/// Abstraction over the File Provider's change-signaling and mount-path surface.
///
/// The engine (`AgentOperationRunner`, `AgentLauncher`) uses this to signal FP
/// changes and read the mount path without depending on the AppKit-coupled
/// `FileProviderSpike` (which stays in the app target). The app conforms
/// `FileProviderSpike` to this protocol at wiring time.
///
/// See `plans/multi-wiki-daemon.md` §3.2 (the `ChangeSignaler` protocol seam).
@MainActor
public protocol ChangeSignaler: AnyObject {
    /// Signal the File Provider that content changed (debounced).
    func signalChange() async

    /// The mount path for the active wiki's File Provider domain, if mounted.
    var path: String? { get }
}

/// Default `MarkdownExtractor` used when no concrete local pdf2md extractor is
/// available (tests, daemon). Reports `.notInstalled` — `current()` returns it
/// when the configured backend is `.localPdf2md` but the app hasn't injected the
/// real `LocalPdf2MarkdownExtractor` factory. The app overrides this at wiring time.
public struct UnavailablePdf2MarkdownExtractor: MarkdownExtractor {
    public let displayName = "Local pdf2md (unavailable)"

    public init() {}

    public func readiness() async -> ExtractionReadiness {
        .notInstalled("Local pdf2md is not available in this process.")
    }

    public func convert(
        pdfData: Data,
        filename: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> String {
        throw NSError(domain: "WikiFSEngine", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Local pdf2md is not available in this process."])
    }
}
