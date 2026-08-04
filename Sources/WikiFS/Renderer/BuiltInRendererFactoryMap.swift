#if os(macOS)
import Foundation
import SwiftUI
import WikiFSTypes

// pattern: Composition Root

/// App-target factory registry for host-owned native renderer views.
///
/// PR 2 keeps SourceDetailView on its legacy branches, so these factories are a
/// closed, typed inventory rather than the active routing path. PR 4 will replace
/// the token output with renderer-host inputs and call the appropriate existing
/// view builders from one generic host.
@MainActor
enum BuiltInRendererFactoryMap {
    typealias Factory = @MainActor (BuiltInRendererFactoryContext) -> BuiltInRendererFactoryToken

    static let factories: [BuiltInRendererID: Factory] = [
        .pdf: { _ in .pdf },
        .html: { _ in .html },
        .mermaid: { _ in .mermaid },
        .media: { _ in .media },
    ]

    static func factory(for id: BuiltInRendererID) -> Factory? {
        factories[id]
    }
}

struct BuiltInRendererFactoryContext: Sendable, Equatable {
    let rendererID: BuiltInRendererID

    init(rendererID: BuiltInRendererID) {
        self.rendererID = rendererID
    }
}

enum BuiltInRendererFactoryToken: Sendable, Equatable {
    case pdf
    case html
    case mermaid
    case media
}
#endif
