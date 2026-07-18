import Foundation
import Testing

/// House-rule guard: behavioral extension checks (content-type decisions driven by
/// filename extension rather than `mime_type`) are a bug per
/// `plans/content-type-over-extension.md`. This test fails if a new extension-based
/// behavioral branch appears outside the allowlisted set.
///
/// The allowlist covers:
/// - `FilenameEscaping` — filename construction for the mounted filesystem
/// - `WikiFilePanels` — `.sqlite` export filter (UI file dialog)
/// - `WikiFSItem` — generated-doc suffixes (`.md`, `.json`, `.jsonl` on names we control)
/// - `EmbeddingService` — `Bundle.main.bundlePath.hasSuffix(".app")` (runtime path)
/// - `any WikiStore` — same bundle-path guard + ext fallback in `addSource` (last resort)
/// - `ZoteroClient` — `isIngestable` fallback heuristic (MIME-first already)
/// - `WikiStoreModel` — markdown lazy-seed ext check (owned by Phase C)
struct ExtensionCheckGuardTests {

    /// Patterns that signal a behavioral extension check.
    private static let patterns: [(String, String)] = [
        // .ext == / .ext != on a source/file model — checking extension to decide behavior
        ("\\.ext == \"", "direct ext string comparison"),
        // hasSuffix(".<ext>") — checking filename suffix for behavior (not construction)
        ("hasSuffix\\(\"\\.", "filename suffix check"),
    ]

    /// Files (stem only, no .swift) that are allowed to check extensions.
    private static let allowlistedFiles: Set<String> = [
        "FilenameEscaping",       // filename construction for mount
        "WikiFilePanels",         // .sqlite export filter
        "WikiFSItem",             // generated-doc suffixes on names we control
        "EmbeddingService",       // Bundle.main.bundlePath.hasSuffix(".app")
        "any WikiStore",        // bundle-path guard + ext fallback in addSource
        "ZoteroClient",           // isIngestable fallback (MIME-first already)
        "WikiStoreModel",         // markdown lazy-seed (Phase C owns removal)
    ]

    @Test func noNewExtensionChecks() throws {
        // Resolve the Sources/ directory relative to the repo root.
        // The test runs from the project root when invoked via `swift test`.
        let srcDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)

        let fm = FileManager.default
        var swiftFiles: [URL] = []
        guard let enumerator = fm.enumerator(at: srcDir, includingPropertiesForKeys: nil) else {
            Issue.record("Could not enumerate Sources/ directory at \(srcDir.path)")
            return
        }
        while let file = enumerator.nextObject() as? URL {
            if file.pathExtension == "swift" { swiftFiles.append(file) }
        }

        var offenders: [String] = []
        for file in swiftFiles {
            let stem = file.deletingLastPathComponent().lastPathComponent
            guard !Self.allowlistedFiles.contains(stem) else { continue }

            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                for (pattern, desc) in Self.patterns {
                    if line.contains(pattern) {
                        // Skip lines inside comments (block comments)
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                            continue
                        }
                        offenders.append("\(file.lastPathComponent):\(i + 1) — \(desc): \(trimmed)")
                    }
                }
            }
        }

        if !offenders.isEmpty {
            let sorted = offenders.sorted()
            let msg = "New extension-based behavioral checks found outside allowlist:\n"
                + sorted.joined(separator: "\n")
                + "\n\nSee plans/content-type-over-extension.md."
            Issue.record("\(msg)")
        }
    }
}
