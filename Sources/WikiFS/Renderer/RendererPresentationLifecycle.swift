#if os(macOS)
import WikiFSTypes
import WikiFSCore

// pattern: Functional Core

/// Resolves a source presentation only after the owner has loaded its source facts.
///
/// Loading a different source always clears the previous state. This prevents an
/// exact renderer pin from one `SourceID` from affecting another source.
struct RendererPresentationLifecycle: Sendable, Equatable {
    private(set) var state: RendererPresentationState

    init(sourceID: SourceID) {
        state = RendererPresentationState(sourceID: sourceID)
    }

    mutating func beginLoading(sourceID: SourceID) {
        state = RendererPresentationState(sourceID: sourceID)
    }

    mutating func resolveLoadedSource(
        source: SourceSummary,
        matchingRenderer: RendererReference?,
        currentMarkdown: String?,
        persistedSelection: RendererSourcePresentationMode?
    ) {
        state = RendererPresentationState.defaultState(
            sourceID: state.sourceID,
            matchingRenderer: matchingRenderer,
            hasPresentableSource: SourceRendererPresentationPlanner.hasPresentableSource(
                for: source,
                currentMarkdown: currentMarkdown),
            persistedSelection: persistedSelection)
    }
}
#endif
