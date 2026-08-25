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
        .svg: makeSVG,
        .mermaid: makeMermaid,
        .media: makeMedia,
        .jsonCanvas: makeJSONCanvas,
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

    private static func makeSVG(_ inputs: BuiltInRendererFactoryInputs) -> AnyView? {
        guard let bytes = inputs.sourceBytes, bytes.isEmpty == false else { return nil }
        return AnyView(SVGRendererView(bytes: bytes))
    }

    private static func makeMermaid(_ inputs: BuiltInRendererFactoryInputs) -> AnyView? {
        AnyView(Group {
            if let source = inputs.mermaidDiagramSource {
                MermaidRendererView(source: source)
            } else if let mermaidProjection = inputs.mermaidProjection {
                mermaidProjection
            } else {
                ContentUnavailableView {
                    Label("No Diagram", systemImage: "flowchart.fill")
                } description: {
                    Text("This source has no Mermaid diagram to render yet.")
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

    private static func makeJSONCanvas(_ inputs: BuiltInRendererFactoryInputs) -> AnyView? {
        do {
            let document = try JSONCanvasDocument.decode(inputs.sourceBytes)
            return AnyView(JSONCanvasRendererView(
                document: document,
                onHostAction: inputs.jsonCanvasHostAction))
        } catch {
            DebugLog.tabs("BuiltInRendererFactoryMap: JSON Canvas decode failed: \(error)")
            return nil
        }
    }
}

/// Renderer inputs assembled at the SourceDetailView boundary.
struct BuiltInRendererFactoryInputs {
    let sourceBytes: Data?
    let pdfQuote: String?
    let htmlSource: String?
    let mermaidProjection: AnyView?
    let mermaidDiagramSource: String?
    let mediaTarget: EmbedTarget?
    let jsonCanvasHostAction: @MainActor @Sendable (JSONCanvasHostAction) -> Void

    init(
        sourceBytes: Data?,
        pdfQuote: String?,
        htmlSource: String?,
        mermaidProjection: AnyView?,
        mermaidDiagramSource: String? = nil,
        mediaTarget: EmbedTarget?,
        jsonCanvasHostAction: @escaping @MainActor @Sendable (JSONCanvasHostAction) -> Void
    ) {
        self.sourceBytes = sourceBytes
        self.pdfQuote = pdfQuote
        self.htmlSource = htmlSource
        self.mermaidProjection = mermaidProjection
        self.mermaidDiagramSource = mermaidDiagramSource
        self.mediaTarget = mediaTarget
        self.jsonCanvasHostAction = jsonCanvasHostAction
    }
}
#endif
