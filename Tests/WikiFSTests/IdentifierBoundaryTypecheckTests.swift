import Foundation
import Testing

/// Runs small fixtures through `swiftc -typecheck` against the modules that
/// SwiftPM built for this test run. This proves the namespace boundary at the
/// compiler level, rather than only observing runtime behavior.
struct IdentifierBoundaryTypecheckTests {

    private struct CompilerResult {
        let status: Int32
        let output: String
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func fixtureURL(_ name: String) -> URL {
        repositoryRoot()
            .appendingPathComponent("Tests/WikiFSTests/Fixtures/IdentifierBoundaryTypecheck")
            .appendingPathComponent(name)
    }

    private func modulesDirectory() throws -> URL {
        let buildDirectory = repositoryRoot().appendingPathComponent(".build")
        let candidates = try FileManager.default.contentsOfDirectory(
            at: buildDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        let modules = candidates
            .map { $0.appendingPathComponent("debug/Modules") }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("WikiFSTypes.swiftmodule").path) }

        return try #require(
            modules.first,
            "SwiftPM did not build WikiFSTypes before the typecheck fixture ran."
        )
    }

    private func runTypecheck(_ fixtureName: String) throws -> CompilerResult {
        let root = repositoryRoot()
        let modules = try modulesDirectory()
        let tantivyHeaders = root.appendingPathComponent(
            ".build/artifacts/tantivy.swift/TantivyRS/libtantivy-rs.xcframework/macos-arm64_x86_64/Headers"
        )
        let tantivyModuleMap = tantivyHeaders
            .appendingPathComponent("tantivyFFI/module.modulemap")
        let grdbSQLite = root.appendingPathComponent(
            ".build/checkouts/GRDB.swift/Sources/GRDBSQLite"
        )
        let scratchDirectory = root
            .appendingPathComponent("tmp/identifier-boundary-typecheck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: scratchDirectory)
            } catch {
                Issue.record("failed to remove typecheck scratch directory: \(error)")
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "swiftc", "-typecheck",
            "-I", modules.path,
            "-Xcc", "-I\(tantivyHeaders.path)",
            "-Xcc", "-fmodule-map-file=\(tantivyModuleMap.path)",
            "-Xcc", "-I\(grdbSQLite.path)",
            "-Xcc", "-fmodule-map-file=\(grdbSQLite.appendingPathComponent("module.modulemap").path)",
            "-module-cache-path", scratchDirectory.path,
            fixtureURL(fixtureName).path,
        ]
        process.currentDirectoryURL = root

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        return CompilerResult(
            status: process.terminationStatus,
            output: String(decoding: outputData, as: UTF8.self)
        )
    }

    @Test func positiveFixturesCompile() throws {
        let result = try runTypecheck("positive.swift")
        #expect(result.status == 0, "positive fixture failed to typecheck:\n\(result.output)")
    }

    @Test func pageIDIsRejectedBySourceAPI() throws {
        let result = try runTypecheck("page-id-to-source-api.swift")
        #expect(result.status != 0, "PageID unexpectedly typechecked at a SourceID API boundary.")
        #expect(
            result.output.contains("cannot convert value of type 'PageID' to expected argument type 'SourceID'"),
            "unexpected compiler diagnostic:\n\(result.output)"
        )
    }

    @Test func sourceIDIsRejectedByPageAPI() throws {
        let result = try runTypecheck("source-id-to-page-api.swift")
        #expect(result.status != 0, "SourceID unexpectedly typechecked at a PageID API boundary.")
        #expect(
            result.output.contains("cannot convert value of type 'SourceID' to expected argument type 'PageID'"),
            "unexpected compiler diagnostic:\n\(result.output)"
        )
    }
}
