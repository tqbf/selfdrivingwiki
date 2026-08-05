#if os(macOS)
import Foundation
import Testing
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
}
#endif
