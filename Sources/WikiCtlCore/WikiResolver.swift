import Foundation
import WikiFSCore

/// The typed form of one wiki selection on the CLI: either the ordinary
/// registry selector (`--wiki <id-or-name>` / `WIKI_DB`), or an EXPLICIT
/// database file (`--database-path <file>` / `WIKI_DB_PATH`).
///
/// The two forms are mutually exclusive. The explicit form exists so a caller
/// can target a disposable fixture database outside the App Group container
/// (the live semantic evaluation harness) WITHOUT overloading the `--wiki`
/// string — a file path can never masquerade as a wiki id, and a wiki id can
/// never silently resolve to a file. Raw path text converts to a typed `URL`
/// exactly here, at the external boundary, and is validated once:
/// absolute, `.sqlite`, and NOT inside the real App Group container (the
/// last guard keeps an accidental live-wiki target a hard error instead of a
/// silent write to operator data).
public enum WikiDatabaseSelection: Equatable, Sendable {
    /// Registry lookup by wiki id (ULID) or display name — unchanged
    /// semantics for every ordinary invocation.
    case registry(String)
    /// One explicit wiki database file.
    case explicitDatabase(URL)
}

/// Why a raw selector string could not become a typed ``WikiDatabaseSelection``.
public enum WikiSelectionError: Error, Equatable, Sendable {
    /// `--database-path`/`WIKI_DB_PATH` carried a relative path.
    case relativeDatabasePath(String)
    /// The explicit database file does not end in `.sqlite`.
    case notADatabaseFile(String)
    /// The explicit database file lies inside the real App Group container —
    /// refused so a typo can never redirect an isolated run onto live wiki
    /// data. Registry selection (`--wiki`) is the only way to reach a
    /// container database.
    case explicitPathInsideAppGroupContainer(String)
    /// Both selector forms were supplied (flag + env in some combination).
    case conflictingSelectors(String)

    public var localizedDescription: String {
        switch self {
        case .relativeDatabasePath(let path):
            "database path must be absolute: \(path)"
        case .notADatabaseFile(let path):
            "database path must name a .sqlite file: \(path)"
        case .explicitPathInsideAppGroupContainer(let path):
            "refusing --database-path inside the App Group container (use --wiki to select a live wiki): \(path)"
        case .conflictingSelectors(let detail):
            "conflicting wiki selectors — pass exactly one of --wiki or --database-path (\(detail))"
        }
    }
}

/// One fully resolved wiki target: the database file, its typed id, and the
/// directory sidecars (search index, registry) are rooted at.
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

/// Resolves the `--wiki <id>` / `--wiki=<id>` / `WIKI_DB` selector to a concrete wiki's
/// `<ulid>.sqlite` path, through the SAME registry the app uses
/// (`plans/llm-wiki.md` — "Takes `--wiki <id>` … resolved through the same
/// registry the app uses").
///
/// Accepts either the wiki's ULID directly, or — for convenience — a display
/// name, which it resolves to the id via the registry. The ULID is tried first
/// so an exactly-matching id is never shadowed by a same-named wiki.
public struct WikiResolver {
    public let containerDirectory: URL

    public init(containerDirectory: URL) {
        self.containerDirectory = containerDirectory
    }

    /// The App Group container the un-sandboxed app writes to, built from the
    /// literal home-relative path (`DatabaseLocation.appGroupContainerDirectory`)
    /// so `wikictl` opens the exact same files without an entitlement.
    public static func appGroupContainer() throws -> WikiResolver {
        WikiResolver(containerDirectory: try DatabaseLocation.appGroupContainerDirectory())
    }

    /// Resolve a `--wiki` selector to its descriptor. Returns nil if no wiki in
    /// the registry matches the selector by id or by display name.
    public func descriptor(forSelector selector: String) -> WikiDescriptor? {
        let registry = WikiRegistry.load(from: containerDirectory)
        if let byID = registry.descriptor(id: WikiID(rawValue: selector)) {
            return byID
        }
        return registry.wikis.first { $0.displayName == selector }
    }

    /// The on-disk `<ulid>.sqlite` URL for a resolved descriptor.
    public func databaseURL(for descriptor: WikiDescriptor) -> URL {
        containerDirectory.appendingPathComponent(descriptor.dbFileName, isDirectory: false)
    }

    // MARK: - Typed selection (explicit database support)

    /// The real App Group container path WITHOUT creating it. Pure string
    /// assembly over `WikiIdentifiers.appGroupID` + the given home directory —
    /// unlike `DatabaseLocation.appGroupContainerDirectory()`, resolving a
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

    /// Convert one raw selector pair (flag-level, env-level) into a typed
    /// ``WikiDatabaseSelection``, rejecting every mixed combination. Exactly
    /// one of the two optional values must be non-nil/non-empty.
    public static func selection(
        wikiSelector: String?,
        databasePath: String?
    ) throws -> WikiDatabaseSelection {
        let wiki = wikiSelector.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let path = databasePath.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        switch (wiki.isEmpty, path.isEmpty) {
        case (false, false):
            throw WikiSelectionError.conflictingSelectors(
                "got both --wiki \(wiki) and --database-path \(path)")
        case (true, true):
            throw WikiSelectionError.conflictingSelectors(
                "no wiki selected — pass --wiki <id> or --database-path <file>")
        case (false, true):
            return .registry(wiki)
        case (true, false):
            return try selection(forDatabasePath: path)
        }
    }

    /// Validate one explicit database path and return the typed selection.
    /// Absolute, `.sqlite`, outside the App Group container. Relative-path
    /// detection runs on the RAW string — `URL(fileURLWithPath:)` silently
    /// resolves a relative string against the current working directory, so
    /// checking the converted URL's path would never fire. The containment
    /// check reads the filesystem only through `resolvingSymlinksInPath()`
    /// (resolving existing symlink components); it creates nothing.
    public static func selection(forDatabasePath rawPath: String) throws -> WikiDatabaseSelection {
        // The raw string must itself be absolute: URL conversion would
        // otherwise absolutize a relative path and hide the mistake.
        guard rawPath.hasPrefix("/") else {
            throw WikiSelectionError.relativeDatabasePath(rawPath)
        }
        let url = URL(fileURLWithPath: rawPath)
        guard url.pathExtension.lowercased() == "sqlite" else {
            throw WikiSelectionError.notADatabaseFile(rawPath)
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
            throw WikiSelectionError.explicitPathInsideAppGroupContainer(rawPath)
        }
        return .explicitDatabase(url)
    }

    /// Resolve a typed selection to its target. The registry form performs the
    /// ordinary registry lookup (read-only, unchanged). The explicit form
    /// bypasses the registry entirely: the database is the named file, the
    /// wiki id is the file's stem, and the container directory is the file's
    /// parent — so every sidecar the CLI profile roots at a "container"
    /// (search index, scratch state) stays beside the disposable database and
    /// nothing in the real App Group container is read or written.
    public func resolve(selection: WikiDatabaseSelection) throws -> ResolvedWikiTarget {
        switch selection {
        case .registry(let selector):
            guard let descriptor = descriptor(forSelector: selector) else {
                throw PageCommand.Failure.message(
                    "no wiki matching \(selector.debugDescription) in the registry")
            }
            return ResolvedWikiTarget(
                databaseURL: databaseURL(for: descriptor),
                wikiID: descriptor.id,
                containerDirectory: containerDirectory)
        case .explicitDatabase(let url):
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            let stem = canonical.deletingPathExtension().lastPathComponent
            return ResolvedWikiTarget(
                databaseURL: canonical,
                wikiID: WikiID(rawValue: stem),
                containerDirectory: canonical.deletingLastPathComponent())
        }
    }
}
