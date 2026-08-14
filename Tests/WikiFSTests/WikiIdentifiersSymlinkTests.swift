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
/// as Nix/Homebrew/`ln -s` all create) searched only `~/.local/bin`, where no
/// sidecar exists and the `signing/local.config` walk-up finds no repo.
/// Resolution then fell through to the compiled-in `group.org.sockpuppet.wiki`
/// — a DIFFERENT, empty container. The symptom was that the exact same binary
/// resolved every wiki by its bundle path and reported "no wiki matching <id>
/// in the registry" through the symlink.
///
/// The contract is additive: the INVOKED directory is still searched first and
/// is never dropped, and the symlink-resolved directory is appended.
struct WikiIdentifiersSymlinkTests {

    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-ids-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeFile(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    private func isSame(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().path == rhs.resolvingSymlinksInPath().path
    }

    /// The headline repro: a shim on `PATH` pointing at a binary elsewhere must
    /// also search the REAL binary's directory, so the bundled sidecar is found.
    /// The invoked directory stays first — the fix adds a candidate, it does not
    /// replace one.
    @Test func symlinkedExecutableAlsoSearchesItsRealDirectory() throws {
        let root = try tempDirectory()
        let helpers = root.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let shimDir = root.appendingPathComponent("local/bin", isDirectory: true)
        let real = helpers.appendingPathComponent("wikictl")
        try makeFile(at: real)
        try FileManager.default.createDirectory(at: shimDir, withIntermediateDirectories: true)
        let shim = shimDir.appendingPathComponent("wikictl")
        try FileManager.default.createSymbolicLink(at: shim, withDestinationURL: real)

        let candidates = WikiIdentifiers.candidateExecutableDirectories(for: shim)

        #expect(candidates.count == 2)
        #expect(isSame(candidates[0], shimDir), "the invoked directory must be searched first")
        #expect(isSame(candidates[1], helpers), "the symlink target's directory must be searched too")
    }

    /// A sidecar deliberately placed beside the shim must still win. This is the
    /// property a resolve-only fix would break — it would search the target's
    /// directory instead of the shim's, silently ignoring local config.
    @Test func invokedDirectoryOutranksTheSymlinkTarget() throws {
        let root = try tempDirectory()
        let helpers = root.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let shimDir = root.appendingPathComponent("local/bin", isDirectory: true)
        let real = helpers.appendingPathComponent("wikictl")
        try makeFile(at: real)
        try FileManager.default.createDirectory(at: shimDir, withIntermediateDirectories: true)
        let shim = shimDir.appendingPathComponent("wikictl")
        try FileManager.default.createSymbolicLink(at: shim, withDestinationURL: real)

        let candidates = WikiIdentifiers.candidateExecutableDirectories(for: shim)

        #expect(candidates.first.map { isSame($0, shimDir) } == true)
    }

    /// A chain of symlinks (the shape Nix home-manager produces: `~/.local/bin`
    /// → a store path → the app bundle) must resolve all the way to the end.
    @Test func chainedSymlinksResolveToTheFinalTarget() throws {
        let root = try tempDirectory()
        let helpers = root.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let middleDir = root.appendingPathComponent("store/bin", isDirectory: true)
        let shimDir = root.appendingPathComponent("local/bin", isDirectory: true)
        let real = helpers.appendingPathComponent("wikictl")
        try makeFile(at: real)
        for dir in [middleDir, shimDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let middle = middleDir.appendingPathComponent("wikictl")
        try FileManager.default.createSymbolicLink(at: middle, withDestinationURL: real)
        let shim = shimDir.appendingPathComponent("wikictl")
        try FileManager.default.createSymbolicLink(at: shim, withDestinationURL: middle)

        let candidates = WikiIdentifiers.candidateExecutableDirectories(for: shim)

        #expect(candidates.count == 2)
        #expect(candidates.last.map { isSame($0, helpers) } == true)
    }

    /// A plain, non-symlinked executable yields exactly ONE directory — the
    /// in-bundle and `swift build` invocation paths must not start doing extra
    /// filesystem probes.
    @Test func plainExecutableYieldsOneDirectory() throws {
        let root = try tempDirectory()
        let real = root.appendingPathComponent("Contents/Helpers/wikictl")
        try makeFile(at: real)

        let candidates = WikiIdentifiers.candidateExecutableDirectories(for: real)

        #expect(candidates.count == 1)
        #expect(candidates.first.map { isSame($0, real.deletingLastPathComponent()) } == true)
    }

    /// A plain executable under a SYMLINKED PARENT (the `/var` → `/private/var`
    /// shape, which `FileManager.temporaryDirectory` actually produces on macOS)
    /// must also collapse to one entry. Two spellings of the same directory are
    /// not two candidates.
    @Test func symlinkedParentDirectoryDoesNotDuplicateTheCandidate() throws {
        let root = try tempDirectory()
        let realParent = root.appendingPathComponent("real/Helpers", isDirectory: true)
        let binary = realParent.appendingPathComponent("wikictl")
        try makeFile(at: binary)
        // A symlinked ANCESTOR, but the binary itself is not a symlink.
        let linkedParent = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: linkedParent, withDestinationURL: root.appendingPathComponent("real", isDirectory: true))

        let viaLink = linkedParent.appendingPathComponent("Helpers/wikictl")
        let candidates = WikiIdentifiers.candidateExecutableDirectories(for: viaLink)

        #expect(candidates.count == 1, "same directory reached two ways is one candidate")
    }

    /// Resolution must not depend on the file existing — a path that has been
    /// deleted still yields its containing directory rather than trapping.
    @Test func missingExecutableStillYieldsItsDirectory() throws {
        let root = try tempDirectory()
        let ghost = root.appendingPathComponent("Contents/Helpers/wikictl")

        let candidates = WikiIdentifiers.candidateExecutableDirectories(for: ghost)

        #expect(candidates.count == 1)
        #expect(candidates.first?.lastPathComponent == "Helpers")
    }

    /// The resolved candidate must still feed the `.app`-ancestor walk that the
    /// bundled `wikictl` and the nested `wikid.xpc` daemon rely on (#887). The
    /// shim's own directory is outside any `.app`, so only the resolved entry
    /// can find the app-level sidecar.
    @Test func resolvedCandidateStillFindsEnclosingAppResources() throws {
        let root = try tempDirectory()
        let app = root.appendingPathComponent("Self Driving Wiki.app", isDirectory: true)
        let helpers = app.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let shimDir = root.appendingPathComponent("local/bin", isDirectory: true)
        let real = helpers.appendingPathComponent("wikictl")
        try makeFile(at: real)
        try FileManager.default.createDirectory(at: shimDir, withIntermediateDirectories: true)
        let shim = shimDir.appendingPathComponent("wikictl")
        try FileManager.default.createSymbolicLink(at: shim, withDestinationURL: real)

        let candidates = WikiIdentifiers.candidateExecutableDirectories(for: shim)
        let resources = candidates.compactMap { WikiIdentifiers.enclosingAppResourcesDirectory(from: $0) }

        #expect(resources.count == 1, "only the resolved candidate is inside the .app")
        #expect(resources.first?.lastPathComponent == "Resources")
        #expect(resources.first?.path.contains("Self Driving Wiki.app") == true)
    }
}
