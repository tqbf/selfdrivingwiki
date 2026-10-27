import Foundation
import Testing
import WikiFSCore
import WikiFSTypes

/// AC.9 — capture and every deterministic check make ZERO writes: no page
/// event, no new version, no provenance row, no body change. Apply remains
/// the only write seam (covered by `LintApplyStoreTests`).
struct LintReadOnlyPipelineTests {

    private func tempStore() throws -> GRDBWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lint-readonly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    @Test func expandedDetectionAndDiscardAreReadOnly() async throws {
        let store = try tempStore()
        let source = try store.addSource(filename: "evidence.txt", data: Data("x".utf8))
        _ = try store.appendProcessedMarkdown(
            sourceID: source.id, content: "alpha source text",
            origin: .extraction, note: nil)
        let body = """
        # Report

        | A | B |
        |---|---|
        | [[Index|Home|alias]] | two |

        Claim.[^a]

        [^a]: [[source:\(source.id.rawValue)#"absent quote"|a]]
        [^b]: [[source:\(source.id.rawValue)#"alpha source text"|b]]
        """
        let created = try PageUpsert.upsert(in: store, id: nil, title: "Notes", body: body)
        let head = try #require(try store.pageHeadVersionID(pageID: created.id))

        // Observe every store event during detection.
        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var events: [String] = []
            func append(_ name: String) { lock.lock(); events.append(name); lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return events.count }
        }
        let recorder = Recorder()
        store.eventBus?.subscribe(nil) { event in
            recorder.append("\(String(describing: event.kind))")
        }

        // The full deterministic pipeline over the captured snapshot.
        let capture = try #require(try store.lintCapture(pageID: created.id))
        let snapshot = LintPageSnapshot(
            wikiID: WikiID(rawValue: "w"), pageID: created.id, title: "Notes",
            body: capture.body, headVersionID: capture.headVersionID,
            strategyRevision: nil, strategyContext: "", relatedResources: .empty,
            citations: capture.citations, parent: capture.parent)
        let lookup = LintAnalyzer.RecipeLookup.none
        var allFindings: [LintFinding] = []
        for builtin in LintAnalyzer.BuiltinCheck.allCases {
            allFindings += LintAnalyzer.run(
                builtin, stepID: LintStepID(rawValue: "step"),
                snapshot: snapshot, facts: capture.facts, recipes: lookup)
        }

        // Detection produced the expected finding families.
        #expect(allFindings.contains { $0.ruleID?.rawValue == "table-alias-pipe" })
        #expect(allFindings.contains { $0.ruleID?.rawValue == "citation-fragment-missing" })

        // "Discard" is a pure no-op: the proposal is nil and nothing was
        // written. (There is nothing to reset — detection holds no state.)
        #expect(snapshot.bodyDigest == LintSnapshotDigest.digest(of: body))

        // ZERO writes: no page event, unchanged head, unchanged body, no
        // new version rows, no provenance growth.
        #expect(recorder.count == 0)
        #expect(try store.pageHeadVersionID(pageID: created.id) == head)
        #expect(try store.getPage(id: created.id).bodyMarkdown == body)
        #expect(try store.pageVersionHistory(pageID: created.id).count == 1)
        #expect(try store.processedMarkdownHistory(sourceID: source.id).count == 1)
    }
}
