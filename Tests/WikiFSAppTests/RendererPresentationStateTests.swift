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
        #expect(state.pinnedRenderer == pdf)
        #expect(state.selection == .source)
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
