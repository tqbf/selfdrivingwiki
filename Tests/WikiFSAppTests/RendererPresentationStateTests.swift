#if os(macOS)
import Foundation
import SwiftUI
import Testing
import WikiFSCore
import WikiFSTypes
@testable import WikiFS

@Suite struct RendererPresentationStateTests {
    @Test func sourceFallbackIsSelectedWhenNoRendererMatches() {
        let state = RendererPresentationState(sourceID: SourceID(rawValue: "01J00000000000000000000000"))
        #expect(state.selection == .source)
        #expect(state.pinnedRenderer == nil)
    }

    @Test("An unextracted PDF defaults to its matching rendered descriptor")
    func unextractedPDFDefaultsToRendered() {
        let pdf = BuiltInRendererReference.reference(for: .pdf)
        let state = RendererPresentationState.defaultState(
            sourceID: SourceID(rawValue: "01J00000000000000000000000"),
            matchingRenderer: pdf,
            hasPresentableSource: false,
            persistedSelection: nil)

        #expect(state.selection == .rendered)
        #expect(state.pinnedRenderer == pdf)
    }

    @Test("Presentable source content remains the default despite a renderer match")
    func presentableSourceDefaultsToSource() {
        let pdf = BuiltInRendererReference.reference(for: .pdf)
        let state = RendererPresentationState.defaultState(
            sourceID: SourceID(rawValue: "01J00000000000000000000000"),
            matchingRenderer: pdf,
            hasPresentableSource: true,
            persistedSelection: nil)

        #expect(state.selection == .source)
        #expect(state.pinnedRenderer == nil)
    }

    @Test func selectingRenderedPinsTheExactReference() throws {
        let reference = BuiltInRendererReference.reference(for: .pdf)
        var state = RendererPresentationState(sourceID: SourceID(rawValue: "01J00000000000000000000000"))
        state.selectRendered(reference)
        #expect(state.selection == .rendered)
        #expect(state.pinnedRenderer == reference)
    }

    @Test func refreshDoesNotReplacePinnedRenderer() {
        let pdf = BuiltInRendererReference.reference(for: .pdf)
        let html = BuiltInRendererReference.reference(for: .html)
        var state = RendererPresentationState(sourceID: SourceID(rawValue: "01J00000000000000000000000"))
        state.selectRendered(pdf)
        state.keepPinnedRenderer(available: [html])
        #expect(state.pinnedRenderer == nil)
        #expect(state.selection == .source)
    }

    @Test("A removed pin lets Split choose an available renderer")
    func unavailablePinDoesNotBlockSplitSelection() {
        let pdf = BuiltInRendererReference.reference(for: .pdf)
        let html = BuiltInRendererReference.reference(for: .html)
        var state = RendererPresentationState(sourceID: SourceID(rawValue: "01J00000000000000000000000"))
        state.selectRendered(pdf)
        state.keepPinnedRenderer(available: [html])
        state.selectSplit(html)

        #expect(state.selection == .split)
        #expect(state.pinnedRenderer == html)
    }

    @Test("Fallback reason survives the transition to Source")
    func fallbackReasonRemainsVisibleUntilTheUserSelectsAPresentation() {
        let pdf = BuiltInRendererReference.reference(for: .pdf)
        var state = RendererPresentationState(sourceID: SourceID(rawValue: "01J00000000000000000000000"))
        state.selectRendered(pdf)
        state.selectFallback(reason: "The selected renderer is unavailable.")

        #expect(state.selection == .source)
        #expect(state.fallbackReason == "The selected renderer is unavailable.")
        state.selectSource()
        #expect(state.fallbackReason == nil)
    }

    @Test("Split metrics fit the source detail minimum width")
    func splitMetricsFitDetailMinimumWidth() {
        #expect(RendererPresentationLayout.supportsSplit(detailWidth: PageEditorMetrics.detailMinWidth))
    }

    @Test func refreshKeepsThePinnedSplitPresentationWhenRendererRemainsAvailable() {
        let pdf = BuiltInRendererReference.reference(for: .pdf)
        var state = RendererPresentationState(sourceID: SourceID(rawValue: "01J00000000000000000000000"))
        state.selectSplit(pdf)
        state.keepPinnedRenderer(available: [pdf])
        #expect(state.selection == .split)
        #expect(state.pinnedRenderer == pdf)
    }

    @Test("Lifecycle: an unextracted PDF resolves Rendered only after its source facts load")
    func lifecycleUnextractedPDFUsesRenderedAndKeepsItsRendererPin() {
        let sourceID = SourceID(rawValue: "01J00000000000000000000000")
        let pdf = BuiltInRendererReference.reference(for: .pdf)
        var lifecycle = RendererPresentationLifecycle(sourceID: sourceID)

        #expect(lifecycle.state.selection == .source)
        #expect(lifecycle.state.pinnedRenderer == nil)

        lifecycle.resolveLoadedSource(
            source: lifecycleSource(filename: "paper.pdf", ext: "pdf", mimeType: MimeType.pdf, byteSize: 4),
            matchingRenderer: pdf,
            currentMarkdown: nil,
            persistedSelection: nil)

        #expect(lifecycle.state.selection == .rendered)
        #expect(lifecycle.state.pinnedRenderer == pdf,
                "The PDF renderer remains selected so the unextracted quote-anchor path can render it.")
    }

    @Test("Lifecycle: extracted PDFs resolve Source after their markdown loads")
    func lifecycleExtractedPDFUsesSourceAfterMarkdownLoads() {
        let pdf = BuiltInRendererReference.reference(for: .pdf)
        var lifecycle = RendererPresentationLifecycle(sourceID: SourceID(rawValue: "01J00000000000000000000000"))

        lifecycle.resolveLoadedSource(
            source: lifecycleSource(filename: "paper.pdf", ext: "pdf", mimeType: MimeType.pdf, byteSize: 4),
            matchingRenderer: pdf,
            currentMarkdown: "# Extracted paper",
            persistedSelection: nil)

        #expect(lifecycle.state.selection == .source)
        #expect(lifecycle.state.pinnedRenderer == nil)
    }

    @Test("Lifecycle: a loaded extraction replaces an automatic PDF Rendered default with Source")
    func lifecycleReResolvesWhenPDFPresentabilityChanges() {
        let source = lifecycleSource(filename: "paper.pdf", ext: "pdf", mimeType: MimeType.pdf, byteSize: 4)
        let pdf = BuiltInRendererReference.reference(for: .pdf)
        var lifecycle = RendererPresentationLifecycle(sourceID: source.id)

        lifecycle.resolveLoadedSource(
            source: source,
            matchingRenderer: pdf,
            currentMarkdown: nil,
            persistedSelection: nil)
        #expect(lifecycle.state.selection == .rendered)

        lifecycle.resolveLoadedSource(
            source: source,
            matchingRenderer: pdf,
            currentMarkdown: "# Extracted paper",
            persistedSelection: nil)
        #expect(lifecycle.state.selection == .source)
        #expect(lifecycle.state.pinnedRenderer == nil)
    }

    @Test("Lifecycle: transcript-bearing media resolves Source after its transcript loads")
    func lifecycleTranscriptMediaUsesSourceAfterTranscriptLoads() {
        let media = BuiltInRendererReference.reference(for: .media)
        var lifecycle = RendererPresentationLifecycle(sourceID: SourceID(rawValue: "01J00000000000000000000000"))

        lifecycle.resolveLoadedSource(
            source: lifecycleSource(filename: "video", ext: "", mimeType: "video/youtube", byteSize: 0),
            matchingRenderer: media,
            currentMarkdown: "Transcript",
            persistedSelection: nil)

        #expect(lifecycle.state.selection == .source)
        #expect(lifecycle.state.pinnedRenderer == nil)
    }

    @Test("Lifecycle: native markdown and plain text keep Source as the default")
    func lifecycleNativeTextUsesSource() {
        for source in [
            lifecycleSource(filename: "note.md", ext: "md", mimeType: MimeType.markdown, byteSize: 5),
            lifecycleSource(filename: "note.txt", ext: "txt", mimeType: "text/plain", byteSize: 5),
        ] {
            var lifecycle = RendererPresentationLifecycle(sourceID: source.id)
            lifecycle.resolveLoadedSource(
                source: source,
                matchingRenderer: nil,
                currentMarkdown: nil,
                persistedSelection: nil)

            #expect(lifecycle.state.selection == .source)
            #expect(lifecycle.state.pinnedRenderer == nil)
        }
    }

    @Test("Lifecycle: source navigation clears the prior source pin before resolving the destination")
    func lifecycleSourceNavigationDoesNotRetainPriorPresentation() {
        let firstSource = SourceID(rawValue: "01J00000000000000000000000")
        let secondSource = SourceID(rawValue: "01J00000000000000000000001")
        let pdf = BuiltInRendererReference.reference(for: .pdf)
        var lifecycle = RendererPresentationLifecycle(sourceID: firstSource)
        lifecycle.resolveLoadedSource(
            source: lifecycleSource(filename: "paper.pdf", ext: "pdf", mimeType: MimeType.pdf, byteSize: 4),
            matchingRenderer: pdf,
            currentMarkdown: nil,
            persistedSelection: nil)

        lifecycle.beginLoading(sourceID: secondSource)

        #expect(lifecycle.state.sourceID == secondSource)
        #expect(lifecycle.state.selection == .source)
        #expect(lifecycle.state.pinnedRenderer == nil)
    }

    @Test("Split uses the first current descriptor when its pin is stale")
    @MainActor
    func splitUsesCurrentDescriptorWhenPinIsStale() {
        let pdf = BuiltInRendererReference.reference(for: .pdf)
        let html = BuiltInRendererReference.reference(for: .html)

        #expect(RendererHostView<EmptyView, EmptyView>.splitRendererReference(
            pinnedRenderer: pdf,
            availableRendererReferences: [html]) == html)
    }
}

private func lifecycleSource(
    filename: String,
    ext: String,
    mimeType: String?,
    byteSize: Int
) -> SourceSummary {
    SourceSummary(
        id: SourceID(rawValue: "01J00000000000000000000000"),
        filename: filename,
        ext: ext,
        mimeType: mimeType,
        byteSize: byteSize,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0),
        version: 1)
}
#endif
