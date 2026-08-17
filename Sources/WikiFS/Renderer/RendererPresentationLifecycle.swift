#if os(macOS)
import Foundation
import WikiFSTypes
import WikiFSCore

// pattern: Functional Core

/// Resolves a source presentation only after the owner has loaded its source facts.
///
/// Loading a different source always clears the previous state. This prevents an
/// exact renderer pin from one `SourceID` from affecting another source.
struct RendererPresentationLifecycle: Sendable, Equatable {
    private(set) var state: RendererPresentationState
    private var loadedFacts: LoadedFacts?

    private struct LoadedFacts: Sendable, Equatable {
        let source: SourceSummary
        let boundedBytes: Data?
        let currentMarkdown: String?
        let origin: SourceOrigin?
    }

    init(sourceID: SourceID) {
        state = RendererPresentationState(sourceID: sourceID)
        loadedFacts = nil
    }

    mutating func beginLoading(sourceID: SourceID) {
        state = RendererPresentationState(sourceID: sourceID)
        loadedFacts = nil
    }

    mutating func replaceState(_ state: RendererPresentationState) {
        self.state = state
    }

    mutating func selectSource() {
        state.selectSource()
    }

    mutating func selectSplit(_ reference: RendererReference) {
        state.selectSplit(reference)
    }

    mutating func selectRendered(_ reference: RendererReference) {
        state.selectRendered(reference)
    }

    mutating func selectFallback(reason: String) {
        state.selectFallback(reason: reason)
    }

    mutating func resolveLoadedSource(
        source: SourceSummary,
        matchingRenderer: RendererReference?,
        boundedBytes: Data? = nil,
        currentMarkdown: String?,
        origin: SourceOrigin? = nil,
        persistedSelection: RendererSourcePresentationMode?
    ) {
        state = RendererPresentationState.defaultState(
            sourceID: source.id,
            matchingRenderer: matchingRenderer,
            hasPresentableSource: SourceRendererPresentationPlanner.hasPresentableSource(
                for: source,
                currentMarkdown: currentMarkdown),
            persistedSelection: persistedSelection)
        loadedFacts = LoadedFacts(
            source: source,
            boundedBytes: boundedBytes,
            currentMarkdown: currentMarkdown,
            origin: origin)
    }

    /// Retains a pane-lifetime pin during unrelated source-list refreshes.
    /// Loaded facts, not a store notification alone, determine whether a
    /// persisted selection may be resolved again.
    mutating func refreshLoadedSource(
        source: SourceSummary,
        availableRenderers: [RendererReference],
        matchingRenderer: RendererReference?,
        boundedBytes: Data? = nil,
        currentMarkdown: String?,
        origin: SourceOrigin? = nil,
        persistedSelection: RendererSourcePresentationMode?,
        isEditing: Bool = false
    ) {
        // An edit buffer is transient input. Do not let a source-list refresh
        // resolve the persisted presentation over the live Source editor.
        // A different source must still resolve after navigation.
        guard !isEditing || state.sourceID != source.id else { return }
        let refreshedFacts = LoadedFacts(
            source: source,
            boundedBytes: boundedBytes,
            currentMarkdown: currentMarkdown,
            origin: origin)
        guard state.sourceID != source.id || loadedFacts != refreshedFacts else {
            state.keepPinnedRenderer(available: availableRenderers)
            return
        }
        resolveLoadedSource(
            source: source,
            matchingRenderer: matchingRenderer,
            boundedBytes: boundedBytes,
            currentMarkdown: currentMarkdown,
            origin: origin,
            persistedSelection: persistedSelection)
    }
}
#endif
