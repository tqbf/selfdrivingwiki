import Testing
import Foundation

/// Contract test for the outline pipeline's observability (AC.9): exactly two
/// central outline-content log seams are allowed in `Sources/WikiFS` — the
/// controller's payload-acceptance line and the renderer's redraw line — and
/// none of the transitional per-surface outline logs may return.
struct InspectorOutlineLoggingContractTests {
    /// The exact set of `DebugLog.tabs` outline-message prefixes allowed in
    /// production sources. Two seams: payload acceptance (controller) and
    /// inspector redraw (renderer).
    private static let allowedSeams: Set<String> = [
        "Inspector outline payload accepted",
        "Inspector outline redraw",
    ]

    /// Transitional log strings from the investigation phase. If any of these
    /// reappear, the per-surface outline lifecycle is creeping back.
    private static let legacyStrings: [String] = [
        "outline registration published",
        "registration deferred",
        "PageOutline redraw",
        "PageOutline parsed",
        "Source outline redraw",
        "Chat outline redraw",
        "Inspector outline branch",
        "subject replaced",
    ]

    /// Repo root, derived from this file's location so the scan works no
    /// matter what the test process's working directory is.
    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/WikiFSAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Sources/WikiFS")
    }

    private static func swiftFiles(under root: URL) throws -> [URL] {
        var files: [URL] = []
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey])
        while let next = enumerator?.nextObject() as? URL {
            // Skip build artifacts if a stray .build symlink ever appears.
            if next.path.contains("/.build/") || next.path.contains("/DerivedData/") {
                continue
            }
            if next.pathExtension == "swift" {
                files.append(next)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    @Test func onlyTheTwoCentralOutlineSeamsRemain() throws {
        var outlineSeamPrefixes: Set<String> = []
        var seamSiteCounts: [String: Int] = [:]

        for file in try Self.swiftFiles(under: Self.sourcesRoot) {
            let text = try String(contentsOf: file, encoding: .utf8)
            // Matches `DebugLog.tabs(` call sites whose message begins with
            // "Inspector outline" up to the message's first colon — the
            // convention both allowed seams follow.
            let pattern = #"DebugLog\.tabs\(\s*"Inspector outline ([a-z ]+):"#
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard let seamRange = Range(match.range(at: 1), in: text) else { continue }
                let seam = "Inspector outline " + text[seamRange]
                outlineSeamPrefixes.insert(seam)
                seamSiteCounts[seam, default: 0] += 1
            }
        }

        #expect(
            outlineSeamPrefixes == Self.allowedSeams,
            "outline log seams must be exactly the two central ones; found \(outlineSeamPrefixes.sorted())")
        #expect(
            seamSiteCounts["Inspector outline payload accepted"] == 1,
            "payload acceptance must log at exactly one site")
        #expect(
            seamSiteCounts["Inspector outline redraw"] == 1,
            "outline redraw must log at exactly one site")
    }

    @Test func legacyTransitionalOutlineLogsAreGone() throws {
        for file in try Self.swiftFiles(under: Self.sourcesRoot) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for legacy in Self.legacyStrings {
                #expect(
                    !text.contains(legacy),
                    "legacy outline log string \"\(legacy)\" must not reappear (found in \(file.lastPathComponent))")
            }
        }
    }
}
