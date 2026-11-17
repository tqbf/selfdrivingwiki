import Foundation
import Testing

@Suite("Search Cordis boundaries")
struct SearchCordisBoundaryPolicyTests {
    @Test("consumers receive facade only")
    func consumersReceiveFacadeOnly() throws {
        for path in [
            "Sources/WikiFSEngine/ProfileWikiSession.swift",
            "Sources/WikiFSEngine/SessionManager.swift",
            "Sources/WikiFSCore/Store/WikiStoreModel.swift",
            "Sources/WikiFS/Window/RootScene.swift",
        ] {
            let source = try read(path)
            #expect(!source.contains("CordisContext"), "Context leaked into \(path)")
            #expect(!source.contains("ActivationContext"), "Activation context leaked into \(path)")
            #expect(!source.contains("ServiceKey<"), "Service key leaked into \(path)")
        }
    }

    @Test("raw application state is not a search service")
    func rawApplicationStateIsNotAService() throws {
        let assembly = try read("Sources/WikiFSEngine/SearchRuntimeCompositionFactory.swift")
        for forbidden in [
            "ServiceKey<WikiStore", "ServiceKey<WikiEventBus", "ServiceKey<SQLite",
            "ServiceKey<GRDB", "ServiceKey<WikiReadPool",
        ] {
            #expect(!assembly.contains(forbidden))
        }
    }

    @Test("production uses shared assembly and no legacy construction")
    func legacyConstructionDoesNotReturn() throws {
        let sources = try [
            "Sources/WikiFSEngine/ProfileWikiSession.swift",
            "Sources/WikiCtlCore/CLITantivyLegResolver.swift",
        ].map(read).joined(separator: "\n")
        #expect(!sources.contains("TantivySearchService("))
        #expect(!sources.contains("TantivyIndexer("))
        #expect(!sources.contains("TantivyShadowSync"))
        #expect(!sources.contains("SearchRuntimeCompositionFactory"))
    }

    @Test("search lifecycle has no detached tasks")
    func lifecycleHasNoDetachedTasks() throws {
        for path in [
            "Sources/WikiFSEngine/SearchRuntime.swift",
            "Sources/WikiFSEngine/SearchRuntimeRegistry.swift",
            "Sources/WikiFSEngine/SearchChangeStreamFactory.swift",
        ] {
            let source = try read(path)
            #expect(!source.contains("Task.detached"))
        }
    }

    @Test("the deleted app search owner stays deleted")
    func deletedSearchOwnerStaysDeleted() {
        // P5: `SearchCompositionOwner.swift` is deleted — the app consumes
        // only the daemon-backed facade. The deleted file must not return.
        #expect(!FileManager.default.fileExists(
            atPath: repositoryRoot().appendingPathComponent(
                "Sources/WikiFSEngine/SearchCompositionOwner.swift").path))
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: repositoryRoot().appendingPathComponent(path), encoding: .utf8)
    }
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
