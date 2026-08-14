import Foundation
import Testing
@testable import WikiFSCore

/// Regression tests for per-developer id resolution through a `PATH` symlink.
///
/// `WikiIdentifiers` resolves `appGroupID` from, in order: an env var, the
/// `Bundle.main` Info.plist, a `wiki-identifiers.env` sidecar next to the
/// executable, `signing/local.config`, then a compiled-in default. The sidecar
/// leg is the only one that works for the bundled `wikictl` — a plain CLI with
/// no Info.plist — and it is located relative to the running executable.
///
/// `Bundle.main.executableURL` reports the path the process was EXEC'd through,
/// not the real file. So invoking the bundled `wikictl` through a `PATH` shim
/// (`~/.local/bin/wikictl` → `…/Self Driving Wiki.app/Contents/Helpers/wikictl`,
/// as Nix/Homebrew/`ln -s` all create) put the search in `~/.local/bin`, where
/// no sidecar exists and the `signing/local.config` walk-up finds no repo.
/// Resolution then fell through to the compiled-in `group.org.sockpuppet.wiki`
/// — a DIFFERENT, empty container. The symptom was that the exact same binary
/// resolved every wiki by its bundle path and reported "no wiki matching <id>
/// in the registry" through the symlink.
struct WikiIdentifiersSymlinkTests {

    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-ids-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The headline repro: a shim on `PATH` pointing at a binary elsewhere must
    /// resolve to the REAL binary's directory, so the sidecar beside it is found.
    @Test func symlinkedExecutableResolvesToItsRealDirectory() throws {
        let root = try tempDirectory()
        let helpers = root.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let shimDir = root.appendingPathComponent("local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shimDir, withIntermediateDirectories: true)

        let real = helpers.appendingPathComponent("wikictl")
        try Data().write(to: real)
        let shim = shimDir.appendingPathComponent("wikictl")
        try FileManager.default.createSymbolicLink(at: shim, withDestinationURL: real)

        let resolved = WikiIdentifiers.directoryOfRealExecutable(at: shim)

        #expect(resolved.resolvingSymlinksInPath().path == helpers.resolvingSymlinksInPath().path)
        // The point of resolving: the sidecar next to the real binary is now in
        // reach, where searching from the shim's own directory would find nothing.
        #expect(resolved.path != shimDir.path)
    }

    /// A chain of symlinks (the shape Nix home-manager produces: `~/.local/bin`
    /// → a store path → the app bundle) must resolve all the way to the end.
    @Test func chainedSymlinksResolveToTheFinalTarget() throws {
        let root = try tempDirectory()
        let helpers = root.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let middleDir = root.appendingPathComponent("store/bin", isDirectory: true)
        let shimDir = root.appendingPathComponent("local/bin", isDirectory: true)
        for dir in [helpers, middleDir, shimDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let real = helpers.appendingPathComponent("wikictl")
        try Data().write(to: real)
        let middle = middleDir.appendingPathComponent("wikictl")
        try FileManager.default.createSymbolicLink(at: middle, withDestinationURL: real)
        let shim = shimDir.appendingPathComponent("wikictl")
        try FileManager.default.createSymbolicLink(at: shim, withDestinationURL: middle)

        let resolved = WikiIdentifiers.directoryOfRealExecutable(at: shim)

        #expect(resolved.resolvingSymlinksInPath().path == helpers.resolvingSymlinksInPath().path)
    }

    /// A plain, non-symlinked executable keeps behaving exactly as before — the
    /// in-bundle and `swift build` invocation paths must not regress.
    @Test func plainExecutableKeepsItsOwnDirectory() throws {
        let root = try tempDirectory()
        let helpers = root.appendingPathComponent("Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let real = helpers.appendingPathComponent("wikictl")
        try Data().write(to: real)

        let resolved = WikiIdentifiers.directoryOfRealExecutable(at: real)

        #expect(resolved.resolvingSymlinksInPath().path == helpers.resolvingSymlinksInPath().path)
    }

    /// Resolving must not depend on the file existing — a path that has been
    /// deleted still yields its containing directory rather than trapping.
    @Test func missingExecutableStillYieldsItsDirectory() throws {
        let root = try tempDirectory()
        let ghost = root.appendingPathComponent("Contents/Helpers/wikictl")

        let resolved = WikiIdentifiers.directoryOfRealExecutable(at: ghost)

        #expect(resolved.lastPathComponent == "Helpers")
    }

    /// The resolved directory must still feed the `.app`-ancestor walk that the
    /// bundled `wikictl` and the nested `wikid.xpc` daemon rely on.
    @Test func resolvedDirectoryStillFindsEnclosingAppResources() throws {
        let root = try tempDirectory()
        let app = root.appendingPathComponent("Self Driving Wiki.app", isDirectory: true)
        let helpers = app.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let shimDir = root.appendingPathComponent("local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shimDir, withIntermediateDirectories: true)

        let real = helpers.appendingPathComponent("wikictl")
        try Data().write(to: real)
        let shim = shimDir.appendingPathComponent("wikictl")
        try FileManager.default.createSymbolicLink(at: shim, withDestinationURL: real)

        let resolved = WikiIdentifiers.directoryOfRealExecutable(at: shim)
        let resources = WikiIdentifiers.enclosingAppResourcesDirectory(from: resolved)

        #expect(resources?.lastPathComponent == "Resources")
        #expect(resources?.path.contains("Self Driving Wiki.app") == true)
    }
}
