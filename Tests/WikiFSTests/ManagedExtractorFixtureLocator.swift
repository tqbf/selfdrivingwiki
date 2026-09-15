import Foundation

/// Deterministic discovery of SwiftPM-built test fixture executables.
///
/// The build tree can hold more than one path for a fixture (the product
/// plus its `.dSYM` payload, multiple triples or configurations, and stale
/// artifacts after configuration switches). Taking the first enumerator hit
/// made the selection depend on directory enumeration order, which can pin a
/// stale or non-product file whose behavior no longer matches the source
/// (#1286). The locator instead considers only build products (paths whose
/// parent is a SwiftPM configuration directory such as `debug` or
/// `release`), prefers the most recently modified match, and breaks ties by
/// path so the choice is stable regardless of enumeration order.
enum ManagedExtractorFixtureLocator {
    enum LocatorError: Error, CustomStringConvertible {
        case missing(String)

        var description: String {
            switch self {
            case .missing(let name): return "\(name) is missing from the build tree"
            }
        }
    }

    /// SwiftPM configuration directories that hold linkable products. Both
    /// layouts appear here: the classic `.../<triple>/debug/` products and
    /// the SwiftPM native build system's capitalized `Products/Debug/`.
    private static let productDirectoryNames: Set<String> = [
        "debug", "release", "Debug", "Release",
    ]

    /// Returns the newest built product named `name` under the repository's
    /// `.build` directory.
    ///
    /// `repositoryRootFilePath` is the `#filePath` of the calling test file;
    /// every current call site sits three directories below the repository
    /// root (`Tests/WikiFSTests/<file>.swift`).
    static func locate(
        name: String,
        repositoryRootFilePath: String
    ) throws -> URL {
        let repositoryRoot = URL(fileURLWithPath: repositoryRootFilePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildRoot = repositoryRoot.appendingPathComponent(".build", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: buildRoot,
            includingPropertiesForKeys: [.isExecutableKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw LocatorError.missing(name)
        }

        var best: (url: URL, modified: Date, path: String)?
        while let candidate = enumerator.nextObject() as? URL {
            guard candidate.lastPathComponent == name,
                  FileManager.default.isExecutableFile(atPath: candidate.path),
                  isBuildProduct(candidate) else { continue }
            let modified: Date
            do {
                modified = try candidate.resourceValues(
                    forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            } catch {
                // An unstattable candidate cannot be the newest product.
                modified = .distantPast
            }
            if let current = best {
                if modified > current.modified
                    || (modified == current.modified && candidate.path < current.path) {
                    best = (candidate, modified, candidate.path)
                }
            } else {
                best = (candidate, modified, candidate.path)
            }
        }
        guard let best else { throw LocatorError.missing(name) }
        return best.url
    }

    /// Build products live directly inside a configuration directory (for
    /// example `.build/arm64-apple-macosx/debug/`). Same-named payloads such
    /// as a `.dSYM`'s DWARF file live deeper and are excluded.
    private static func isBuildProduct(_ candidate: URL) -> Bool {
        guard let parent = candidate.pathComponents.dropLast().last else { return false }
        return productDirectoryNames.contains(parent)
    }
}
