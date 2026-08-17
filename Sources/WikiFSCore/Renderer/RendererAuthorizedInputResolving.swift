import Foundation
import WikiFSTypes

// pattern: Functional Core

/// Composition seam for the exact, version-pinned input reader used by an
/// installed renderer session.
@MainActor
public protocol RendererAuthorizedInputResolving {
    func rendererAuthorizedInputReader(for sourceID: SourceID) -> RendererAuthorizedInputReader?
}
