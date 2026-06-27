import Foundation
import Testing
@testable import WikiFSCore

/// Pure unit tests for `MarkdownFolderReader` — injected `FileOperations` means
/// none of these touch the real filesystem.
struct MarkdownFolderReaderTests {

    // MARK: - Test double

    /// In-memory filesystem. File paths map to their content (`nil` = read error).
    /// Directory paths are inferred: any path that is a prefix of another entry
    /// (with a `/` separator) is a directory. This mirrors how `FileManager`
    /// enumerates children — flat list, implicit directories.
    private final class FakeFileOperations: MarkdownFolderReader.FileOperations, @unchecked Sendable {
        /// File path → content. `nil` content means "exists but can't be read".
        private let files: [String: Data?]
        /// Cached set of directory paths (computed once from file path prefixes).
        private let directories: Set<String>

        init(root: String, files: [String: Data?]) {
            self.files = files
            // Infer directories from file path prefixes. E.g. file "/r/a/b.md"
            // implies directories "/r" and "/r/a".
            var dirs: Set<String> = [root]
            for (path, _) in files {
                var parent = (path as NSString).deletingLastPathComponent
                while !parent.isEmpty && parent != "/" {
                    dirs.insert(parent)
                    parent = (parent as NSString).deletingLastPathComponent
                }
            }
            self.directories = dirs
        }

        func listDirectory(at directory: URL) throws -> [URL] {
            let dirPath = directory.path
            let prefix = dirPath.hasSuffix("/") ? dirPath : dirPath + "/"
            var seen: Set<String> = []
            var children: [URL] = []

            // Direct subdirectories
            for d in directories where d != dirPath {
                let parent = (d as NSString).deletingLastPathComponent
                if parent == dirPath {
                    let name = (d as NSString).lastPathComponent
                    if !seen.contains(name) {
                        seen.insert(name)
                        children.append(URL(fileURLWithPath: d))
                    }
                }
            }
            // Files directly in this directory
            for (path, _) in files {
                guard path.hasPrefix(prefix) else { continue }
                let relative = String(path.dropFirst(prefix.count))
                guard !relative.contains("/") else { continue }  // skip nested files
                let name = relative
                if !seen.contains(name) {
                    seen.insert(name)
                    children.append(URL(fileURLWithPath: path))
                }
            }
            return children.sorted { $0.path < $1.path }
        }

        func isDirectory(at url: URL) -> Bool {
            directories.contains(url.path)
        }

        func readContents(at url: URL) throws -> Data {
            let path = url.path
            guard let result = files[path] else {
                throw NSError(domain: "FakeFileOperations", code: 260,
                              userInfo: [NSLocalizedDescriptionKey: "File not found: \(path)"])
            }
            guard let bytes = result else {
                throw NSError(domain: "FakeFileOperations", code: 257,
                              userInfo: [NSLocalizedDescriptionKey: "Permission denied: \(path)"])
            }
            return bytes
        }

        func isHiddenFile(at url: URL) -> Bool {
            url.lastPathComponent.hasPrefix(".")
        }
    }

    private func fakeRoot() -> String {
        "/fake/vault"
    }

    // MARK: - Recursive walk

    @Test func findsAllDotMDFilesRecursively() {
        let root = fakeRoot()
        let ops = FakeFileOperations(root: root, files: [
            "\(root)/a.md": Data("a".utf8),
            "\(root)/sub/b.md": Data("b".utf8),
            "\(root)/sub/deep/c.md": Data("c".utf8),
        ])
        let result = MarkdownFolderReader.walk(
            directory: URL(fileURLWithPath: root), fileOps: ops)
        #expect(result.files.count == 3)
        #expect(result.errors.isEmpty)
        let filenames = Set(result.files.map(\.filename))
        #expect(filenames == ["a.md", "b.md", "c.md"])
    }

    @Test func findsDotMarkdownFiles() {
        let root = fakeRoot()
        let ops = FakeFileOperations(root: root, files: [
            "\(root)/note.markdown": Data("md".utf8),
            "\(root)/readme.MARKDOWN": Data("md".utf8),
        ])
        let result = MarkdownFolderReader.walk(
            directory: URL(fileURLWithPath: root), fileOps: ops)
        #expect(result.files.count == 2)
    }

    @Test func ignoresUnsupportedFiles() {
        let root = fakeRoot()
        let ops = FakeFileOperations(root: root, files: [
            "\(root)/note.md": Data("md".utf8),
            "\(root)/image.png": Data("png".utf8),
            "\(root)/video.mp4": Data("mp4".utf8),
            "\(root)/script.txt": Data("txt".utf8),
            "\(root)/sub/note.md": Data("md2".utf8),
        ])
        let result = MarkdownFolderReader.walk(
            directory: URL(fileURLWithPath: root), fileOps: ops)
        #expect(result.files.count == 2)
    }

    @Test func ignoresHiddenFilesAndDirectories() {
        let root = fakeRoot()
        let ops = FakeFileOperations(root: root, files: [
            "\(root)/note.md": Data("visible".utf8),
            "\(root)/.hidden.md": Data("hidden".utf8),
            "\(root)/.obsidian/config.md": Data("hidden2".utf8),
            "\(root)/.obsidian/plugins/plugin.md": Data("hidden3".utf8),
        ])
        let result = MarkdownFolderReader.walk(
            directory: URL(fileURLWithPath: root), fileOps: ops)
        #expect(result.files.count == 1)
        #expect(result.files.first?.filename == "note.md")
        #expect(result.files.first?.data == Data("visible".utf8))
    }

    @Test func deduplicatesIdenticalFilenames() {
        let root = fakeRoot()
        let ops = FakeFileOperations(root: root, files: [
            "\(root)/a/Note.md": Data("first".utf8),
            "\(root)/b/Note.md": Data("second".utf8),
            "\(root)/c/Note.md": Data("third".utf8),
        ])
        let result = MarkdownFolderReader.walk(
            directory: URL(fileURLWithPath: root), fileOps: ops)
        #expect(result.files.count == 3)
        let filenames = Set(result.files.map(\.filename))
        #expect(filenames == ["Note.md", "Note-1.md", "Note-2.md"])
    }

    @Test func deduplicationPreservesOriginalForFirstOccurrence() {
        let root = fakeRoot()
        let ops = FakeFileOperations(root: root, files: [
            "\(root)/archive/Note.md": Data("copy".utf8),
            "\(root)/projects/Note.md": Data("original".utf8),
        ])
        let result = MarkdownFolderReader.walk(
            directory: URL(fileURLWithPath: root), fileOps: ops)
        #expect(result.files.count == 2)
        // archive/ sorts before projects/ — the first Note.md keeps its name.
        #expect(result.files.contains { $0.filename == "Note.md" && $0.data == Data("copy".utf8) })
        #expect(result.files.contains { $0.filename == "Note-1.md" && $0.data == Data("original".utf8) })
    }

    @Test func collectsReadErrorsWithoutAborting() {
        let root = fakeRoot()
        let ops = FakeFileOperations(root: root, files: [
            "\(root)/good.md": Data("ok".utf8),
            "\(root)/bad.md": nil,  // nil data = read error
            "\(root)/also-good.md": Data("also ok".utf8),
        ])
        let result = MarkdownFolderReader.walk(
            directory: URL(fileURLWithPath: root), fileOps: ops)
        #expect(result.files.count == 2)
        #expect(result.errors.count == 1)
        #expect(result.errors.first?.path.hasSuffix("bad.md") == true)
    }

    @Test func returnsEmptyResultForEmptyDirectory() {
        let root = fakeRoot()
        let ops = FakeFileOperations(root: root, files: [:])
        let result = MarkdownFolderReader.walk(
            directory: URL(fileURLWithPath: root), fileOps: ops)
        #expect(result.files.isEmpty)
        #expect(result.errors.isEmpty)
    }

    @Test func returnsEmptyResultForDirectoryWithUnsupportedFiles() {
        let root = fakeRoot()
        let ops = FakeFileOperations(root: root, files: [
            "\(root)/image.png": Data("png".utf8),
            "\(root)/video.mp4": Data("mp4".utf8),
        ])
        let result = MarkdownFolderReader.walk(
            directory: URL(fileURLWithPath: root), fileOps: ops)
        #expect(result.files.isEmpty)
        #expect(result.errors.isEmpty)
    }

    @Test func preservesFileContentByteIdentical() {
        let root = fakeRoot()
        let content = Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0xFD])
        let ops = FakeFileOperations(root: root, files: [
            "\(root)/binary.md": content,
        ])
        let result = MarkdownFolderReader.walk(
            directory: URL(fileURLWithPath: root), fileOps: ops)
        #expect(result.files.count == 1)
        #expect(result.files.first?.data == content)
    }

    @Test func walkErrorIsEquatable() {
        let a = MarkdownFolderReader.WalkError(path: "a.md", reason: "permission denied")
        let b = MarkdownFolderReader.WalkError(path: "a.md", reason: "permission denied")
        let c = MarkdownFolderReader.WalkError(path: "b.md", reason: "permission denied")
        #expect(a == b)
        #expect(a != c)
    }

    @Test func walkErrorErrorDescriptionIncludesPathAndReason() {
        let error = MarkdownFolderReader.WalkError(path: "sub/note.md", reason: "permission denied")
        #expect(error.errorDescription?.contains("sub/note.md") == true)
        #expect(error.errorDescription?.contains("permission denied") == true)
    }

    // MARK: - MarkdownFile Equatable

    @Test func markdownFileIsEquatable() {
        let a = MarkdownFolderReader.MarkdownFile(filename: "a.md", data: Data("x".utf8))
        let b = MarkdownFolderReader.MarkdownFile(filename: "a.md", data: Data("x".utf8))
        let c = MarkdownFolderReader.MarkdownFile(filename: "b.md", data: Data("x".utf8))
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - WalkResult Equatable

    @Test func walkResultIsEquatable() {
        let a = MarkdownFolderReader.WalkResult(
            files: [MarkdownFolderReader.MarkdownFile(filename: "n.md", data: Data("x".utf8))],
            errors: [])
        let b = MarkdownFolderReader.WalkResult(
            files: [MarkdownFolderReader.MarkdownFile(filename: "n.md", data: Data("x".utf8))],
            errors: [])
        #expect(a == b)
    }
}
