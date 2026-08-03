import Foundation
import WikiFSCore

enum MetadataHydrationState: Equatable {
    case idle
    case loading(subject: MetadataSubject)
    case loaded(MetadataPanelModel)
    case failed(subject: MetadataSubject, message: String)
}

enum MetadataHydrationKey: Hashable {
    case page(PageID, Int)
    case source(SourceID, Int)
    case chat(ChatID, Int)
}

enum MetadataHydrationReadPath: Equatable, Sendable {
    case readPool
    case inMemoryStoreFallback

    static func resolve(readPoolAvailable: Bool) -> MetadataHydrationReadPath {
        readPoolAvailable ? .readPool : .inMemoryStoreFallback
    }
}

/// The common structured-task transition guard for detail-owned metadata.
/// Detail views still own their `@State`; this helper only guarantees that a
/// cancelled task cannot publish an obsolete loading, success, or failure.
@MainActor
enum MetadataHydrator {
    static func hydrate(
        subject: MetadataSubject,
        operation: @MainActor () async throws -> MetadataPanelModel,
        publish: (MetadataHydrationState) -> Void
    ) async {
        guard !Task.isCancelled else { return }
        publish(.loading(subject: subject))
        do {
            let model = try await operation()
            guard !Task.isCancelled else { return }
            publish(.loaded(model))
        } catch {
            guard !Task.isCancelled else { return }
            publish(.failed(subject: subject, message: error.localizedDescription))
        }
    }
}
