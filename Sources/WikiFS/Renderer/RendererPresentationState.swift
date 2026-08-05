#if os(macOS)
import Foundation
import WikiFSTypes

// pattern: Functional Core

/// Per-source presentation choice for a rendered pane.
///
/// Source is a host-owned fallback. A rendered choice retains its exact
/// reference until the pane closes or the user makes another selection.
struct RendererPresentationState: Sendable, Equatable {
    enum Selection: String, Sendable, Equatable {
        case source
        case rendered
        case split
    }

    let sourceID: SourceID
    private(set) var selection: Selection
    private(set) var pinnedRenderer: RendererReference?

    init(sourceID: SourceID, selection: Selection = .source, pinnedRenderer: RendererReference? = nil) {
        self.sourceID = sourceID
        self.selection = selection
        self.pinnedRenderer = pinnedRenderer
    }

    mutating func selectSource() {
        selection = .source
    }

    mutating func selectRendered(_ reference: RendererReference) {
        selection = .rendered
        pinnedRenderer = reference
    }

    mutating func selectSplit(_ reference: RendererReference) {
        selection = .split
        pinnedRenderer = reference
    }

    /// A registry refresh cannot substitute a different exact renderer.
    mutating func keepPinnedRenderer(available: [RendererReference]) {
        guard let pinnedRenderer, available.contains(pinnedRenderer) else {
            selection = .source
            return
        }
    }
}
#endif
