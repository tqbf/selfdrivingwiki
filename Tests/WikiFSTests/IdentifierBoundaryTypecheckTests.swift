import Foundation
import Testing

/// Runs small fixtures through `swiftc -typecheck` against the modules that
/// SwiftPM built for this test run. This proves the namespace boundary at the
/// compiler level, rather than only observing runtime behavior.
///
/// `.serialized` AND `.timeLimit(.minutes(2))` (issue #1051): each test spawns
/// `swiftc -typecheck` as a subprocess. The original implementation used
/// `Process.waitUntilExit()` — a synchronous call that parks the cooperative
/// thread pool thread the test is running on. Under `--parallel` with multiple
/// non-`.serialized` suites scheduled concurrently, 26 simultaneous
/// `waitUntilExit()` calls can exhaust the pool, starving other suites'
/// `withCheckedContinuation` completions (same bug class as #664/#732/#926).
/// The async `terminationHandler` + `CheckedContinuation` pattern below is
/// non-blocking; `.serialized` + `.timeLimit` are the safety net.
@Suite(.serialized, .timeLimit(.minutes(3)))
struct IdentifierBoundaryTypecheckTests {
    private struct FixtureCase: Sendable {
        let label: String
        let batchFixture: String
        let expectedDiagnostic: String
    }

    private struct BatchFixture: Sendable {
        let name: String
        let cases: [FixtureCase]

        var fixtureURL: URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Tests/WikiFSTests/Fixtures/IdentifierBoundaryTypecheck")
                .appendingPathComponent(name)
        }
    }

    private static let batchFixtures: [BatchFixture] = [
        BatchFixture(
            name: "negative-core-batch.swift",
            cases: [
                .init(label: "chatIDIsRejectedByChatMessageAPI", batchFixture: "negative-core-batch.swift", expectedDiagnostic: "cannot convert value of type 'ChatID' to expected argument type 'ChatMessageID'"),
                .init(label: "chatIDIsRejectedByPageAPI", batchFixture: "negative-core-batch.swift", expectedDiagnostic: "cannot convert value of type 'ChatID' to expected argument type 'PageID'"),
                .init(label: "chatIDIsRejectedByProcessedMarkdownVersionAPI", batchFixture: "negative-core-batch.swift", expectedDiagnostic: "cannot convert value of type 'ChatID' to expected argument type 'SourceMarkdownVersionID'"),
                .init(label: "chatIDIsRejectedBySourceAPI", batchFixture: "negative-core-batch.swift", expectedDiagnostic: "cannot convert value of type 'ChatID' to expected argument type 'SourceID'"),
                .init(label: "markdownVersionIDIsRejectedBySourceVersionAPI", batchFixture: "negative-core-batch.swift", expectedDiagnostic: "cannot convert value of type 'SourceMarkdownVersionID' to expected argument type 'SourceVersionID'"),
                .init(label: "pageIDIsRejectedByChatAPI", batchFixture: "negative-core-batch.swift", expectedDiagnostic: "cannot convert value of type 'PageID' to expected argument type 'ChatID'"),
                .init(label: "pageIDIsRejectedByChatTurnAPI", batchFixture: "negative-core-batch.swift", expectedDiagnostic: "cannot convert value of type 'PageID' to expected argument type 'ChatTurnID'"),
                .init(label: "pageIDIsRejectedByProcessedMarkdownVersionAPI", batchFixture: "negative-core-batch.swift", expectedDiagnostic: "cannot convert value of type 'PageID' to expected argument type 'SourceMarkdownVersionID'"),
                .init(label: "pageIDIsRejectedBySourceAPI", batchFixture: "negative-core-batch.swift", expectedDiagnostic: "cannot convert value of type 'PageID' to expected argument type 'SourceID'"),
                .init(label: "pageIDIsRejectedBySourceVersionAPI", batchFixture: "negative-core-batch.swift", expectedDiagnostic: "cannot convert value of type 'PageID' to expected argument type 'SourceVersionID'"),
                .init(label: "permissionRequestIDIsRejectedByToolCallAPI", batchFixture: "negative-core-batch.swift", expectedDiagnostic: "cannot convert value of type 'PermissionRequestID' to expected argument type 'ToolCallID'"),
                .init(label: "sourceIDIsRejectedByChatAPI", batchFixture: "negative-core-batch.swift", expectedDiagnostic: "cannot convert value of type 'SourceID' to expected argument type 'ChatID'"),
                .init(label: "sourceIDIsRejectedByPageAPI", batchFixture: "negative-core-batch.swift", expectedDiagnostic: "cannot convert value of type 'SourceID' to expected argument type 'PageID'"),
                .init(label: "sourceIDIsRejectedByProcessedMarkdownVersionAPI", batchFixture: "negative-core-batch.swift", expectedDiagnostic: "cannot convert value of type 'SourceID' to expected argument type 'SourceMarkdownVersionID'"),
                .init(label: "sourceIDIsRejectedBySourceVersionAPI", batchFixture: "negative-core-batch.swift", expectedDiagnostic: "cannot convert value of type 'SourceID' to expected argument type 'SourceVersionID'"),
                .init(label: "sourceVersionIDIsRejectedByChatAPI", batchFixture: "negative-core-batch.swift", expectedDiagnostic: "cannot convert value of type 'SourceVersionID' to expected argument type 'ChatID'"),
                .init(label: "sourceVersionIDIsRejectedByPageAPI", batchFixture: "negative-core-batch.swift", expectedDiagnostic: "cannot convert value of type 'SourceVersionID' to expected argument type 'PageID'"),
                .init(label: "sourceVersionIDIsRejectedByProcessedMarkdownVersionAPI", batchFixture: "negative-core-batch.swift", expectedDiagnostic: "cannot convert value of type 'SourceVersionID' to expected argument type 'SourceMarkdownVersionID'"),
                .init(label: "sourceVersionIDIsRejectedBySetActiveMarkdownAPI", batchFixture: "negative-core-batch.swift", expectedDiagnostic: "cannot convert value of type 'SourceVersionID' to expected argument type 'SourceMarkdownVersionID'"),
                .init(label: "sourceVersionIDIsRejectedBySourceAPI", batchFixture: "negative-core-batch.swift", expectedDiagnostic: "cannot convert value of type 'SourceVersionID' to expected argument type 'SourceID'"),
                .init(label: "stringIsRejectedByChatCommandAPI", batchFixture: "negative-core-batch.swift", expectedDiagnostic: "cannot convert value of type 'String' to expected argument type 'ChatCommandID'"),
            ]
        ),
        BatchFixture(
            name: "negative-launcher-batch.swift",
            cases: [
                .init(label: "pageIDIsRejectedByLauncherChatAPI", batchFixture: "negative-launcher-batch.swift", expectedDiagnostic: "cannot convert value of type 'PageID' to expected argument type 'ChatID'"),
                .init(label: "stringIsRejectedByLauncherChatAPI", batchFixture: "negative-launcher-batch.swift", expectedDiagnostic: "cannot convert value of type 'String' to expected argument type 'ChatID'"),
            ]
        ),
    ]

    private static let positiveFixtures: [String] = [
        "positive.swift",
    ]

    private static let expectedBoundaryLabels: Set<String> = [
        "chatIDIsRejectedByChatMessageAPI",
        "chatIDIsRejectedByPageAPI",
        "chatIDIsRejectedByProcessedMarkdownVersionAPI",
        "chatIDIsRejectedBySourceAPI",
        "markdownVersionIDIsRejectedBySourceVersionAPI",
        "pageIDIsRejectedByChatAPI",
        "pageIDIsRejectedByChatTurnAPI",
        "pageIDIsRejectedByLauncherChatAPI",
        "pageIDIsRejectedByProcessedMarkdownVersionAPI",
        "pageIDIsRejectedBySourceAPI",
        "pageIDIsRejectedBySourceVersionAPI",
        "permissionRequestIDIsRejectedByToolCallAPI",
        "sourceIDIsRejectedByChatAPI",
        "sourceIDIsRejectedByPageAPI",
        "sourceIDIsRejectedByProcessedMarkdownVersionAPI",
        "sourceIDIsRejectedBySourceVersionAPI",
        "sourceVersionIDIsRejectedByChatAPI",
        "sourceVersionIDIsRejectedByPageAPI",
        "sourceVersionIDIsRejectedByProcessedMarkdownVersionAPI",
        "sourceVersionIDIsRejectedBySetActiveMarkdownAPI",
        "sourceVersionIDIsRejectedBySourceAPI",
        "stringIsRejectedByChatCommandAPI",
        "stringIsRejectedByLauncherChatAPI",
    ]

    private enum ProcessExitWaitError: Error {
        case timedOut
    }

    private final class ProcessExitWaiter: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var result: Result<Void, Error>?

        func install(_ continuation: CheckedContinuation<Void, Error>) {
            let result: Result<Void, Error>?
            lock.lock()
            if let storedResult = self.result {
                result = storedResult
            } else {
                self.continuation = continuation
                result = nil
            }
            lock.unlock()
            if let result {
                continuation.resume(with: result)
            }
        }

        @discardableResult
        func finish(_ result: Result<Void, Error>) -> Bool {
            let continuation: CheckedContinuation<Void, Error>?
            lock.lock()
            guard self.result == nil else {
                lock.unlock()
                return false
            }
            self.result = result
            continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
            return true
        }
    }

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

    private func allBoundaryCases() -> [FixtureCase] {
        Self.batchFixtures.flatMap(\.cases)
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

    private func runTypecheck(fixtureName: String) async throws -> CompilerResult {
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

        try await asyncWaitUntilExit(process)

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        return CompilerResult(
            status: process.terminationStatus,
            output: String(decoding: outputData, as: UTF8.self)
        )
    }

    private func runTypecheck(_ batch: BatchFixture) async throws -> CompilerResult {
        let root = repositoryRoot()
        let buildProducts = try buildProducts(for: batch.name)
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
            batch.fixtureURL.path,
        ]
        arguments.insert(contentsOf: compilerSearchArguments(root: root, buildProducts: buildProducts), at: 6)
        process.arguments = arguments
        process.currentDirectoryURL = root

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()

        try await asyncWaitUntilExit(process)

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        return CompilerResult(
            status: process.terminationStatus,
            output: String(decoding: outputData, as: UTF8.self)
        )
    }

    private func asyncWaitUntilExit(_ process: Process, timeout: Duration = .seconds(30)) async throws {
        let waiter = ProcessExitWaiter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        waiter.install(cont)
                        process.terminationHandler = { _ in
                            waiter.finish(.success(()))
                        }
                        if !process.isRunning {
                            waiter.finish(.success(()))
                        }
                    }
                } onCancel: {
                    if waiter.finish(.failure(CancellationError())), process.isRunning {
                        process.terminate()
                    }
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                guard waiter.finish(.failure(ProcessExitWaitError.timedOut)) else { return }
                if process.isRunning {
                    process.terminate()
                }
                throw ProcessExitWaitError.timedOut
            }
            _ = try await group.next()
            group.cancelAll()
        }
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
            buildProducts.debugDirectory.appendingPathComponent("CRendererPackageMove.build"),
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

    @Test func fixtureTablePreservesAllNamedBoundaries() {
        let labels = Set(allBoundaryCases().map(\.label))
        #expect(labels == Self.expectedBoundaryLabels)
    }

    @Test func positiveFixturesCompile() async throws {
        let result = try await runTypecheck(fixtureName: Self.positiveFixtures[0])
        #expect(result.status == 0, "positive fixture failed to typecheck:\n\(result.output)")
    }

    #if canImport(WikiFSEngine)
    @Test func positiveChatDomainFixturesCompile() async throws {
        let result = try await runTypecheck(fixtureName: "positive-chat-domain.swift")
        #expect(result.status == 0, "positive chat-domain fixture failed to typecheck:\n\(result.output)")
    }
    #endif

    #if os(macOS)
    @Test func launcherPositiveFixturesCompile() async throws {
        let result = try await runTypecheck(fixtureName: "positive-launcher-macos.swift")
        #expect(result.status == 0, "launcher positive fixture failed to typecheck:\n\(result.output)")
    }
    #endif

    @Test func negativeFixturesCompileAndMapBoundaries() async throws {
        for batch in Self.batchFixtures {
            let result = try await runTypecheck(batch)
            #expect(
                result.status != 0,
                "\(batch.name) unexpectedly typechecked; expected boundary diagnostics:\n\(result.output)"
            )

            for expectedCase in batch.cases {
                #expect(
                    result.output.contains(expectedCase.expectedDiagnostic),
                    "missing boundary \(expectedCase.label) in \(expectedCase.batchFixture):\n\(result.output)"
                )
            }

            let emittedDiagnostics = batch.cases.filter { result.output.contains($0.expectedDiagnostic) }
            #expect(
                emittedDiagnostics.count == batch.cases.count,
                "batch \(batch.name) omitted one or more expected boundaries; expected \(batch.cases.count), saw \(emittedDiagnostics.count)"
            )
        }
    }
}
