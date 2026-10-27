import Foundation
import Testing
import WikiFSLinks
import WikiFSCore
import WikiFSTypes

/// AC.7 (pure half) — the model evidence seam: budgets, identity labels,
/// quote-window excerpts, omission counts, and stability under store
/// mutation. These tests validate SERIALIZATION AND ADMISSION, not model
/// obedience. (Session wiring lives in the opt-in app tier.)
struct LintEvidenceTests {

    private let sourceID = SourceID(rawValue: "01M58TQS3ZHJC1YCDPJ327AYW2")

    private func snapshot(
        body: String,
        records: [LintCapturedSourceVersion],
        parent: LintCapturedParentVersion? = nil,
        notices: [LintCaptureNotice] = []
    ) -> LintPageSnapshot {
        LintPageSnapshot(
            wikiID: WikiID(rawValue: "w"), pageID: PageID(rawValue: "p"),
            title: "T", body: body, headVersionID: PageVersionID(rawValue: "v"),
            strategyRevision: nil, strategyContext: "",
            relatedResources: .empty,
            citations: LintCitationEvidence(
                occurrences: LintCitationOccurrence.parseAll(in: body),
                sourceVersions: records,
                nameIndex: .unavailable,
                notices: notices,
                isAvailable: true),
            parent: parent)
    }

    private func record(
        _ id: SourceID, text: String, complete: Bool = true,
        request: LintSourceVersionRequest = .active
    ) -> LintCapturedSourceVersion {
        let bytes = text.utf8.count
        return LintCapturedSourceVersion(
            sourceID: id, request: request,
            resolvedVersionID: SourceMarkdownVersionID(rawValue: "smv"),
            status: .present, text: text,
            completeness: complete ? .complete : .prefix(originalByteCount: bytes + 10),
            digest: LintSnapshotDigest.digest(of: text),
            originalByteCount: complete ? nil : bytes + 10)
    }

    @Test func lintEvidencePromptBudgetsAndIdentity() throws {
        // Identity: the serialized evidence carries source id, requested
        // pin, resolved version id, digest, availability, and excerpt.
        let body = "Claim.[^a]\n\n[^a]: [[source:\(sourceID.rawValue)@v2#\"needle in the source\"|a]]\n"
        // Long pre-needle text (beyond the 1 KiB quote window) proves the
        // excerpt centers on the match instead of the bare prefix.
        let text = String(repeating: "intro ", count: 400) + "needle in the source inside and suffix text"
        let snap = snapshot(
            body: body,
            records: [record(sourceID, text: text,
                             request: .pinned(LintSourceVersionPin(ordinal: 2)!))])
        let selection = LintEvidence.selection(snapshot: snap, quoteHints: ["needle in the source"])
        #expect(selection.isUsable)
        #expect(selection.json.contains("\"\(sourceID.rawValue.uppercased())\""))
        #expect(selection.json.contains("\"v2\""))
        #expect(selection.json.contains("smv"))
        #expect(selection.json.contains(LintSnapshotDigest.digest(of: text).prefix(12)))
        #expect(selection.json.contains("complete"))
        // The excerpt centers on the quote (windowed, not the bare prefix):
        // at most ~1 KiB of the 2.4 KiB intro run survives ahead of the
        // needle, so a 200-intro run cannot be present.
        #expect(selection.json.contains("needle in the source"))
        #expect(!selection.json.contains(String(repeating: "intro ", count: 200)))

        // Exactly at the body limit: the model step runs.
        let limit = LintEvidenceBudgets.maxPageBodyBytes
        let exactBody = String(repeating: "a", count: limit)
        let exactSnap = snapshot(body: exactBody, records: [])
        #expect(LintEvidence.pageBodySkipReason(exactSnap.body) == nil)
        // One byte over: skipped with a typed reason.
        let overBody = String(repeating: "a", count: limit + 1)
        #expect(LintEvidence.pageBodySkipReason(overBody)?.contains("did not run") == true)

        // Multibyte boundary: exactly-at-limit bodies measured in BYTES.
        let emojiBodyExact = String(repeating: "😀", count: limit / 4)
        #expect(emojiBodyExact.utf8.count == limit)
        #expect(LintEvidence.pageBodySkipReason(emojiBodyExact) == nil)

        // The 64 KiB evidence cap excludes the page body: a huge body with
        // tiny evidence still passes the evidence gate.
        let hugeSnap = snapshot(body: String(repeating: "a", count: 200_000), records: [])
        let hugeSelection = LintEvidence.selection(snapshot: hugeSnap, quoteHints: [])
        #expect(hugeSelection.isUsable)
        #expect(hugeSelection.json.utf8.count <= LintEvidenceBudgets.maxSerializedEvidenceBytes)

        // Omission counting: records beyond the cap are counted, never
        // silently dropped.
        let many = (0..<12).map { index -> LintCapturedSourceVersion in
            record(
                SourceID(rawValue: "01M58TQS3ZHJC1YCDPJ327AYW\(String(index).first!)"),
                text: "text \(index)")
        }
        let manySnap = snapshot(body: body, records: many)
        let manySelection = LintEvidence.selection(snapshot: manySnap, quoteHints: [])
        #expect(manySelection.omittedSourceRecords == 4)
        #expect(manySelection.json.contains("not selected"))
    }

    @Test func lintEvidenceExcerptBudgetsClipAtScalarBoundaries() {
        // A record whose text exceeds the per-record budget clips at a
        // Unicode scalar boundary and keeps the prefix availability label.
        let multibyte = String(repeating: "😀", count: 5_000) // 20 000 bytes
        let snap = snapshot(body: "x", records: [record(sourceID, text: multibyte)])
        let selection = LintEvidence.selection(snapshot: snap, quoteHints: [])
        #expect(selection.isUsable)
        // Excerpt within the per-record budget; no replacement characters.
        #expect(!selection.json.contains("\u{FFFD}"))
        // Completeness metadata was NOT overwritten by the excerpt clip:
        // availability still says complete (the CAPTURE is complete; the
        // excerpt is bounded separately).
        #expect(selection.json.contains("\"availability\":\"complete\""))
    }

    @Test func lintEvidenceRemainsUnchangedAfterStoreMutation() async throws {
        // The evidence for a captured snapshot is a value: mutating the
        // store afterwards cannot change it, and re-selecting from the SAME
        // snapshot produces identical bytes.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lint-evidence-mutation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
        let source = try store.addSource(filename: "s.txt", data: Data("x".utf8))
        _ = try store.appendProcessedMarkdown(
            sourceID: source.id, content: "the original evidence text",
            origin: .extraction, note: nil)
        let body = "Claim.[^a]\n\n[^a]: [[source:\(source.id.rawValue)#\"original evidence\"|a]]\n"
        let created = try PageUpsert.upsert(in: store, id: nil, title: "P", body: body)
        let before = try #require(try store.lintCapture(pageID: created.id))
        let beforeSelection = LintEvidence.selection(
            snapshot: LintPageSnapshot(
                wikiID: WikiID(rawValue: "w"), pageID: created.id, title: "P",
                body: before.body, headVersionID: before.headVersionID,
                strategyRevision: nil, strategyContext: "", relatedResources: .empty,
                citations: before.citations, parent: before.parent),
            quoteHints: ["original evidence"])

        // Mutate the store: source re-extracted and page rewritten.
        _ = try store.appendProcessedMarkdown(
            sourceID: source.id, content: "NEWER EXTRACTION", origin: .extraction, note: nil)
        let head = try #require(try store.pageHeadVersionID(pageID: created.id))
        _ = try PageUpsert.upsert(
            in: store, id: created.id, title: "P", body: "rewritten",
            expectation: .expectedHead(head))

        // The captured evidence still serializes to identical bytes.
        let afterSelection = LintEvidence.selection(
            snapshot: LintPageSnapshot(
                wikiID: WikiID(rawValue: "w"), pageID: created.id, title: "P",
                body: before.body, headVersionID: before.headVersionID,
                strategyRevision: nil, strategyContext: "", relatedResources: .empty,
                citations: before.citations, parent: before.parent),
            quoteHints: ["original evidence"])
        #expect(afterSelection.json == beforeSelection.json)
        #expect(beforeSelection.json.contains("the original evidence text"))
    }
}
