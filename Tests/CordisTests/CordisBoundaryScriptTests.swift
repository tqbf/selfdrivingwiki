import Foundation
import Testing

@Suite("Cordis boundary script", .serialized, .timeLimit(.minutes(1)))
struct CordisBoundaryScriptTests {
    @Test("current source tree satisfies strict boundaries", arguments: [[], ["--strict"]])
    func currentTreeSatisfiesStrictBoundaries(arguments: [String]) async throws {
        let result = try await runBoundaryCheck(arguments: arguments)
        #expect(result.status == 0, "Boundary check failed: \(result.standardError)")
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
