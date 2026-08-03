import Foundation
import PDFKit
import WikiFSCore

/// PDFKit-based PDF document-title extraction for the **app** target only.
///
/// `import PDFKit` transitively links **AppKit** (and AVFoundation). The
/// read-only File Provider extension (`WikiFSFileProvider`) also links
/// `WikiFSCore`, so if `WikiFSCore` imported PDFKit the extension would pull
/// AppKit — which macOS 26 (`com.apple.fileprovider-nonui`) asserts against in
/// `_EXRunningExtension._start`, crashing the extension on launch.
///
/// To keep `WikiFSCore` (and thus the extension) free of PDFKit/AppKit, the PDF
/// extraction is **injectable** via `DisplayNameResolver.pdfTitleExtractor`.
/// Core's default is a `nil`-returning closure; the app installs this real
/// PDFKit implementation at launch (`WikiFSApp.init`). Every non-app context
/// (the extension, `wikictl`, tests by default) leaves the default and simply
/// falls through to the filename.
public enum PDFTitleExtractor {
    /// Extract the document title from a PDF via PDFKit's document attributes.
    /// Returns `nil` for non-PDF data, PDFs with no `/Title`, or an empty title.
    public static func extract(_ data: Data) -> String? {
        guard let document = PDFDocument(data: data),
              let attrs = document.documentAttributes,
              let title = attrs[PDFDocumentAttribute.titleAttribute] as? String
        else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension DisplayNameResolver {
    /// Install the app-only PDFKit title extractor into Core's injectable seam.
    /// Called once at launch from `WikiFSApp.init`. Non-app contexts never call
    /// this, so they keep the default `nil`-returning closure and stay free of
    /// PDFKit/AppKit.
    public static func installPDFTitleExtractor() {
        pdfTitleExtractor = PDFTitleExtractor.extract
    }
}
