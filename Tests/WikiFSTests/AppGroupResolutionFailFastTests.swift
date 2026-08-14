import Foundation
import Testing
@testable import WikiFSCore

/// Tests for refusing to open a container under an App Group id nobody chose.
///
/// `appGroupContainerDirectory()` is the one place that turns the resolved id
/// into filesystem state, and it calls
/// `createDirectory(withIntermediateDirectories:)`. So an unresolved id never
/// failed — it MANUFACTURED a second, empty container and carried on. The
/// process then read an empty registry and wrote real config into the wrong
/// place, which is indistinguishable from a first run.
///
/// That silently happened in at least four launch contexts: a `.build/debug`
/// dev CLI, the nested `wikid.xpc` daemon (#887), a `PATH` symlink shim, and a
/// search reindex. Each was fixed by adding another resolution leg, which
/// cannot stop the next context from forking the same way. Refusing is what
/// closes the class.
struct AppGroupResolutionFailFastTests {

    private func tempHome() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func containerPath(in home: URL, id: String) -> URL {
        home.appendingPathComponent("Library/Group Containers", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    // MARK: - The refusal

    @Test func unconfiguredIDThrowsInsteadOfResolving() throws {
        let home = try tempHome()

        #expect(throws: WikiIdentifiersError.unconfiguredAppGroupID(
            fallback: "group.org.sockpuppet.wiki")) {
            _ = try DatabaseLocation.appGroupContainerDirectory(
                id: "group.org.sockpuppet.wiki", isConfigured: false, home: home)
        }
    }

    /// The damaging half: the old code created the directory before anyone could
    /// notice the id was wrong. Refusing must leave the filesystem untouched.
    @Test func unconfiguredIDCreatesNoContainer() throws {
        let home = try tempHome()
        let container = containerPath(in: home, id: "group.org.sockpuppet.wiki")

        _ = try? DatabaseLocation.appGroupContainerDirectory(
            id: "group.org.sockpuppet.wiki", isConfigured: false, home: home)

        #expect(!FileManager.default.fileExists(atPath: container.path),
                "the refusal must not manufacture a container")
        // Not even the intermediate directories.
        #expect(!FileManager.default.fileExists(
            atPath: home.appendingPathComponent("Library/Group Containers").path))
    }

    // MARK: - The configured path still works

    @Test func configuredIDResolvesAndCreatesTheContainer() throws {
        let home = try tempHome()
        let id = "group.com.example.wiki"

        let dir = try DatabaseLocation.appGroupContainerDirectory(
            id: id, isConfigured: true, home: home)

        #expect(dir.path == containerPath(in: home, id: id).path)
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }

    /// Creating an existing container is a no-op, not an error — every process
    /// start goes through this path.
    @Test func configuredIDIsIdempotent() throws {
        let home = try tempHome()
        let id = "group.com.example.wiki"

        let first = try DatabaseLocation.appGroupContainerDirectory(
            id: id, isConfigured: true, home: home)
        let second = try DatabaseLocation.appGroupContainerDirectory(
            id: id, isConfigured: true, home: home)

        #expect(first.path == second.path)
    }

    /// The compiled-in constant is not itself forbidden. If a developer really
    /// does state it — say they ARE the upstream author — it is honored. What is
    /// forbidden is reaching it by default, with nobody having chosen it.
    @Test func explicitlyConfiguredDefaultIDIsAllowed() throws {
        let home = try tempHome()

        let dir = try DatabaseLocation.appGroupContainerDirectory(
            id: "group.org.sockpuppet.wiki", isConfigured: true, home: home)

        #expect(FileManager.default.fileExists(atPath: dir.path))
    }

    // MARK: - Resolution source

    @Test(arguments: [
        WikiIdentifiers.ResolutionSource.environment,
        .infoPlist,
        .sidecar,
        .localConfig,
    ]) func statedSourcesCountAsExplicit(_ source: WikiIdentifiers.ResolutionSource) {
        #expect(source.isExplicit)
    }

    /// The one leg nobody chose. `build.sh` injecting the same string via the
    /// Info.plist IS a choice and stays explicit — the build echoes the group it
    /// used, so that path is visible.
    @Test func compiledDefaultIsNotExplicit() {
        #expect(!WikiIdentifiers.ResolutionSource.compiledDefault.isExplicit)
    }

    @Test func everySourceHasADistinctRawValueForDiagnostics() {
        let all: [WikiIdentifiers.ResolutionSource] =
            [.environment, .infoPlist, .sidecar, .localConfig, .compiledDefault]
        #expect(Set(all.map(\.rawValue)).count == all.count)
    }

    // MARK: - The message

    /// The error exists for the instructions it carries. The CLI and daemon
    /// report with `"\(error)"`, so `String(describing:)` must produce them too —
    /// not the raw enum case.
    @Test func errorTextIsActionableThroughBothSpellings() {
        let error = WikiIdentifiersError.unconfiguredAppGroupID(
            fallback: "group.org.sockpuppet.wiki")

        for text in [error.localizedDescription, "\(error)", error.description] {
            #expect(text.contains("WIKI_APP_GROUP_ID"))
            #expect(text.contains("signing/local.config"))
            #expect(text.contains("signing/setup.sh"))
            #expect(text.contains("group.org.sockpuppet.wiki"))
            #expect(!text.contains("unconfiguredAppGroupID("),
                    "must not leak the raw enum case")
        }
    }
}
