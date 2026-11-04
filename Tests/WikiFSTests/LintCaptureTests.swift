import Foundation
import Testing
import WikiFSCore
import WikiFSTypes

/// AC.1 — coherent, version-aware capture on the real GRDB store: page +
/// requested source versions + the head's actual parent, read in ONE
/// transaction, with explicit statuses for every non-present outcome, named
/// budgets, and Unicode-boundary clipping. Both the pooled read path and the
/// model's memory fallback are covered.
@MainActor
struct LintCaptureTests {

    private func tempStore() throws -> GRDBWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lint-capture-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    /// A page citing a source: pinned @v2, unpinned active, and a quote.
    private func seedPinnedFixture(_ store: GRDBWikiStore) throws -> (
        page: PageID, source: SourceID
    ) {
        let source = try store.addSource(filename: "evidence.txt", data: Data("x".utf8))
        _ = try store.appendProcessedMarkdown(
            sourceID: source.id, content: "v1: oldest phrasing", origin: .extraction, note: nil)
        _ = try store.appendProcessedMarkdown(
            sourceID: source.id, content: "v2: the pinned phrasing", origin: .extraction, note: nil)
        _ = try store.appendProcessedMarkdown(
            sourceID: source.id, content: "v3: active head phrasing", origin: .extraction, note: nil)
        let body = """
        Claims.[^a]

        [^a]: [[source:\(source.id.rawValue)@v2#"the pinned phrasing"|pinned]]
        [^b]: [[source:\(source.id.rawValue)#"active head phrasing"|active]]
        """
        let created = try PageUpsert.upsert(in: store, id: nil, title: "Notes", body: body)
        return (created.id, source.id)
    }

    @Test func lintCaptureUsesPinnedAndActiveVersions() throws {
        let store = try tempStore()
        let (pageID, sourceID) = try seedPinnedFixture(store)
        let capture = try #require(try store.lintCapture(pageID: pageID))

        #expect(capture.citations.isAvailable)
        // Two distinct (id, request) records in authored order.
        #expect(capture.citations.sourceVersions.count == 2)
        let pinned = capture.citations.sourceVersions[0]
        let active = capture.citations.sourceVersions[1]
        #expect(pinned.request.pin?.ordinal == 2)
        #expect(pinned.status == .present)
        #expect(pinned.text == "v2: the pinned phrasing")
        #expect(pinned.isComplete)
        #expect(active.request == .active)
        #expect(active.status == .present)
        #expect(active.text == "v3: active head phrasing")
        #expect(capture.citations.occurrences.count == 2)
        // Quote fragments parsed per occurrence.
        #expect(capture.citations.occurrences[0].quote == "the pinned phrasing")
        #expect(capture.citations.occurrences[1].quote == "active head phrasing")
        _ = sourceID
    }

    @Test func lintCaptureUsesActualParent() throws {
        let store = try tempStore()
        let created = try PageUpsert.upsert(in: store, id: nil, title: "Notes", body: "first body")
        _ = try PageUpsert.upsert(
            in: store, id: created.id, title: "Notes", body: "second body",
            expectation: .expectedHead(try #require(try store.pageHeadVersionID(pageID: created.id))))
        let capture = try #require(try store.lintCapture(pageID: created.id))
        let parent = try #require(capture.parent)
        #expect(parent.status == .captured)
        #expect(parent.completeness?.isComplete == true)
        #expect(parent.text == "first body")
        #expect(parent.bodyDigest == LintSnapshotDigest.digest(of: "first body"))
        // The parent id is the HEAD's declared parent (the first version),
        // not merely "some older row".
        let head = try #require(try store.pageHeadVersionID(pageID: created.id))
        let history = try store.pageVersionHistory(pageID: created.id)
        #expect(history.count == 2)
        #expect(parent.parentVersionID != head)

        // A first version is not applicable — a status, not a failure.
        let fresh = try PageUpsert.upsert(in: store, id: nil, title: "First", body: "only")
        let freshCapture = try #require(try store.lintCapture(pageID: fresh.id))
        #expect(freshCapture.parent?.status == .firstVersion)
    }

    @Test func lintCaptureRemainsCoherentAcrossExternalCommit() throws {
        let store = try tempStore()
        let (pageID, sourceID) = try seedPinnedFixture(store)
        let before = try #require(try store.lintCapture(pageID: pageID))
        let beforeDigest = before.citations.sourceVersions[1].digest

        // An external writer advances the page AND the source.
        let head = try #require(try store.pageHeadVersionID(pageID: pageID))
        _ = try PageUpsert.upsert(
            in: store, id: pageID, title: "Notes", body: "rewritten without citations",
            expectation: .expectedHead(head))
        _ = try store.appendProcessedMarkdown(
            sourceID: sourceID, content: "v4: newer extraction", origin: .extraction, note: nil)

        // The captured evidence still describes the CAPTURED state — every
        // retained page/source/parent fact belongs to that state.
        let after = try #require(try store.lintCapture(pageID: pageID))
        #expect(before.body == """
        Claims.[^a]

        [^a]: [[source:\(sourceID.rawValue)@v2#"the pinned phrasing"|pinned]]
        [^b]: [[source:\(sourceID.rawValue)#"active head phrasing"|active]]
        """)
        #expect(before.citations.sourceVersions[1].text == "v3: active head phrasing")
        #expect(before.citations.sourceVersions[1].digest == beforeDigest)
        // The rewritten page no longer cites anything: no occurrences, and
        // no source-version loads are planned.
        #expect(after.body == "rewritten without citations")
        #expect(after.citations.occurrences.isEmpty)
        #expect(after.citations.sourceVersions.isEmpty)
    }

    @Test func lintCaptureMissingAndUnresolvableTargetsAreTyped() throws {
        let store = try tempStore()
        let ghost = SourceID(rawValue: "01M58TQS3ZHJC1YCDPJ327AYZ9")
        let noExtraction = try store.addSource(filename: "raw.pdf", data: Data("%PDF".utf8))
        let body = """
        [^a]: [[source:\(ghost.rawValue)#"quote"|g]]
        [^b]: [[source:\(noExtraction.id.rawValue)#"quote"|r]]
        [^c]: [[source:\(ghost.rawValue)@v1#"quote"|gpin]]
        """
        let created = try PageUpsert.upsert(in: store, id: nil, title: "Notes", body: body)
        let capture = try #require(try store.lintCapture(pageID: created.id))
        // Ghost source: missing target (canonical id, unpinned AND pinned).
        #expect(capture.citations.sourceVersions.contains {
            $0.sourceID == ghost && $0.request == .active && $0.status == .missingTarget
        })
        #expect(capture.citations.sourceVersions.contains {
            $0.sourceID == ghost && $0.request.pin?.ordinal == 1 && $0.status == .missingTarget
        })
        // Real source with no derived markdown: unavailable extraction.
        #expect(capture.citations.sourceVersions.contains {
            $0.sourceID == noExtraction.id && $0.status == .unavailableExtraction
        })
    }

    @Test func lintCaptureBudgetsAndUnicodeBoundaries() throws {
        // Clipping never splits a Unicode scalar: a multibyte character that
        // straddles the byte limit stays whole, and the original byte count
        // is retained with the prefix flag.
        let text = String(repeating: "a", count: 9) + "😀" + String(repeating: "b", count: 9)
        // "a"×9 = 9 bytes; 😀 = 4 bytes (bytes 9–12); the 11-byte cut lands
        // inside the emoji and backs off to the scalar boundary at 9.
        let clipped = LintCaptureLimits.clipped(text, byteLimit: 11)
        #expect(clipped.text.utf8.count == 9)
        #expect(clipped.text == String(repeating: "a", count: 9))
        #expect(clipped.originalByteCount == text.utf8.count)
        #expect(!clipped.text.contains("\u{FFFD}"))
        // Under the limit: unchanged and complete.
        let whole = LintCaptureLimits.clipped(text, byteLimit: 1_000)
        #expect(whole.text == text)
        #expect(whole.originalByteCount == text.utf8.count)

        // Per-record budget compliance on a real store capture.
        let store = try tempStore()
        var citations = ""
        for index in 0..<2 {
            let source = try store.addSource(filename: "big\(index).txt", data: Data("x\(index)".utf8))
            let big = String(repeating: String(repeating: "z\(index)", count: 100) + "\n", count: 30)
            _ = try store.appendProcessedMarkdown(
                sourceID: source.id, content: big, origin: .extraction, note: nil)
            citations += "[^s\(index)]: [[source:\(source.id.rawValue)#\"zzz\"|s\(index)]]\n"
        }
        let page = try PageUpsert.upsert(
            in: store, id: nil, title: "Big", body: citations)
        let capture = try #require(try store.lintCapture(pageID: page.id))
        #expect(capture.citations.sourceVersions.count == 2)
        #expect(capture.citations.sourceVersions.allSatisfy { $0.status == .present })
        // Each record's text respects the per-record budget.
        #expect(capture.citations.sourceVersions.allSatisfy {
            ($0.text?.utf8.count ?? 0) <= LintCaptureLimits.maxBytesPerSourceVersion
        })
    }

    @Test func lintCaptureUsesReadService() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lint-capture-pool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("WikiFS.sqlite")
        let store = try GRDBWikiStore(databaseURL: url)
        let (pageID, _) = try seedPinnedFixture(store)

        // Pooled read path: a second read-only connection captures coherently.
        let service = WikiReadService(databaseURL: url)
        let pooled = try await service.asyncRead { access in
            try access.lintCapture(pageID: pageID)
        }
        #expect(pooled?.citations.sourceVersions.count == 2)
        #expect(pooled?.citations.sourceVersions[0].text == "v2: the pinned phrasing")
        #expect(pooled?.parent != nil)
    }

    @Test func lintCaptureMemoryFallback() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lint-capture-mem-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("WikiFS.sqlite")
        let store = try GRDBWikiStore(databaseURL: url)
        let (pageID, _) = try seedPinnedFixture(store)

        // Memory fallback: the model without a read service reads through
        // the main store. A missing page returns nil — that contract is nil
        // only for a genuinely missing page.
        let model = WikiStoreModel(store: store)
        let fallback = try await model.lintCaptureAsync(pageID: pageID)
        #expect(fallback?.citations.sourceVersions.count == 2)
        let missing = try await model.lintCaptureAsync(pageID: PageID(rawValue: "ghost"))
        #expect(missing == nil)
    }

    @Test func lintCaptureNameMultiplicityPreserved() throws {
        let store = try tempStore()
        // Both sources miss passes 1–2 (their stems differ from the query
        // stem) but their LOOSE keys collide (dash variants → spaces):
        // pass 3 sees two candidates → ambiguity, never a silent pick.
        let a = try store.addSource(filename: "Alpha–Report.txt", data: Data("a".utf8))
        let b = try store.addSource(filename: "Alpha—Report.md", data: Data("b".utf8))
        _ = try store.appendProcessedMarkdown(
            sourceID: a.id, content: "alpha", origin: .extraction, note: nil)
        _ = try store.appendProcessedMarkdown(
            sourceID: b.id, content: "beta", origin: .extraction, note: nil)
        let page = try PageUpsert.upsert(
            in: store, id: nil, title: "Amb", body: "[[source:Alpha Report.txt|ambiguous]]\n")
        let capture = try #require(try store.lintCapture(pageID: page.id))
        let resolution = capture.citations.nameIndex.resolve(name: "Alpha Report.txt")
        guard case .ambiguous(let candidates) = resolution else {
            Issue.record("Expected ambiguity, got \(resolution)")
            return
        }
        #expect(candidates.count == 2)
        // No load was planned for the ambiguous name.
        #expect(capture.citations.sourceVersions.isEmpty)
    }
}
