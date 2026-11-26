import Foundation
import WikiFSTypes

// pattern: Mixed (unavoidable)
// Reason: this main-actor protocol is a narrow boundary between the SwiftUI
// host and the concrete store model; it keeps the exact authorized-reader
// lookup typed without introducing another storage or bridge path.
@MainActor
public protocol RendererAuthorizedInputResolving {
    /// `async` since the WikiStore async flip (plan P1): the model resolves
    /// the active content version through the store to pin the reader.
    func rendererAuthorizedInputReader(for sourceID: SourceID) async -> RendererAuthorizedInputReader?
}
