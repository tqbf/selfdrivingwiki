import Foundation

/// Recursively walks a directory and reads all Markdown files (`.md` / `.markdown`)
/// into memory, suitable for landing in `ingested_files`. Works with any folder of
/// Markdown files — Obsidian vault, LogSeq graph, or a plain directory.
///
/// Pure + injectable filesystem via the `FileOperations` protocol, so the entire
/// walk is unit-testable without touching the real disk. Mirrors
/// `ZoteroLocalStorage`'s injection shape (`fileExists` closure) and
/// `URLFetchService`'s injectable-fetcher pattern.
public enum MarkdownFolderReader {

    // MARK: - File operations protocol (injectable)

    /// Abstract filesystem access — `Sendable` so it can cross the actor boundary
    /// in a `Task.detached`. The production implementation wraps `FileManager`.
    public protocol FileOperations: Sendable {
        /// Returns the immediate children (files + directories) of `directory`.
        /// Throws on a real I/O failure (directory unreadable).
        func listDirectory(at directory: URL) throws -> [URL]

        /// True if `url` is a directory.
        func isDirectory(at url: URL) -> Bool

        /// Reads the entire contents of `url` as `Data`. Throws on failure.
        func readContents(at url: URL) throws -> Data

        /// True if the last path component starts with `.` (hidden file / directory).
        func isHiddenFile(at url: URL) -> Bool
    }

    // MARK: - Result types

    /// One markdown file ready for ingest.
    public struct MarkdownFile: Equatable, Sendable {
        /// The deduplicated filename (e.g. `Note.md`, `Note-1.md`).
        public let filename: String
        /// Verbatim file bytes.
        public let data: Data

        public init(filename: String, data: Data) {
            self.filename = filename
            self.data = data
        }
    }

    /// A per-file read failure — collected, never fatal.
    public struct WalkError: LocalizedError, Equatable, Sendable {
        /// The path (relative to the walk root) whose read failed.
        public let path: String
        public let reason: String

        public var errorDescription: String? {
            "Couldn't read \(path): \(reason)"
        }

        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }
    }

    /// The result of walking a directory.
    public struct WalkResult: Equatable, Sendable {
        public let files: [MarkdownFile]
        public let errors: [WalkError]

        public init(files: [MarkdownFile], errors: [WalkError]) {
            self.files = files
            self.errors = errors
        }
    }

    // MARK: - Walk

    /// Recursively walk `directory`, find every `.md` / `.markdown` file, read its
    /// bytes, and deduplicate filenames (two `Note.md` files in different
    /// subdirectories become `Note.md` and `Note-1.md`). Hidden files and
    /// directories (names starting with `.`) are skipped — this naturally excludes
    /// `.obsidian/`, `.trash/`, `.git/`, etc.
    ///
    /// Per-file read failures are collected in `WalkResult.errors`; the walk
    /// continues through any failure.
    ///
    /// - Parameters:
    ///   - directory: The root directory to walk.
    ///   - fileOps: Injectable filesystem access.
    /// - Returns: The set of readable markdown files + any per-file errors.
    public static func walk(
        directory: URL,
        fileOps: any FileOperations
    ) -> WalkResult {
        var found: [(relativePath: String, url: URL)] = []
        collectMarkdownFiles(in: directory, root: directory, fileOps: fileOps, found: &found)

        // Deduplicate filenames. Two files in different subdirs that happen to
        // share the same last component get a disambiguating suffix:
        //   sub1/Note.md  →  Note.md
        //   sub2/Note.md  →  Note-1.md
        var files: [MarkdownFile] = []
        var errors: [WalkError] = []
        var seen: [String: Int] = [:]

        for (relPath, url) in found {
            let base = url.lastPathComponent
            let stem: String
            let ext: String
            if let dot = base.lastIndex(of: "."), dot != base.startIndex {
                stem = String(base[..<dot])
                ext = String(base[dot...])
            } else {
                stem = base
                ext = ""
            }

            let count = seen[base, default: 0]
            seen[base, default: 0] += 1

            let filename: String
            if count == 0 {
                filename = base
            } else {
                filename = "\(stem)-\(count)\(ext)"
            }

            do {
                let data = try fileOps.readContents(at: url)
                files.append(MarkdownFile(filename: filename, data: data))
            } catch {
                errors.append(WalkError(
                    path: relPath,
                    reason: error.localizedDescription
                ))
            }
        }

        return WalkResult(files: files, errors: errors)
    }

    // MARK: - Private helpers

    /// Supported source extensions (case-insensitive comparison).
    private static let sourceExtensions: Set<String> = ["md", "markdown", "pdf"]

    /// Recursively collect source file URLs relative to `root`.
    private static func collectMarkdownFiles(
        in directory: URL,
        root: URL,
        fileOps: any FileOperations,
        found: inout [(relativePath: String, url: URL)]
    ) {
        guard let children = try? fileOps.listDirectory(at: directory) else { return }

        for child in children {
            if fileOps.isHiddenFile(at: child) { continue }

            if fileOps.isDirectory(at: child) {
                collectMarkdownFiles(in: child, root: root, fileOps: fileOps, found: &found)
            } else {
                let ext = child.pathExtension.lowercased()
                guard sourceExtensions.contains(ext) else { continue }
                let relPath = String(child.path.dropFirst(root.path.count + 1))
                found.append((relativePath: relPath, url: child))
            }
        }
    }
}

// MARK: - Production file operations

extension MarkdownFolderReader {
    /// Production `FileOperations` backed by `FileManager.default`.
    public struct FileManagerFileOperations: FileOperations, Sendable {
        public init() {}

        public func listDirectory(at directory: URL) throws -> [URL] {
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsSubdirectoryDescendants]
            )
        }

        public func isDirectory(at url: URL) -> Bool {
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        }

        public func readContents(at url: URL) throws -> Data {
            try Data(contentsOf: url)
        }

        public func isHiddenFile(at url: URL) -> Bool {
            url.lastPathComponent.hasPrefix(".")
        }
    }
}
