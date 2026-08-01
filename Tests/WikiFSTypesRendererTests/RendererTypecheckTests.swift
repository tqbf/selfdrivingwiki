import Foundation
import Testing

/// Compiles API fixtures against the built portable module. A runtime equality
/// assertion cannot prove that package/version namespaces stay distinct.
struct RendererIdentifierBoundaryTypecheckTests {
    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func fixtureURL(_ name: String) -> URL {
        repositoryRoot().appendingPathComponent("Tests/WikiFSTypesRendererTests/Fixtures/RendererIdentifierBoundaryTypecheck/\(name)")
    }

    private func moduleDirectory() throws -> URL {
        let buildDirectory = repositoryRoot().appendingPathComponent(".build")
        let enumerator = try #require(FileManager.default.enumerator(at: buildDirectory, includingPropertiesForKeys: [.isDirectoryKey]))
        for case let url as URL in enumerator where url.lastPathComponent == "Modules" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("WikiFSTypes.swiftmodule").path) {
                return url
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private func typecheck(_ fixture: String) throws -> (status: Int32, output: String) {
        let scratch = repositoryRoot().appendingPathComponent("tmp/renderer-typecheck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: scratch) }
            catch { Issue.record("failed to remove renderer typecheck scratch directory: \(error)") }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swiftc", "-typecheck", "-I", try moduleDirectory().path, "-module-cache-path", scratch.path, fixtureURL(fixture).path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    @Test func positiveFixtureCompiles() throws {
        let result = try typecheck("positive.swift")
        #expect(result.status == 0, "positive renderer fixture failed to typecheck:\n\(result.output)")
    }

    @Test func packageVersionNamespacesCannotBeInterchanged() throws {
        let result = try typecheck("version-for-package.swift")
        #expect(result.status != 0, "RendererPackageVersion unexpectedly typechecked as RendererPackageID.")
        #expect(result.output.contains("RendererPackageVersion") && result.output.contains("RendererPackageID"), "unexpected compiler diagnostic:\n\(result.output)")
    }
}
