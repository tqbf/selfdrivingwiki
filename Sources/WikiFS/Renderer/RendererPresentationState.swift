#if os(macOS)
import Foundation
import WikiFSTypes

// pattern: Functional Core

/// Per-source presentation choice for a rendered pane.
///
/// Source is a host-owned fallback. A rendered choice retains its exact
/// reference until the pane closes or the user makes another selection.
struct RendererPresentationState: Sendable, Equatable {
    typealias Selection = RendererSourcePresentationMode

    static let unavailableFallbackMessage = "The selected renderer is unavailable."

    let sourceID: SourceID
    private(set) var selection: Selection
    private(set) var pinnedRenderer: RendererReference?
    private(set) var fallbackReason: String?

    init(sourceID: SourceID, selection: Selection = .source, pinnedRenderer: RendererReference? = nil) {
        self.sourceID = sourceID
        self.selection = selection
        self.pinnedRenderer = pinnedRenderer
        fallbackReason = nil
    }

    static func defaultState(
        sourceID: SourceID,
        matchingRenderer: RendererReference?,
        hasPresentableSource: Bool,
        persistedSelection: Selection?
    ) -> Self {
        guard let matchingRenderer else { return Self(sourceID: sourceID) }
        let persistedSelection = persistedSelection.map { selection in
            selection == .split ? .rendered : selection
        }
        let selection = persistedSelection ?? (hasPresentableSource ? .source : .rendered)
        guard selection != .source else { return Self(sourceID: sourceID) }
        return Self(sourceID: sourceID, selection: selection, pinnedRenderer: matchingRenderer)
    }

    mutating func selectSource() {
        selection = .source
        pinnedRenderer = nil
        fallbackReason = nil
    }

    mutating func selectRendered(_ reference: RendererReference) {
        selection = .rendered
        pinnedRenderer = reference
        fallbackReason = nil
    }

    mutating func selectFallback(reason: String) {
        selection = .source
        pinnedRenderer = nil
        fallbackReason = reason
    }

    /// A registry refresh cannot substitute a different exact renderer.
    mutating func keepPinnedRenderer(available: [RendererReference]) {
        guard let pinnedRenderer, available.contains(pinnedRenderer) else {
            if self.pinnedRenderer != nil {
                selectFallback(reason: Self.unavailableFallbackMessage)
            }
            return
        }
    }
}

enum RendererHostMetrics {
    static let minimumFallbackPaneWidth: CGFloat = 200
}
#endif
