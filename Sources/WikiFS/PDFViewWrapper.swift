import PDFKit
import SwiftUI

/// Wraps AppKit's `PDFView` for inline PDF preview in a SwiftUI view.
/// Loads from raw `Data` (verbatim source bytes from SQLite), not a file URL.
struct PDFViewWrapper: NSViewRepresentable {
    let data: Data

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
        if let document = PDFDocument(data: data) {
            nsView.document = document
        }
    }
}
