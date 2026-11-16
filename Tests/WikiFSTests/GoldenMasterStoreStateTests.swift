import Foundation
import Testing
import WikiFSCore

/// Golden-master comparison against the committed baseline artifact
/// (plans/daemon-only-access.md Phase 0 → Phase 7). The fixture sequence and
/// exporter live in `GoldenMasterStoreState.swift`; this test runs them on a
/// fresh pair of databases and diffs the dump against
/// `Fixtures/GoldenMasterStoreState/baseline.txt`.
///
/// Regenerating the artifact after an INTENTIONAL behavior change:
/// `GOLDEN_MASTER_REGENERATE=1 swift test --filter GoldenMasterStoreStateTests`
/// rewrites the committed file (then review the diff like code).
@Suite("Golden master store state", .serialized, .timeLimit(.minutes(2)))
struct GoldenMasterStoreStateTests {
    private static var artifactURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/GoldenMasterStoreState/baseline.txt")
    }

    private static func makeScratch() throws -> (wiki: URL, queue: URL, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("golden-master-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let wiki = root.appendingPathComponent("wiki", isDirectory: true)
        try FileManager.default.createDirectory(at: wiki, withIntermediateDirectories: true)
        return (wiki, root.appendingPathComponent("queue.sqlite"), root)
    }

    @Test("fixture sequence matches the committed baseline artifact")
    @MainActor
    func matchesCommittedBaseline() async throws {
        let scratch = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.root) }
        let dump = try await GoldenMasterStoreState.runFixture(
            wikiDirectory: scratch.wiki, queueURL: scratch.queue)

        let regenerate = ProcessInfo.processInfo.environment["GOLDEN_MASTER_REGENERATE"] == "1"
        if regenerate {
            try dump.write(to: Self.artifactURL, atomically: true, encoding: .utf8)
            Issue.record("baseline regenerated at \(Self.artifactURL.path) — review the diff, then commit")
            return
        }

        let baseline = try String(contentsOf: Self.artifactURL, encoding: .utf8)
        let expected = baseline.split(separator: "\n", omittingEmptySubsequences: false)
        let actual = dump.split(separator: "\n", omittingEmptySubsequences: false)
        if expected != actual {
            var differences: [String] = []
            for index in 0..<max(expected.count, actual.count) {
                let e = index < expected.count ? String(expected[index]) : "<missing>"
                let a = index < actual.count ? String(actual[index]) : "<missing>"
                if e != a {
                    differences.append("line \(index + 1):\n  baseline: \(e)\n  actual:   \(a)")
                    if differences.count >= 12 { break }
                }
            }
            #expect(
                Bool(false),
                Comment(rawValue: """
                golden-master drift: \(differences.count)+ differing lines \
                (baseline \(expected.count) lines vs actual \(actual.count) lines)
                \(differences.joined(separator: "\n"))
                If the behavior change is INTENTIONAL, regenerate with \
                GOLDEN_MASTER_REGENERATE=1 and review the diff.
                """))
        } else {
            #expect(true)
        }
    }

    /// Determinism guard: the same fixture run twice on fresh databases must
    /// produce byte-identical dumps (no leaked wall-clock or random state).
    @Test("exporter is deterministic across fresh runs")
    @MainActor
    func exporterIsDeterministic() async throws {
        let first = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: first.root) }
        let second = try Self.makeScratch()
        defer { try? FileManager.default.removeItem(at: second.root) }
        let dumpA = try await GoldenMasterStoreState.runFixture(
            wikiDirectory: first.wiki, queueURL: first.queue)
        let dumpB = try await GoldenMasterStoreState.runFixture(
            wikiDirectory: second.wiki, queueURL: second.queue)
        if dumpA != dumpB {
            // Same shape as the baseline-drift report: show the first
            // differing lines so a determinism regression is diagnosable
            // without re-running the fixture by hand.
            let aLines = dumpA.split(separator: "\n").map(String.init)
            let bLines = dumpB.split(separator: "\n").map(String.init)
            var differences: [String] = []
            for (index, pair) in zip(aLines, bLines).enumerated() {
                if pair.0 != pair.1 {
                    differences.append("line \(index + 1):\n  A: \(pair.0)\n  B: \(pair.1)")
                }
                if differences.count >= 12 { break }
            }
            #expect(
                Bool(false),
                Comment(rawValue: """
                determinism drift: \(differences.count)+ differing lines \
                (A \(aLines.count) lines vs B \(bLines.count) lines)
                \(differences.joined(separator: "\n"))
                """))
        } else {
            #expect(true)
        }
    }
}
