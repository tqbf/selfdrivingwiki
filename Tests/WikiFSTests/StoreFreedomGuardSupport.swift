import Foundation
import Testing

/// Shared machinery for the daemon-only source-level freedom guards
/// (plans/daemon-only-access.md Phase 0). Guards parse guarded sources and
/// assert every occurrence of a forbidden token is covered by an explicit
/// waiver whose count matches exactly — a new violation, a stale waiver, or
/// a count drift all fail. Waivers shrink phase by phase per the plan's
/// permitted-access table; the P7 end state is every list empty.
enum StoreFreedomGuardSupport {
    struct Waiver: Sendable {
        /// Repo-root-relative file path, `/` separators.
        let file: String
        /// The exact forbidden-token text this waiver covers.
        let token: String
        /// The exact expected occurrence count. Must match the source; a
        /// mismatch in either direction fails (shrinking enforcement).
        let count: Int
        /// The plan phase that removes this occurrence (for audit).
        let clearedIn: String

        init(file: String, token: String, count: Int, clearedIn: String) {
            self.file = file
            self.token = token
            self.count = count
            self.clearedIn = clearedIn
        }
    }

    /// Forbidden tokens ordered most-specific first so nested matches
    /// (`GRDBWikiStore(readOnlyURL:` inside `GRDBWikiStore(`) count once,
    /// against the specific token.
    static let forbiddenTokens: [String] = [
        "GRDBWikiStore(readOnlyURL:",
        "GRDBWikiStore(",
        "WikiReadService(",
        "QueueStore(",
        "TantivyIndexer(",
        "StoreBackend.current.makeStore",
    ]

    /// Counts non-overlapping occurrences of `token` in `source`, skipping
    /// ranges already consumed by MORE-specific tokens (the list is ordered
    /// most-specific first, so only tokens before `token` in the list are
    /// subtracted).
    static func occurrences(of token: String, in source: String) -> Int {
        var consumed = [Range<String.Index>]()
        for earlier in forbiddenTokens.prefix(while: { $0 != token }) {
            var searchStart = source.startIndex
            while let range = source.range(of: earlier, range: searchStart..<source.endIndex) {
                consumed.append(range)
                searchStart = range.upperBound
            }
        }
        var count = 0
        var searchStart = source.startIndex
        while let range = source.range(of: token, range: searchStart..<source.endIndex) {
            defer { searchStart = range.upperBound }
            if consumed.contains(where: { $0.overlaps(range) }) { continue }
            count += 1
        }
        return count
    }

    /// Recursively lists Swift sources under a repo-root-relative directory.
    static func swiftFiles(inRoot root: URL, relative directory: String) throws -> [String] {
        let directoryURL = root.appendingPathComponent(directory, isDirectory: true)
        var results: [String] = []
        let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey])
        while let next = enumerator?.nextObject() as? URL {
            let isRegular = (try? next.resourceValues(forKeys: [.isRegularFileKey]))?
                .isRegularFile ?? false
            guard isRegular, next.pathExtension == "swift" else { continue }
            let relative = next.path
                .replacingOccurrences(of: root.path + "/", with: "")
            results.append(relative)
        }
        return results.sorted()
    }

    /// Asserts the guarded files' forbidden-token occurrences exactly match
    /// the waiver list (every occurrence waived at its exact count, every
    /// waiver live).
    static func assertForbiddenTokens(
        guardedDirectories: [String],
        guardedFiles: [String] = [],
        waivers: [Waiver],
        file: Swift.String = #filePath
    ) throws {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var sources: [String: String] = [:]
        for directory in guardedDirectories {
            for relative in try swiftFiles(inRoot: root, relative: directory) {
                let url = root.appendingPathComponent(relative)
                sources[relative] = try String(contentsOf: url, encoding: .utf8)
            }
        }
        for relative in guardedFiles {
            let url = root.appendingPathComponent(relative)
            sources[relative] = try String(contentsOf: url, encoding: .utf8)
        }
        guard !sources.isEmpty else {
            Issue.record("no guarded sources found under \(guardedDirectories + guardedFiles)")
            return
        }

        var waiverIndex: [String: [Waiver]] = [:]
        for waiver in waivers {
            waiverIndex[waiver.file, default: []].append(waiver)
        }

        var failures: [String] = []
        for (relative, source) in sources {
            let fileWaivers = waiverIndex[relative] ?? []
            for token in forbiddenTokens {
                let actual = occurrences(of: token, in: source)
                let waiver = fileWaivers.first { $0.token == token }
                switch (actual, waiver) {
                case (0, nil):
                    continue
                case (0, .some(let stale)):
                    failures.append(
                        "stale waiver: \(relative) no longer contains “\(stale.token)” (waiver expected \(stale.count) for \(stale.clearedIn))")
                case (_, nil):
                    failures.append(
                        "unwaived occurrence: \(relative) contains forbidden token “\(token)” ×\(actual) — it needs an explicit waiver (or removal)")
                case (let actual, .some(let waiver)) where actual != waiver.count:
                    failures.append(
                        "waiver drift: \(relative) “\(waiver.token)” actual ×\(actual) but waiver pins ×\(waiver.count) (cleared in \(waiver.clearedIn))")
                default:
                    continue
                }
            }
            // A waiver naming a file absent from the guarded set is stale too.
        }
        for (relative, fileWaivers) in waiverIndex where sources[relative] == nil {
            for waiver in fileWaivers {
                failures.append(
                    "stale waiver: \(relative) is not in the guarded set (waiver for “\(waiver.token)”, cleared in \(waiver.clearedIn))")
            }
        }

        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }
}
