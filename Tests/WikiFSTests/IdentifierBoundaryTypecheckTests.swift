import Foundation
import Testing

/// Runs small fixtures through `swiftc -typecheck` against the modules that
/// SwiftPM built for this test run. This proves the namespace boundary at the
/// compiler level, rather than only observing runtime behavior.
struct IdentifierBoundaryTypecheckTests {

    private struct BuildProducts {
        let debugDirectory: URL
        let modulesDirectory: URL
    }

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

    private func buildProducts(for fixtureName: String) throws -> BuildProducts {
        let buildDirectory = repositoryRoot().appendingPathComponent(".build")
        let fileManager = FileManager.default
        let requiredModules = try requiredFixtureModules(fixtureName)
        let enumerator = try #require(
            fileManager.enumerator(
                at: buildDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        )
        var candidates: [BuildProducts] = []

        for case let candidate as URL in enumerator
        where candidate.lastPathComponent == "Modules"
            && candidate.deletingLastPathComponent().lastPathComponent == "debug" {
            guard requiredModules.allSatisfy({
                fileManager.fileExists(atPath: candidate.appendingPathComponent("\($0).swiftmodule").path)
            }) else {
                continue
            }
            candidates.append(
                BuildProducts(
                    debugDirectory: candidate.deletingLastPathComponent(),
                    modulesDirectory: candidate
                )
            )
        }

        let sortedCandidates = candidates.sorted { lhs, rhs in
            candidateSortKey(lhs) < candidateSortKey(rhs)
        }
        return try #require(
            sortedCandidates.first,
            """
            SwiftPM did not build the modules required by \(fixtureName).
            Required: \(requiredModules.sorted().joined(separator: ", "))
            Looked under: \(buildDirectory.path)
            """
        )
    }

    private func runTypecheck(_ fixtureName: String) throws -> CompilerResult {
        let root = repositoryRoot()
        let buildProducts = try buildProducts(for: fixtureName)
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
            "-target", typecheckTargetTriple(),
            "-I", buildProducts.debugDirectory.path,
            "-I", buildProducts.modulesDirectory.path,
            "-module-cache-path", scratchDirectory.path,
            fixtureURL(fixtureName).path,
        ]
        arguments.insert(contentsOf: compilerSearchArguments(root: root, buildProducts: buildProducts), at: 6)
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

    private func typecheckTargetTriple() -> String {
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif

        #if os(macOS)
        return "\(architecture)-apple-macosx26.0"
        #elseif os(Linux)
        return "\(architecture)-unknown-linux-gnu"
        #else
        return "\(architecture)-unknown-unknown"
        #endif
    }

    private func requiredFixtureModules(_ fixtureName: String) throws -> Set<String> {
        let source = try String(contentsOf: fixtureURL(fixtureName), encoding: .utf8)
        let importedModules = source
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") else {
                    return nil
                }
                let importedModule = trimmed
                    .dropFirst("import ".count)
                    .split(whereSeparator: \.isWhitespace)
                    .last
                guard let importedModule else {
                    return nil
                }
                return String(importedModule)
            }
            .filter { $0.hasPrefix("Wiki") }

        return Set(importedModules)
    }

    private func candidateSortKey(_ candidate: BuildProducts) -> (Int, Int, String) {
        let path = candidate.modulesDirectory.path
        let isAuxiliary = path.contains("/index-build/") || path.contains("/analyze/")
        return (isAuxiliary ? 1 : 0, path.count, path)
    }

    private func compilerSearchArguments(root: URL, buildProducts: BuildProducts) -> [String] {
        var arguments: [String] = []
        let fileManager = FileManager.default

        let candidateDirectories = [
            buildProducts.debugDirectory.appendingPathComponent("GRDB.build/include"),
            buildProducts.debugDirectory.appendingPathComponent("TantivyFFI.build/include"),
            buildProducts.debugDirectory.appendingPathComponent("TantivySwift.build/include"),
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

    @Test func positiveChatDomainFixturesCompile() throws {
        let result = try runTypecheck("positive-chat-domain.swift")
        #expect(result.status == 0, "positive chat-domain fixture failed to typecheck:\n\(result.output)")
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
            result.output.contains("cannot convert value of type 'SourceMarkdownVersionID' to expected argument type 'SourceVersionID'"),
            "unexpected compiler diagnostic:\n\(result.output)"
        )
    }

    @Test func pageIDIsRejectedByProcessedMarkdownVersionAPI() throws {
        let result = try runTypecheck("page-id-to-processed-markdown-version-api.swift")
        #expect(result.status != 0, "PageID unexpectedly typechecked at processedMarkdownVersion(id:).")
        #expect(
            result.output.contains("cannot convert value of type 'PageID' to expected argument type 'SourceMarkdownVersionID'"),
            "unexpected compiler diagnostic:\n\(result.output)"
        )
    }

    @Test func sourceIDIsRejectedByProcessedMarkdownVersionAPI() throws {
        let result = try runTypecheck("source-id-to-processed-markdown-version-api.swift")
        #expect(result.status != 0, "SourceID unexpectedly typechecked at processedMarkdownVersion(id:).")
        #expect(
            result.output.contains("cannot convert value of type 'SourceID' to expected argument type 'SourceMarkdownVersionID'"),
            "unexpected compiler diagnostic:\n\(result.output)"
        )
    }

    @Test func chatIDIsRejectedByProcessedMarkdownVersionAPI() throws {
        let result = try runTypecheck("chat-id-to-processed-markdown-version-api.swift")
        #expect(result.status != 0, "ChatID unexpectedly typechecked at processedMarkdownVersion(id:).")
        #expect(
            result.output.contains("cannot convert value of type 'ChatID' to expected argument type 'SourceMarkdownVersionID'"),
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

    @Test func sourceVersionIDIsRejectedByProcessedMarkdownVersionAPI() throws {
        let result = try runTypecheck("source-version-id-to-processed-markdown-version-api.swift")
        #expect(result.status != 0, "SourceVersionID unexpectedly typechecked at processedMarkdownVersion(id:).")
        #expect(
            result.output.contains("cannot convert value of type 'SourceVersionID' to expected argument type 'SourceMarkdownVersionID'"),
            "unexpected compiler diagnostic:\n\(result.output)"
        )
    }

    @Test func sourceVersionIDIsRejectedBySetActiveMarkdownAPI() throws {
        let result = try runTypecheck("source-version-id-to-set-active-markdown-api.swift")
        #expect(result.status != 0, "SourceVersionID unexpectedly typechecked at setActiveMarkdown(sourceID:to:).")
        #expect(
            result.output.contains("cannot convert value of type 'SourceVersionID' to expected argument type 'SourceMarkdownVersionID'"),
            "unexpected compiler diagnostic:\n\(result.output)"
        )
    }

    @Test func sourceVersionIDIsRejectedByPageAPI() throws {
        let result = try runTypecheck("source-version-id-to-page-api.swift")
        #expect(result.status != 0, "SourceVersionID unexpectedly typechecked at a PageID API boundary.")
        #expect(
            result.output.contains("cannot convert value of type 'SourceVersionID' to expected argument type 'PageID'"),
            "unexpected compiler diagnostic:\n\(result.output)"
        )
    }

    @Test func sourceVersionIDIsRejectedByChatAPI() throws {
        let result = try runTypecheck("source-version-id-to-chat-api.swift")
        #expect(result.status != 0, "SourceVersionID unexpectedly typechecked at a ChatID API boundary.")
        #expect(
            result.output.contains("cannot convert value of type 'SourceVersionID' to expected argument type 'ChatID'"),
            "unexpected compiler diagnostic:\n\(result.output)"
        )
    }

    @Test func pageIDIsRejectedByChatTurnAPI() throws {
        let result = try runTypecheck("page-id-to-chat-turn-api.swift")
        #expect(result.status != 0, "PageID unexpectedly typechecked at a ChatTurnID API boundary.")
        #expect(
            result.output.contains("cannot convert value of type 'PageID' to expected argument type 'ChatTurnID'"),
            "unexpected compiler diagnostic:\n\(result.output)"
        )
    }

    @Test func chatIDIsRejectedByChatMessageAPI() throws {
        let result = try runTypecheck("chat-id-to-chat-message-api.swift")
        #expect(result.status != 0, "ChatID unexpectedly typechecked at a ChatMessageID API boundary.")
        #expect(
            result.output.contains("cannot convert value of type 'ChatID' to expected argument type 'ChatMessageID'"),
            "unexpected compiler diagnostic:\n\(result.output)"
        )
    }

    @Test func stringIsRejectedByChatCommandAPI() throws {
        let result = try runTypecheck("string-to-chat-command-api.swift")
        #expect(result.status != 0, "String unexpectedly typechecked at a ChatCommandID API boundary.")
        #expect(
            result.output.contains("cannot convert value of type 'String' to expected argument type 'ChatCommandID'"),
            "unexpected compiler diagnostic:\n\(result.output)"
        )
    }

    @Test func permissionRequestIDIsRejectedByToolCallAPI() throws {
        let result = try runTypecheck("permission-request-id-to-tool-call-api.swift")
        #expect(result.status != 0, "PermissionRequestID unexpectedly typechecked at a ToolCallID API boundary.")
        #expect(
            result.output.contains("cannot convert value of type 'PermissionRequestID' to expected argument type 'ToolCallID'"),
            "unexpected compiler diagnostic:\n\(result.output)"
        )
    }
}
