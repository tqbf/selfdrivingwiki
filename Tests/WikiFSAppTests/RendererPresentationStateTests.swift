#if os(macOS)
import Foundation
import SwiftUI
import Testing
import WikiFSCore
import WikiFSTypes
@testable import WikiFS

@Suite struct RendererPresentationStateTests {
    private func pdfSource() -> SourceSummary {
        SourceSummary(
            id: SourceID(rawValue: "01J00000000000000000000000"),
            filename: "paper.pdf",
            ext: "pdf",
            mimeType: MimeType.pdf,
            byteSize: 4,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            version: 1)
    }

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

    @Test("Selecting Source clears the live renderer pin so a registry refresh cannot report it unavailable")
    func selectingSourceClearsLiveRendererPin() {
        let pdf = BuiltInRendererReference.reference(for: .pdf)
        var state = RendererPresentationState(sourceID: SourceID(rawValue: "01J00000000000000000000000"))
        state.selectRendered(pdf)

        state.selectSource()
        state.keepPinnedRenderer(available: [])

        #expect(state.selection == .source)
        #expect(state.pinnedRenderer == nil)
        #expect(state.fallbackReason == nil)
    }

    @Test("Production lifecycle: an unchanged source refresh preserves its pinned renderer and selected mode")
    func unchangedRefreshPreservesPinnedRendererAndMode() {
        let source = pdfSource()
        let pdf = BuiltInRendererReference.reference(for: .pdf)
        var lifecycle = RendererPresentationLifecycle(sourceID: source.id)
        lifecycle.resolveLoadedSource(
            source: source,
            matchingRenderer: pdf,
            currentMarkdown: nil,
            persistedSelection: .rendered)
        lifecycle.selectSplit(pdf)

        lifecycle.refreshLoadedSource(
            source: source,
            availableRenderers: [pdf],
            matchingRenderer: pdf,
            currentMarkdown: nil,
            persistedSelection: .rendered)

        #expect(lifecycle.state.selection == .split)
        #expect(lifecycle.state.pinnedRenderer == pdf)
    }

    @Test("Production lifecycle: a failed renderer fallback survives an unchanged refresh")
    func fallbackRefreshKeepsSourceAndNotice() {
        let source = pdfSource()
        let pdf = BuiltInRendererReference.reference(for: .pdf)
        var lifecycle = RendererPresentationLifecycle(sourceID: source.id)
        lifecycle.resolveLoadedSource(
            source: source,
            matchingRenderer: pdf,
            currentMarkdown: nil,
            persistedSelection: .rendered)
        lifecycle.selectFallback(reason: "The selected renderer could not be loaded.")

        lifecycle.refreshLoadedSource(
            source: source,
            availableRenderers: [pdf],
            matchingRenderer: pdf,
            currentMarkdown: nil,
            persistedSelection: .rendered)

        #expect(lifecycle.state.selection == .source)
        #expect(lifecycle.state.pinnedRenderer == nil)
        #expect(lifecycle.state.fallbackReason == "The selected renderer could not be loaded.")

        var reopened = RendererPresentationLifecycle(sourceID: source.id)
        reopened.resolveLoadedSource(
            source: source,
            matchingRenderer: pdf,
            currentMarkdown: nil,
            persistedSelection: .rendered)
        #expect(reopened.state.selection == .rendered)
        #expect(reopened.state.pinnedRenderer == pdf)
    }

    @Test("Production lifecycle: a refresh for a different source adopts that source identity")
    func refreshForDifferentSourceUsesResolvedSourceIdentity() {
        let firstSourceID = SourceID(rawValue: "01J00000000000000000000000")
        let secondSourceID = SourceID(rawValue: "01J00000000000000000000001")
        let secondSource = lifecycleSource(
            id: secondSourceID,
            filename: "paper.pdf",
            ext: "pdf",
            mimeType: MimeType.pdf,
            byteSize: 4)
        let pdf = BuiltInRendererReference.reference(for: .pdf)
        var lifecycle = RendererPresentationLifecycle(sourceID: firstSourceID)

        lifecycle.refreshLoadedSource(
            source: secondSource,
            availableRenderers: [pdf],
            matchingRenderer: pdf,
            currentMarkdown: nil,
            persistedSelection: .rendered)

        #expect(lifecycle.state.sourceID == secondSourceID)
        #expect(lifecycle.state.selection == .rendered)
        #expect(lifecycle.state.pinnedRenderer == pdf)
    }

    @Test("The detail minimum width admits the production Split layout")
    func detailMinimumWidthSupportsSplit() {
        #expect(RendererPresentationLayout.supportsSplit(detailWidth: PageEditorMetrics.detailMinWidth))
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

    @Test("Presentation controls describe the active visual and VoiceOver state")
    func presentationControlsDescribeActiveVisualAndVoiceOverState() {
        let source = RendererPresentationControlState(
            presentation: .source,
            selectedPresentation: .rendered)
        let rendered = RendererPresentationControlState(
            presentation: .rendered,
            selectedPresentation: .rendered)
        let split = RendererPresentationControlState(
            presentation: .split,
            selectedPresentation: .rendered)

        #expect(source.isSelected == false)
        #expect(source.accessibilityValue == "Not selected")
        #expect(rendered.isSelected)
        #expect(rendered.accessibilityValue == "Selected")
        #expect(split.isSelected == false)
        #expect(split.accessibilityValue == "Not selected")
    }

    @Test("Fallback waits for explicit renderer selection before recovering")
    func fallbackWaitsForExplicitRendererSelectionBeforeRecovering() {
        let pdf = BuiltInRendererReference.reference(for: .pdf)
        var state = RendererPresentationState(sourceID: SourceID(rawValue: "01J00000000000000000000000"))
        state.selectRendered(pdf)
        state.selectFallback(reason: "The selected renderer could not be loaded.")

        state.keepPinnedRenderer(available: [pdf])
        #expect(state.selection == .source)
        #expect(state.pinnedRenderer == nil)
        #expect(state.fallbackReason == "The selected renderer could not be loaded.")

        state.selectRendered(pdf)
        #expect(state.selection == .rendered)
        #expect(state.pinnedRenderer == pdf)
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

    @Test("Lifecycle: HTML without processed markdown uses its rendered descriptor")
    func lifecycleHTMLWithoutMarkdownUsesRenderedDescriptor() {
        let source = lifecycleSource(filename: "page.html", ext: "html", mimeType: MimeType.html, byteSize: 14)
        let html = BuiltInRendererReference.reference(for: .html)
        var lifecycle = RendererPresentationLifecycle(sourceID: source.id)

        lifecycle.resolveLoadedSource(
            source: source,
            matchingRenderer: html,
            currentMarkdown: nil,
            persistedSelection: nil)

        #expect(lifecycle.state.selection == .rendered)
        #expect(lifecycle.state.pinnedRenderer == html)
    }

    @Test("Lifecycle: an editing refresh retains Source despite a persisted Rendered selection")
    func lifecycleEditingRefreshDoesNotReplaceSourceWithRendered() {
        let source = lifecycleSource(filename: "page.html", ext: "html", mimeType: MimeType.html, byteSize: 14)
        let html = BuiltInRendererReference.reference(for: .html)
        var lifecycle = RendererPresentationLifecycle(sourceID: source.id)
        lifecycle.resolveLoadedSource(
            source: source,
            matchingRenderer: html,
            currentMarkdown: "# Extracted page",
            persistedSelection: .rendered)
        lifecycle.selectSource()

        lifecycle.refreshLoadedSource(
            source: source,
            availableRenderers: [html],
            matchingRenderer: html,
            currentMarkdown: "# Extracted page\n\nUnsaved edit",
            persistedSelection: .rendered,
            isEditing: true)

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

    @Test("Lifecycle: a renderer that returns after a transient refresh restores the persisted presentation")
    func lifecycleRecoversRendererAfterTransientUnavailableRefresh() {
        let source = lifecycleSource(
            filename: "architecture.svg",
            ext: "svg",
            mimeType: "image/svg+xml",
            byteSize: 848)
        let svg = BuiltInRendererReference.reference(for: .svg)
        var lifecycle = RendererPresentationLifecycle(sourceID: source.id)
        lifecycle.resolveLoadedSource(
            source: source,
            matchingRenderer: svg,
            boundedBytes: Data("<svg></svg>".utf8),
            currentMarkdown: nil,
            persistedSelection: .rendered)

        lifecycle.refreshLoadedSource(
            source: source,
            availableRenderers: [],
            matchingRenderer: nil,
            boundedBytes: Data("<svg></svg>".utf8),
            currentMarkdown: nil,
            persistedSelection: .rendered)
        #expect(lifecycle.state.selection == .source)
        #expect(lifecycle.state.fallbackReason == RendererPresentationState.unavailableFallbackMessage)

        lifecycle.refreshLoadedSource(
            source: source,
            availableRenderers: [svg],
            matchingRenderer: svg,
            boundedBytes: Data("<svg></svg>".utf8),
            currentMarkdown: nil,
            persistedSelection: .rendered)

        #expect(lifecycle.state.selection == .rendered)
        #expect(lifecycle.state.pinnedRenderer == svg)
        #expect(lifecycle.state.fallbackReason == nil)
    }

    @Test("Lifecycle: automatic Rendered mode recovers after a transient renderer omission")
    func lifecycleAutomaticRenderedModeRecoversAfterTransientOmission() {
        let source = lifecycleSource(filename: "paper.pdf", ext: "pdf", mimeType: MimeType.pdf, byteSize: 4)
        let pdf = BuiltInRendererReference.reference(for: .pdf)
        var lifecycle = RendererPresentationLifecycle(sourceID: source.id)
        lifecycle.resolveLoadedSource(
            source: source,
            matchingRenderer: pdf,
            currentMarkdown: nil,
            persistedSelection: nil)
        lifecycle.refreshLoadedSource(
            source: source,
            availableRenderers: [],
            matchingRenderer: nil,
            currentMarkdown: nil,
            persistedSelection: nil)
        lifecycle.refreshLoadedSource(
            source: source,
            availableRenderers: [pdf],
            matchingRenderer: pdf,
            currentMarkdown: nil,
            persistedSelection: nil)

        #expect(lifecycle.state.selection == .rendered)
        #expect(lifecycle.state.pinnedRenderer == pdf)
        #expect(lifecycle.state.fallbackReason == nil)
    }

    @Test("Lifecycle: transient omission restores Split only with the same exact renderer")
    func lifecycleSplitRecoveryRejectsRendererSubstitution() {
        let source = lifecycleSource(
            filename: "architecture.svg",
            ext: "svg",
            mimeType: "image/svg+xml",
            byteSize: 848)
        let svg = BuiltInRendererReference.reference(for: .svg)
        let html = BuiltInRendererReference.reference(for: .html)
        let bytes = Data("<svg></svg>".utf8)
        var lifecycle = RendererPresentationLifecycle(sourceID: source.id)
        lifecycle.resolveLoadedSource(
            source: source,
            matchingRenderer: svg,
            boundedBytes: bytes,
            currentMarkdown: nil,
            persistedSelection: .split)
        lifecycle.refreshLoadedSource(
            source: source,
            availableRenderers: [],
            matchingRenderer: nil,
            boundedBytes: bytes,
            currentMarkdown: nil,
            persistedSelection: .split)

        lifecycle.refreshLoadedSource(
            source: source,
            availableRenderers: [html],
            matchingRenderer: html,
            boundedBytes: bytes,
            currentMarkdown: nil,
            persistedSelection: .split)
        #expect(lifecycle.state.selection == .source)
        #expect(lifecycle.state.pinnedRenderer == nil)
        #expect(lifecycle.state.fallbackReason == RendererPresentationState.unavailableFallbackMessage)

        lifecycle.refreshLoadedSource(
            source: source,
            availableRenderers: [svg],
            matchingRenderer: svg,
            boundedBytes: bytes,
            currentMarkdown: nil,
            persistedSelection: .split)
        #expect(lifecycle.state.selection == .split)
        #expect(lifecycle.state.pinnedRenderer == svg)
        #expect(lifecycle.state.fallbackReason == nil)
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

    @Test("Deferred fallback applies only to the source that scheduled it")
    @MainActor
    func deferredFallbackRejectsSourceNavigationAndDuplicateFallbacks() {
        let firstSource = SourceID(rawValue: "01J00000000000000000000000")
        let secondSource = SourceID(rawValue: "01J00000000000000000000001")
        let cleanState = RendererPresentationState(sourceID: firstSource)
        var fallbackState = cleanState
        fallbackState.selectFallback(reason: "The selected renderer is unavailable.")

        #expect(RendererHostView<EmptyView, EmptyView>.shouldApplyDeferredFallback(
            failedSourceID: firstSource,
            currentState: cleanState))
        #expect(RendererHostView<EmptyView, EmptyView>.shouldApplyDeferredFallback(
            failedSourceID: firstSource,
            currentState: RendererPresentationState(sourceID: secondSource)) == false)
        #expect(RendererHostView<EmptyView, EmptyView>.shouldApplyDeferredFallback(
            failedSourceID: firstSource,
            currentState: fallbackState) == false)
    }
}

private func lifecycleSource(
    id: SourceID = SourceID(rawValue: "01J00000000000000000000000"),
    filename: String,
    ext: String,
    mimeType: String?,
    byteSize: Int
) -> SourceSummary {
    SourceSummary(
        id: id,
        filename: filename,
        ext: ext,
        mimeType: mimeType,
        byteSize: byteSize,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0),
        version: 1)
}
#endif
