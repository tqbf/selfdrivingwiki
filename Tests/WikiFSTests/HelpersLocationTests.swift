import Foundation
import Testing
@testable import WikiFSCore

/// AC.5 (`plans/acp-adapter-vendoring.md`): the seam-injected core of
/// `HelpersLocation.bundledHelperPath`. The production candidate directories
/// derive from `Bundle.main` at call time and cannot be fixture-built inside
/// a test process, so the internal overload takes the candidate directories
/// and the FileManager explicitly; these tests pin the contract the public
/// method must preserve — candidate priority, executability filtering, and
/// nil when nothing resolves (the shape `WikiFSApp`'s vendored-adapter launch
/// check and `AgentLauncher.bundledHelperPath` depend on).
@Suite struct HelpersLocationTests {
    private let fileManager = FileManager.default

    /// Build a fixture directory holding the named files, each marked
    /// executable (`0o755`) or read-only (`0o644`). Cleanup is the caller's
    /// job — `removeFixture` in a `defer` at test scope (a defer inside this
    /// helper would fire before the test body runs).
    private func makeFixtureDirectory(
        _ files: [String: Bool]
    ) throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appending(path: "HelpersLocationTests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, executable) in files {
            let fileURL = directory.appending(path: name)
            try Data("#!/bin/sh\n".utf8).write(to: fileURL)
            try fileManager.setAttributes(
                [.posixPermissions: executable ? 0o755 : 0o644],
                ofItemAtPath: fileURL.path)
        }
        return directory
    }

    private func removeFixture(_ directory: URL) {
        do {
            try fileManager.removeItem(at: directory)
        } catch {
            Issue.record("fixture cleanup failed for \(directory.path): \(error)")
        }
    }

    /// A non-executable candidate file is skipped: a helper the OS cannot
    /// exec must not resolve (the production walk filters on
    /// `isExecutableFile` for exactly this).
    @Test func executabilityFilteringSkipsNonExecutableFiles() throws {
        let appHelpers = try makeFixtureDirectory(["claude-acp-adapter.js": false])
        defer { removeFixture(appHelpers) }
        let resolved = HelpersLocation.bundledHelperPath(
            "claude-acp-adapter.js",
            candidateDirectories: [appHelpers],
            fileManager: fileManager)
        #expect(resolved == nil)
    }

    /// The first candidate holding an EXECUTABLE copy wins — the app bundle's
    /// Contents/Helpers shadows the dev `build/` copy.
    @Test func candidatePriorityFirstExecutableWins() throws {
        let appHelpers = try makeFixtureDirectory(["claude-acp-adapter.js": true])
        let devBuild = try makeFixtureDirectory(["claude-acp-adapter.js": true])
        let exeDirectory = try makeFixtureDirectory([:])
        defer {
            removeFixture(appHelpers)
            removeFixture(devBuild)
            removeFixture(exeDirectory)
        }

        let resolved = HelpersLocation.bundledHelperPath(
            "claude-acp-adapter.js",
            candidateDirectories: [appHelpers, devBuild, exeDirectory],
            fileManager: fileManager)
        #expect(resolved == appHelpers.appending(path: "claude-acp-adapter.js").path)

        // A gap in the first candidate falls through to the next: the dev
        // build/ copy resolves when the app bundle lacks the helper.
        let resolvedFromDev = HelpersLocation.bundledHelperPath(
            "claude-acp-adapter.js",
            candidateDirectories: [exeDirectory, devBuild, appHelpers],
            fileManager: fileManager)
        #expect(resolvedFromDev == devBuild.appending(path: "claude-acp-adapter.js").path)
    }

    /// AC.5: the dev-build shape — a `build/` candidate holding the vendored
    /// adapter (what `./build.sh` drops next to the dev binaries) resolves
    /// for a `swift run` launch where no app bundle exists.
    @Test func devBuildCandidateResolvesVendoredAdapter() throws {
        let devBuild = try makeFixtureDirectory(["claude-acp-adapter.js": true])
        defer { removeFixture(devBuild) }
        let resolved = HelpersLocation.bundledHelperPath(
            "claude-acp-adapter.js",
            candidateDirectories: [devBuild],
            fileManager: fileManager)
        #expect(resolved == devBuild.appending(path: "claude-acp-adapter.js").path)
    }

    /// No candidate holds the helper → nil. `WikiFSApp`'s launch check warns
    /// on exactly this outcome.
    @Test func nilWhenNoCandidateHoldsTheHelper() throws {
        let empty = try makeFixtureDirectory([:])
        let wrongName = try makeFixtureDirectory(["wikictl": true])
        defer {
            removeFixture(empty)
            removeFixture(wrongName)
        }
        let resolved = HelpersLocation.bundledHelperPath(
            "claude-acp-adapter.js",
            candidateDirectories: [empty, wrongName],
            fileManager: fileManager)
        #expect(resolved == nil)
    }
}
