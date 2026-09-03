#if os(macOS)
import Foundation
import SwiftUI
import WikiFSCore
import WikiFSTypes

// pattern: Imperative Shell

/// App-target factory registry for the native renderer views.
///
/// SourceDetailView supplies source facts through `BuiltInRendererFactoryInputs`.
/// This closed map owns the renderer-specific view construction, so the detail
/// surface never switches on a file format to select a renderer.
@MainActor
enum BuiltInRendererFactoryMap {
    typealias Factory = @MainActor (BuiltInRendererFactoryInputs) -> AnyView?

    static let factories: [BuiltInRendererID: Factory] = [
        .pdf: makePDF,
        .html: makeHTML,
        .media: makeMedia,
    ]

    static func factory(for id: BuiltInRendererID) -> Factory? {
        factories[id]
    }

    static func makeView(
        for descriptor: RendererDescriptor,
        inputs: BuiltInRendererFactoryInputs
    ) -> AnyView? {
        guard case let .builtIn(id) = descriptor.implementation,
              let factory = factory(for: id)
        else { return nil }
        return factory(inputs)
    }

    private static func makePDF(_ inputs: BuiltInRendererFactoryInputs) -> AnyView? {
        AnyView(Group {
            if let data = inputs.sourceBytes {
                PDFViewWrapper(data: data, highlightQuote: inputs.pdfQuote)
            } else {
                ContentUnavailableView {
                    Label("Cannot Load PDF", systemImage: "doc.richtext")
                } description: {
                    Text("The source bytes for this file could not be read.")
                }
            }
        })
    }

    private static func makeHTML(_ inputs: BuiltInRendererFactoryInputs) -> AnyView? {
        AnyView(Group {
            if let html = inputs.htmlSource {
                HTMLSourceWebView(html: html)
            } else {
                ContentUnavailableView {
                    Label("Cannot Load HTML", systemImage: "globe")
                } description: {
                    Text("The source bytes for this file could not be read or decoded as HTML.")
                }
            }
        })
    }

    private static func makeMedia(_ inputs: BuiltInRendererFactoryInputs) -> AnyView? {
        AnyView(Group {
            if let target = inputs.mediaTarget {
                MediaEmbedPlayerView(target: target)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(PageEditorMetrics.contentInset)
            } else {
                ContentUnavailableView {
                    Label("Player Unavailable", systemImage: "play.slash")
                } description: {
                    Text("This media source's embed could not be resolved.")
                }
            }
        })
    }
}

/// Renderer inputs assembled at the SourceDetailView boundary.
struct BuiltInRendererFactoryInputs {
    let sourceBytes: Data?
    let pdfQuote: String?
    let htmlSource: String?
    let mediaTarget: EmbedTarget?

    init(
        sourceBytes: Data?,
        pdfQuote: String?,
        htmlSource: String?,
        mediaTarget: EmbedTarget?
    ) {
        self.sourceBytes = sourceBytes
        self.pdfQuote = pdfQuote
        self.htmlSource = htmlSource
        self.mediaTarget = mediaTarget
    }
}
#endif
