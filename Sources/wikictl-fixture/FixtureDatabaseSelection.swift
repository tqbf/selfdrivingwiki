import Foundation
import WikiCtlCore
import WikiFSCore

// The typed explicit-database selection for `wikictl-fixture` — moved here
// from WikiCtlCore when the fixture-binary split landed (plans/cli-domain-
// commands.md §"The fixture binary"). The shipping `wikictl` has NO local
// database pathway at all: disposable fixture databases are this developer/CI
// binary's exclusive contract, so the selection machinery lives in the fixture
// target and WikiCtlCore keeps only the App Group container resolution.
//
// One explicit wiki database file (`--database-path <file>` / `WIKI_DB_PATH`),
// validated once at this boundary: absolute, `.sqlite`, and NOT inside the
// real App Group container (the last guard keeps an accidental live-wiki
// target a hard error instead of a silent write to operator data). There is no
// registry case: `wikictl-fixture` refuses `--wiki`/`WIKI_DB` outright — live
// wikis are `wikictl`'s daemon-routed surface.

/// Why a raw `--database-path`/`WIKI_DB_PATH` value could not become a typed
/// fixture database URL.
public enum FixtureSelectionError: Error, Equatable, Sendable {
    /// The path carried a relative string.
    case relativeDatabasePath(String)
    /// The explicit database file does not end in `.sqlite`.
    case notADatabaseFile(String)
    /// The explicit database file lies inside the real App Group container —
    /// refused so a typo can never redirect an isolated run onto live wiki
    /// data.
    case explicitPathInsideAppGroupContainer(String)

    public var localizedDescription: String {
        switch self {
        case .relativeDatabasePath(let path):
            "database path must be absolute: \(path)"
        case .notADatabaseFile(let path):
            "database path must name a .sqlite file: \(path)"
        case .explicitPathInsideAppGroupContainer(let path):
            "refusing --database-path inside the App Group container (use wikictl --wiki to select a live wiki): \(path)"
        }
    }
}

/// One fully resolved fixture target: the database file, its typed id, and the
/// directory sidecars (search index, reviewed packages) are rooted at.
public struct ResolvedWikiTarget: Equatable, Sendable {
    public let databaseURL: URL
    public let wikiID: WikiID
    public let containerDirectory: URL

    public init(databaseURL: URL, wikiID: WikiID, containerDirectory: URL) {
        self.databaseURL = databaseURL
        self.wikiID = wikiID
        self.containerDirectory = containerDirectory
    }
}

/// Validates and resolves one explicit `--database-path` selection for the
/// fixture binary. This process never reads `wikis.json` and never resolves a
/// registry selector — `wikictl-fixture page list --wiki X` is a usage error.
public struct FixtureWikiResolver: Sendable {
    public init() {}

    // MARK: - Typed selection validation

    /// The real App Group container path WITHOUT creating it. Pure string
    /// assembly over `WikiIdentifiers.appGroupID` + the given home directory —
    /// unlike `DatabaseLocation.appGroupContainerDirectory()`, validating a
    /// selector never manufactures container state.
    public static func appGroupContainerPath(
        id: String = DatabaseLocation.appGroupID,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        home.appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Group Containers", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
            .path
    }

    /// Validate one explicit database path and return the typed URL.
    /// Absolute, `.sqlite`, outside the App Group container. Relative-path
    /// detection runs on the RAW string — `URL(fileURLWithPath:)` silently
    /// resolves a relative string against the current working directory, so
    /// checking the converted URL's path would never fire. The containment
    /// check reads the filesystem only through `resolvingSymlinksInPath()`
    /// (resolving existing symlink components); it creates nothing.
    public static func validatedDatabasePath(_ rawPath: String) throws -> URL {
        // The raw string must itself be absolute: URL conversion would
        // otherwise absolutize a relative path and hide the mistake.
        guard rawPath.hasPrefix("/") else {
            throw FixtureSelectionError.relativeDatabasePath(rawPath)
        }
        let url = URL(fileURLWithPath: rawPath)
        guard url.pathExtension.lowercased() == "sqlite" else {
            throw FixtureSelectionError.notADatabaseFile(rawPath)
        }
        // Canonicalize both sides before comparing. This resolves real symlink
        // aliases (for example `/tmp` versus `/private/tmp`) without touching
        // the filesystem or creating the App Group container. Keep the
        // container path and its descendants reserved, plus the file-like
        // `<container>.sqlite` collision, so neither can be mistaken for an
        // isolated fixture.
        let canonicalDatabase = url.standardizedFileURL.resolvingSymlinksInPath().path
        let canonicalContainer = URL(fileURLWithPath: appGroupContainerPath())
            .standardizedFileURL.resolvingSymlinksInPath().path
        if canonicalDatabase == canonicalContainer
            || canonicalDatabase.hasPrefix(canonicalContainer + "/")
            || canonicalDatabase == canonicalContainer + ".sqlite" {
            throw FixtureSelectionError.explicitPathInsideAppGroupContainer(rawPath)
        }
        return url
    }

    /// Resolve a validated fixture database URL to its target. The file stem
    /// becomes the wiki id — the same identity the in-process store profile
    /// boots with and every command sees.
    public func resolve(databaseURL: URL) throws -> ResolvedWikiTarget {
        let canonical = databaseURL.standardizedFileURL.resolvingSymlinksInPath()
        let stem = canonical.deletingPathExtension().lastPathComponent
        return ResolvedWikiTarget(
            databaseURL: canonical,
            wikiID: WikiID(rawValue: stem),
            containerDirectory: canonical.deletingLastPathComponent())
    }
}

/// One parsed fixture invocation: the raw explicit-database selector plus the
/// remaining command arguments (parsed further by `ArgumentParser.parseCommand`
/// in WikiCtlCore — the fixture binary adds only its selector, never its own
/// command grammar).
public struct FixtureInvocation: Equatable, Sendable {
    public let databasePath: String
    public let arguments: [String]

    public init(databasePath: String, arguments: [String]) {
        self.databasePath = databasePath
        self.arguments = arguments
    }
}

/// The fixture binary's selector grammar: `--database-path <file>` /
/// `--database-path=<file>` / `WIKI_DB_PATH`, leading the arguments. `--wiki`
/// and `WIKI_DB` are refused outright — live wikis are `wikictl`'s
/// daemon-routed surface, and a fixture run must never touch the registry.
/// Pure (no I/O); the value is validated by
/// ``FixtureWikiResolver/validatedDatabasePath(_:)`` at the run boundary.
public enum FixtureArgumentParser {

    /// The usage-failure type is WikiCtlCore's `ArgumentParser.Failure.usage`
    /// so both binaries print usage errors the same way.
    public static func parse(
        _ arguments: [String],
        env: (String) -> String?
    ) throws -> FixtureInvocation {
        var databasePath: String?
        if arguments.first == "--database-path" {
            guard arguments.count >= 2 else {
                throw ArgumentParser.Failure.usage("--database-path requires a value")
            }
            databasePath = arguments[1]
        } else if let first = arguments.first, first.hasPrefix("--database-path=") {
            let value = String(first.dropFirst("--database-path=".count))
            guard !value.isEmpty else {
                throw ArgumentParser.Failure.usage("--database-path requires a value")
            }
            databasePath = value
        } else if let envValue = env("WIKI_DB_PATH"), !envValue.isEmpty {
            databasePath = envValue
        }
        guard let rawDatabasePath = databasePath, !rawDatabasePath.isEmpty else {
            throw ArgumentParser.Failure.usage(
                "no fixture database selected — pass --database-path <file> (or --database-path=<file>, or set WIKI_DB_PATH)")
        }
        if arguments.first == "--wiki" || arguments.first?.hasPrefix("--wiki=") == true {
            throw ArgumentParser.Failure.usage(
                "wikictl-fixture rejects --wiki — live wikis ride the daemon through wikictl; "
                    + "pass --database-path <file> for a fixture run")
        }
        if let wikiDB = env("WIKI_DB"), !wikiDB.isEmpty {
            throw ArgumentParser.Failure.usage(
                "wikictl-fixture rejects WIKI_DB — live wikis ride the daemon through wikictl; "
                    + "pass --database-path <file> (or WIKI_DB_PATH) for a fixture run")
        }
        let rest: [String]
        if arguments.first == "--database-path" {
            rest = Array(arguments.dropFirst(2))
        } else if arguments.first?.hasPrefix("--database-path=") == true {
            rest = Array(arguments.dropFirst())
        } else {
            // Selector came from WIKI_DB_PATH: every argument is command text.
            rest = arguments
        }
        return FixtureInvocation(databasePath: rawDatabasePath, arguments: rest)
    }
}
