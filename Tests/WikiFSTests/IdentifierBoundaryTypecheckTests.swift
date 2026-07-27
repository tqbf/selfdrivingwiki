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
        var arguments = [
            "swiftc", "-typecheck",
            "-I", modules.path,
            "-module-cache-path", scratchDirectory.path,
            fixtureURL(fixtureName).path,
        ]
        arguments.insert(contentsOf: compilerSearchArguments(root: root), at: 4)
        process.arguments = arguments
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

    private func compilerSearchArguments(root: URL) -> [String] {
        var arguments: [String] = []
        let fileManager = FileManager.default

        let candidateDirectories = [
            root.appendingPathComponent("Sources/CSQLite"),
            root.appendingPathComponent(".build/checkouts/GRDB.swift/Sources/GRDBSQLite"),
            root.appendingPathComponent(".build/artifacts/tantivy.swift/TantivyRS/libtantivy-rs.xcframework/macos-arm64_x86_64/Headers"),
            root.appendingPathComponent(".build/artifacts/tantivy.swift/TantivyRS/libtantivy-rs.xcframework/linux-x86_64/Headers"),
        ]

        for directory in candidateDirectories where fileManager.fileExists(atPath: directory.path) {
            arguments += ["-Xcc", "-I\(directory.path)"]

            let moduleMap = directory.appendingPathComponent("module.modulemap")
            if fileManager.fileExists(atPath: moduleMap.path) {
                arguments += ["-Xcc", "-fmodule-map-file=\(moduleMap.path)"]
                continue
            }

            let tantivyModuleMap = directory.appendingPathComponent("tantivyFFI/module.modulemap")
            if fileManager.fileExists(atPath: tantivyModuleMap.path) {
                arguments += ["-Xcc", "-fmodule-map-file=\(tantivyModuleMap.path)"]
            }
        }

        return arguments
    }

    @Test func positiveFixturesCompile() throws {
        let result = try runTypecheck("positive.swift")
        #expect(result.status == 0, "positive fixture failed to typecheck:\n\(result.output)")
    }

    #if os(macOS)
    @Test func launcherPositiveFixturesCompile() throws {
        let result = try runTypecheck("positive-launcher-macos.swift")
        #expect(result.status == 0, "launcher positive fixture failed to typecheck:\n\(result.output)")
    }
    #endif

    @Test func pageIDIsRejectedByChatAPI() throws {
        let result = try runTypecheck("page-id-to-chat-api.swift")
        #expect(result.status != 0, "PageID unexpectedly typechecked at a ChatID API boundary.")
        #expect(
            result.output.contains("cannot convert value of type 'PageID' to expected argument type 'ChatID'"),
            "unexpected compiler diagnostic:\n\(result.output)"
        )
    }

    #if os(macOS)
    @Test func pageIDIsRejectedByLauncherChatAPI() throws {
        let result = try runTypecheck("page-id-to-launcher-chat-api.swift")
        #expect(result.status != 0, "PageID unexpectedly typechecked at AgentLauncher.startInteractiveQuery(chatID:).")
        #expect(
            result.output.contains("cannot convert value of type 'PageID' to expected argument type 'ChatID'"),
            "unexpected compiler diagnostic:\n\(result.output)"
        )
    }

    @Test func stringIsRejectedByLauncherChatAPI() throws {
        let result = try runTypecheck("string-to-launcher-chat-api.swift")
        #expect(result.status != 0, "String unexpectedly typechecked at AgentLauncher.startInteractiveQuery(chatID:).")
        #expect(
            result.output.contains("cannot convert value of type 'String' to expected argument type 'ChatID'"),
            "unexpected compiler diagnostic:\n\(result.output)"
        )
    }
    #endif

    @Test func pageIDIsRejectedBySourceAPI() throws {
        let result = try runTypecheck("page-id-to-source-api.swift")
        #expect(result.status != 0, "PageID unexpectedly typechecked at a SourceID API boundary.")
        #expect(
            result.output.contains("cannot convert value of type 'PageID' to expected argument type 'SourceID'"),
            "unexpected compiler diagnostic:\n\(result.output)"
        )
    }

    @Test func pageIDIsRejectedBySourceVersionAPI() throws {
        let result = try runTypecheck("page-id-to-source-version-api.swift")
        #expect(result.status != 0, "PageID unexpectedly typechecked at a SourceVersionID API boundary.")
        #expect(
            result.output.contains("cannot convert value of type 'PageID' to expected argument type 'SourceVersionID'"),
            "unexpected compiler diagnostic:\n\(result.output)"
        )
    }

    @Test func chatIDIsRejectedByPageAPI() throws {
        let result = try runTypecheck("chat-id-to-page-api.swift")
        #expect(result.status != 0, "ChatID unexpectedly typechecked at a PageID API boundary.")
        #expect(
            result.output.contains("cannot convert value of type 'ChatID' to expected argument type 'PageID'"),
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

    @Test func sourceIDIsRejectedBySourceVersionAPI() throws {
        let result = try runTypecheck("source-id-to-source-version-api.swift")
        #expect(result.status != 0, "SourceID unexpectedly typechecked at a SourceVersionID API boundary.")
        #expect(
            result.output.contains("cannot convert value of type 'SourceID' to expected argument type 'SourceVersionID'"),
            "unexpected compiler diagnostic:\n\(result.output)"
        )
    }

    @Test func sourceIDIsRejectedByChatAPI() throws {
        let result = try runTypecheck("source-id-to-chat-api.swift")
        #expect(result.status != 0, "SourceID unexpectedly typechecked at a ChatID API boundary.")
        #expect(
            result.output.contains("cannot convert value of type 'SourceID' to expected argument type 'ChatID'"),
            "unexpected compiler diagnostic:\n\(result.output)"
        )
    }

    @Test func chatIDIsRejectedBySourceAPI() throws {
        let result = try runTypecheck("chat-id-to-source-api.swift")
        #expect(result.status != 0, "ChatID unexpectedly typechecked at a SourceID API boundary.")
        #expect(
            result.output.contains("cannot convert value of type 'ChatID' to expected argument type 'SourceID'"),
            "unexpected compiler diagnostic:\n\(result.output)"
        )
    }

    @Test func markdownVersionIDIsRejectedBySourceVersionAPI() throws {
        let result = try runTypecheck("markdown-version-id-to-source-version-api.swift")
        #expect(result.status != 0, "SourceMarkdownVersion.id unexpectedly typechecked at a SourceVersionID API boundary.")
        #expect(
            result.output.contains("cannot convert value of type 'PageID' to expected argument type 'SourceVersionID'"),
            "unexpected compiler diagnostic:\n\(result.output)"
        )
    }

    @Test func sourceVersionIDIsRejectedBySourceAPI() throws {
        let result = try runTypecheck("source-version-id-to-source-api.swift")
        #expect(result.status != 0, "SourceVersionID unexpectedly typechecked at a SourceID API boundary.")
        #expect(
            result.output.contains("cannot convert value of type 'SourceVersionID' to expected argument type 'SourceID'"),
            "unexpected compiler diagnostic:\n\(result.output)"
        )
    }
}
