import Foundation
import Testing

@Suite("Cordis boundary script", .serialized, .timeLimit(.minutes(1)))
struct CordisBoundaryScriptTests {
    struct ProtectedConstruction: Sendable, CustomTestStringConvertible {
        let path: String
        let source: String

        var testDescription: String { path }
    }

    @Test("current source tree satisfies strict boundaries", arguments: [[], ["--strict"]])
    func currentTreeSatisfiesStrictBoundaries(arguments: [String]) async throws {
        let result = try await runBoundaryCheck(arguments: arguments)
        #expect(result.status == 0, "Boundary check failed: \(result.standardError)")
    }

    @Test("app initializer is not a privileged domain assembly root")
    func appInitializerHasNoDirectDomainConstruction() throws {
        let root = repositoryRoot()
        let app = try String(
            contentsOf: root.appendingPathComponent("Sources/WikiFS/Window/WikiFSApp.swift"),
            encoding: .utf8)
        let catalog = try String(
            contentsOf: root.appendingPathComponent("Sources/WikiFS/Renderer/RendererCompositionOwner.swift"),
            encoding: .utf8)

        for constructor in [
            "GenerationGate(", "AgentLauncher(", "AgentProviderRuntimeFactory(",
            "ExtractionRuntimeFactory(", "QueueRuntimeFactory(",
            "DaemonTransportRuntimeFactory(", "RendererRuntimeFactory(",
        ] {
            #expect(!app.contains(constructor), "WikiFSApp must not construct \(constructor)")
        }
        #expect(!app.contains("AppProcessComposition"))
        #expect(catalog.contains("final class AppProcessPluginCatalog"))
        #expect(catalog.contains("ProcessRuntimePlugins"))
    }

    @Test("rejects privileged construction outside allowlisted boundaries", arguments: [
        "let value = ProfileWikiSession(",
        "let value = GRDBWikiStore(",
        "let value = WikiStoreModel(",
        "let value = SearchCompositionOwner(",
        "let value = GenerationGate(",
        "let value = AgentLauncher(",
    ])
    func rejectsPrivilegedConstruction(source: String) async throws {
        let root = repositoryRoot()
        let fixtureRoot = root.appendingPathComponent("tmp/cordis-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        let fixture = fixtureRoot.appendingPathComponent("CordisBoundaryViolationFixture.swift")
        try source.write(to: fixture, atomically: false, encoding: .utf8)
        defer {
            do { try FileManager.default.removeItem(at: fixtureRoot) }
            catch { Issue.record("Could not remove boundary fixture: \(error)") }
        }

        let result = try await runBoundaryCheck(arguments: [], sourceRoot: fixtureRoot)
        #expect(result.status != 0)
        #expect(result.standardError.contains("CordisBoundaryViolationFixture.swift"))
    }

    @Test("migrated production paths cannot regain direct construction", arguments: [
        ProtectedConstruction(
            path: "Sources/wikid/WikiDaemon.swift",
            source: "let store = GRDBWikiStore("),
        ProtectedConstruction(
            path: "Sources/wikictl/main.swift",
            source: "let store = GRDBWikiStore("),
        ProtectedConstruction(
            path: "Sources/wikid/DaemonQueueIngestionProvider.swift",
            source: "let launcher = AgentLauncher("),
    ])
    func migratedProductionPathsRemainProtected(fixture: ProtectedConstruction) async throws {
        let root = repositoryRoot()
        let fixtureRoot = root.appendingPathComponent(
            "tmp/cordis-protected-path-\(UUID().uuidString)",
            isDirectory: true)
        let file = fixtureRoot.appendingPathComponent(fixture.path)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try fixture.source.write(to: file, atomically: false, encoding: .utf8)
        defer {
            do { try FileManager.default.removeItem(at: fixtureRoot) }
            catch { Issue.record("Could not remove protected-path fixture: \(error)") }
        }

        let result = try await runBoundaryCheck(arguments: [], sourceRoot: fixtureRoot)
        #expect(result.status != 0)
        #expect(result.standardError.contains(fixture.path))
    }

    @Test("documented allowlisted path is accepted in fixture mode")
    func documentedAllowlistedPathIsAcceptedInFixtureMode() async throws {
        let root = repositoryRoot()
        let fixtureRoot = root.appendingPathComponent(
            "tmp/cordis-allowed-path-\(UUID().uuidString)",
            isDirectory: true)
        let file = fixtureRoot.appendingPathComponent(
            "Sources/WikiFSCore/Store/StoreBackend.swift")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try "let store = GRDBWikiStore(".write(
            to: file,
            atomically: false,
            encoding: .utf8)
        defer {
            do { try FileManager.default.removeItem(at: fixtureRoot) }
            catch { Issue.record("Could not remove allowlisted-path fixture: \(error)") }
        }

        let result = try await runBoundaryCheck(arguments: [], sourceRoot: fixtureRoot)
        #expect(result.status == 0, "Boundary check failed: \(result.standardError)")
    }

    private func runBoundaryCheck(
        arguments: [String],
        sourceRoot: URL? = nil
    ) async throws -> (status: Int32, standardError: String) {
        let root = repositoryRoot()
        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = root.appendingPathComponent("scripts/check-cordis-boundaries")
        process.arguments = arguments
        if let sourceRoot {
            var environment = ProcessInfo.processInfo.environment
            environment["CORDIS_BOUNDARY_SOURCE_ROOT"] = sourceRoot.path
            environment["CORDIS_BOUNDARY_POLICY_PREFIX"] = ""
            process.environment = environment
        }
        let standardError = Pipe()
        process.standardError = standardError

        let terminations = AsyncStream<Void> { continuation in
            process.terminationHandler = { _ in
                continuation.yield()
                continuation.finish()
            }
        }
        try process.run()
        for await _ in terminations { break }

        let errorData = try standardError.fileHandleForReading.readToEnd() ?? Data()
        return (process.terminationStatus, String(decoding: errorData, as: UTF8.self))
    }
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
