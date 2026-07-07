import Testing
import Foundation

/// Code-scoped regression guard (AC.6). Once `onPageDidChange` is fully removed,
/// this test fails if the symbol reappears in any non-comment line under
/// `Sources/`. Doc-comments (`//`, `///`) are excluded so historical references
/// in prose don't false-positive; only real code (declarations, assignments,
/// calls) trips the guard.
struct NoOnPageDidChangeTests {

    /// Recursively collect every `.swift` file under `Sources/`.
    private func sourceFiles() throws -> [URL] {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let fm = FileManager.default
        guard fm.fileExists(atPath: sources.path) else { return [] }
        var files: [URL] = []
        if let enumerator = fm.enumerator(at: sources, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                files.append(url)
            }
        }
        return files
    }

    @Test func onPageDidChangeIsFullyRemovedFromSources() throws {
        let files = try sourceFiles()
        #expect(!files.isEmpty, "could not locate Sources/ from \(#filePath)")

        // Match the symbol anywhere on a line, but skip comment lines (`//` or
        // `///` after optional whitespace). This catches declarations
        // (`var onPageDidChange`), assignments (`onPageDidChange =`), optionals
        // (`onPageDidChange?`), and member access (`.onPageDidChange`).
        var offenders: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                if line.contains("onPageDidChange") {
                    offenders.append("\(file.lastPathComponent):\(i + 1): \(trimmed)")
                }
            }
        }
        #expect(offenders.isEmpty, """
        `onPageDidChange` reappeared in non-comment code under Sources/:
        \(offenders.joined(separator: "\n"))
        """)
    }
}
