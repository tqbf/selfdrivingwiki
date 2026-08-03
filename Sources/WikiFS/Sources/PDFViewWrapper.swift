import PDFKit
import SwiftUI

/// Wraps AppKit's `PDFView` for inline PDF preview in a SwiftUI view.
/// Loads from raw `Data` (verbatim source bytes from SQLite), not a file URL.
///
/// When `highlightQuote` is non-nil and the document is loaded, the view runs
/// `PDFDocument.findString` (case-insensitive) and sets the first match as
/// `currentSelection` — PDFKit renders the selection as its native highlight
/// — then scrolls it into view.
struct PDFViewWrapper: NSViewRepresentable {
    let data: Data
    var highlightQuote: String? = nil

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.backgroundColor = .textBackgroundColor
        if let document = PDFDocument(data: data) {
            view.document = document
        }
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        // Reload document when data changes.
        if let document = PDFDocument(data: data) {
            nsView.document = document
        }

        // Search + select when a highlight quote is set and the document is loaded.
        if let q = highlightQuote?.trimmingCharacters(in: .whitespacesAndNewlines),
           !q.isEmpty,
           let doc = nsView.document {
            let sel = doc.findString(q, withOptions: .caseInsensitive)
            // Only re-search when the quote changes (avoid repeat work on every
            // SwiftUI update pass).
            let lastSearched = context.coordinator.lastSearchedQuote
            if q != lastSearched, let first = sel.first {
                context.coordinator.lastSearchedQuote = q
                nsView.currentSelection = first
                nsView.scrollSelectionToVisible(nil)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var lastSearchedQuote: String?
    }
}
