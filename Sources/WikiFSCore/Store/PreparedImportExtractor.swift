import Foundation

/// One typed import extractor for a package-claimed kind.
///
/// Import POLICY never branches on an extractor kind: the registration
/// claims and the wiring's derived kinds set decide WHICH kind converts at
/// import, and this enum carries the per-kind TYPED extractor that policy
/// resolved. The cases exist because the per-kind extractor protocols have
/// different operation shapes; they are the adapter seam, not a selection
/// mechanism.
public enum PreparedImportExtractor: Sendable {
    case docx(any DocxMarkdownExtractor)
}
