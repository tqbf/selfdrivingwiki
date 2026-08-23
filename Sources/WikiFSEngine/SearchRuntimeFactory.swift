#if os(macOS)
import Cordis
import WikiFSCore
import WikiFSSearch

/// Assembly-independent request for one per-wiki Tantivy runtime.
public struct SearchRuntimeFactory: Sendable {
    public typealias Factory = @Sendable (
        SearchRuntimeIdentity,
        any TantivyContentSource,
        any SearchChangeStreamFactory
    ) -> SearchRuntimeFactory

    public let identity: SearchRuntimeIdentity
    public let changeStreamFactory: any SearchChangeStreamFactory
    private let assembleOperation: @Sendable (CordisContext) async throws -> SearchRuntimeHandle

    public init(
        identity: SearchRuntimeIdentity,
        changeStreamFactory: any SearchChangeStreamFactory,
        assemble: @escaping @Sendable (CordisContext) async throws -> SearchRuntimeHandle
    ) {
        self.identity = identity
        self.changeStreamFactory = changeStreamFactory
        self.assembleOperation = assemble
    }

    public func assemble(in context: CordisContext) async throws -> SearchRuntimeHandle {
        try await assembleOperation(context)
    }

}
#endif
