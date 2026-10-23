import Foundation
import Testing
import WikiFSTypes
@testable import WikiFSCore
@testable import WikiCtlCore

/// AC.6 exact-patch contract: parser round-trip, validation rejections,
/// exact-byte preservation in exact-body mode, atomicity (a rejected or
/// conflicted patch writes nothing and emits nothing), and AC.8 citation/
/// provenance integrity.
@MainActor
@Suite
struct PagePatchCommandTests {

    private func tempStore() throws -> GRDBWikiStore {
        try TestStoreFactory.inMemory()
    }

    private func hunkJSON(start: Int, end: Int, old: String, new: String, reason: String = "fix damage") -> String {
        #"{"startByte":\#(start),"endByte":\#(end),"oldText":"\#(old)","newText":"\#(new)","reason":"\#(reason)"}"#
    }

    // MARK: - Parser round-trip (AC.6 parserAndWireRoundTrip)

    @Test func parserAcceptsAlternatingPairsAndRoundTrips() throws {
        let invocation = try ArgumentParser.parse(
            [
                "--wiki", "test", "page", "patch",
                "--id", "01HZPATCH0000000000000000001",
                "--expect-head", "01HZHEAD00000000000000000001",
                "--hunk", hunkJSON(start: 0, end: 5, old: "AAAAA", new: "BBBBB"),
                "--defect", "D01",
                "--hunk", hunkJSON(start: 10, end: 12, old: "CC", new: "", reason: "drop merge marker"),
                "--defect", "D15",
            ],
            env: { _ in nil })
        guard case .page(.patch(let id, let expectHead, let hunks, let classes, _)) = invocation.command else {
            Issue.record("expected .page(.patch)")
            return
        }
        #expect(id == PageID(rawValue: "01HZPATCH0000000000000000001"))
        #expect(expectHead == PageVersionID(rawValue: "01HZHEAD00000000000000000001"))
        #expect(hunks.count == 2)
        #expect(classes == [.fenceBoundaryDamage, .duplicateBlocksOrMergeResidue])
        #expect(hunks[0].startByte == 0 && hunks[0].endByte == 5)
        #expect(hunks[0].oldText == "AAAAA" && hunks[0].newText == "BBBBB")
        #expect(hunks[1].newText.isEmpty)
    }

    /// The strict `--hunk <json> --defect <class>` alternation: reversed
    /// order, consecutive hunks, unpaired classes, and unequal counts all
    /// reject with a typed usage error.
    @Test func parserRejectsMalformedPairing() throws {
        let head = ["--wiki", "test", "page", "patch",
                    "--id", "01HZPATCH0000000000000000001",
                    "--expect-head", "01HZHEAD00000000000000000001"]

        func usageMessage(_ arguments: [String]) -> String {
            do {
                _ = try ArgumentParser.parse(head + arguments, env: { _ in nil })
                return "expected a usage failure"
            } catch {
                // Any error type — the assertion inspects the message.
                return String(describing: error)
            }
        }

        // Reversed order: defect before hunk.
        let reversed = usageMessage([
            "--defect", "D01",
            "--hunk", hunkJSON(start: 0, end: 1, old: "A", new: "B"),
        ])
        #expect(reversed.contains("reversed order"), "got: \(reversed)")
        // Consecutive hunks (an unpaired class at position 3).
        let consecutive = usageMessage([
            "--hunk", hunkJSON(start: 0, end: 1, old: "A", new: "B"),
            "--hunk", hunkJSON(start: 2, end: 3, old: "C", new: "D"),
            "--defect", "D01",
        ])
        #expect(consecutive.contains("consecutive hunks"), "got: \(consecutive)")
        // Unpaired trailing class.
        let unpaired = usageMessage([
            "--hunk", hunkJSON(start: 0, end: 1, old: "A", new: "B"),
            "--defect", "D01",
            "--defect", "D15",
        ])
        #expect(unpaired.contains("unpaired"), "got: \(unpaired)")
        // No hunks at all.
        let empty = usageMessage([])
        #expect(empty.contains("at least one --hunk"), "got: \(empty)")
        // Inline + file forms combined.
        let combined = usageMessage([
            "--hunk", hunkJSON(start: 0, end: 1, old: "A", new: "B"),
            "--defect", "D01",
            "--hunk-file", "/tmp/hunks.json",
        ])
        #expect(combined.contains("cannot be combined"), "got: \(combined)")
        // Unknown class.
        let unknownClass = usageMessage([
            "--hunk", hunkJSON(start: 0, end: 1, old: "A", new: "B"),
            "--defect", "D99",
        ])
        #expect(unknownClass.contains("unknown defect class"), "got: \(unknownClass)")
    }

    /// The `--hunk-file` form round-trips: versioned array, per-hunk class,
    /// and the wrong version rejects.
    @Test func hunkFileRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("page-patch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("hunks.json")
        let document = PagePatchHunkFile(hunks: [
            .init(defect: "D25", startByte: 0, endByte: 3, oldText: "```", newText: "", reason: "unwrap"),
        ])
        try JSONEncoder().encode(document).write(to: path)
        let invocation = try ArgumentParser.parse(
            [
                "--wiki", "test", "page", "patch",
                "--id", "01HZPATCH0000000000000000001",
                "--expect-head", "01HZHEAD00000000000000000001",
                "--hunk-file", path.path,
            ],
            env: { _ in nil })
        guard case .page(.patch(_, _, let hunks, let classes, _)) = invocation.command else {
            Issue.record("expected .page(.patch)")
            return
        }
        #expect(hunks.count == 1 && classes == [.wholeBodyFenceWrap])

        // Wrong version rejects.
        let stale = PagePatchHunkFile(version: 99, hunks: document.hunks)
        try JSONEncoder().encode(stale).write(to: path)
        do {
            _ = try ArgumentParser.parse(
                [
                    "--wiki", "test", "page", "patch",
                    "--id", "01HZPATCH0000000000000000001",
                    "--expect-head", "01HZHEAD00000000000000000001",
                    "--hunk-file", path.path,
                ],
                env: { _ in nil })
            Issue.record("expected a version rejection")
        } catch let failure as ArgumentParser.Failure {
            #expect(failure.description.contains("version"))
        }
    }

    // MARK: - Validator rejections (AC.6 rejectsInvalidHunks)

    @Test func validatorRejectsInvalidHunks() throws {
        let body = "Hello world, hello table."
        let head = PageVersionID(rawValue: "01HZHEAD00000000000000000001")
        let page = PageID(rawValue: "01HZPATCH0000000000000000001")

        func rejects(_ patch: PagePatch) -> Bool {
            do {
                _ = try PagePatchValidator.composedBody(applying: patch, to: body)
                return false
            } catch {
                return true
            }
        }

        // Empty request.
        #expect(rejects(PagePatch(pageID: page, expectHead: head, hunks: [], defectClasses: [])))
        // Unpaired classes.
        #expect(rejects(PagePatch(
            pageID: page, expectHead: head,
            hunks: [PagePatchHunk(startByte: 0, endByte: 5, oldText: "Hello", newText: "Bye", reason: "r")],
            defectClasses: [])))
        // Reversed range / out of bounds.
        #expect(rejects(PagePatch(
            pageID: page, expectHead: head,
            hunks: [PagePatchHunk(startByte: 6, endByte: 5, oldText: "", newText: "x", reason: "r")],
            defectClasses: [.fenceBoundaryDamage])))
        #expect(rejects(PagePatch(
            pageID: page, expectHead: head,
            hunks: [PagePatchHunk(startByte: 0, endByte: 999, oldText: body, newText: "x", reason: "r")],
            defectClasses: [.fenceBoundaryDamage])))
        // Mismatched old text.
        #expect(rejects(PagePatch(
            pageID: page, expectHead: head,
            hunks: [PagePatchHunk(startByte: 0, endByte: 5, oldText: "HELLO", newText: "x", reason: "r")],
            defectClasses: [.fenceBoundaryDamage])))
        // Overlapping ranges.
        #expect(rejects(PagePatch(
            pageID: page, expectHead: head,
            hunks: [
                PagePatchHunk(startByte: 0, endByte: 8, oldText: "Hello wo", newText: "x", reason: "r"),
                PagePatchHunk(startByte: 6, endByte: 11, oldText: "orld", newText: "y", reason: "r"),
            ],
            defectClasses: [.fenceBoundaryDamage, .fenceBoundaryDamage])))
        // Repeated insertion position (two empty-range hunks at one offset).
        #expect(rejects(PagePatch(
            pageID: page, expectHead: head,
            hunks: [
                PagePatchHunk(startByte: 5, endByte: 5, oldText: "", newText: "a", reason: "r"),
                PagePatchHunk(startByte: 5, endByte: 5, oldText: "", newText: "b", reason: "r"),
            ],
            defectClasses: [.fenceBoundaryDamage, .fenceBoundaryDamage])))
        // A report-only class cannot authorize a hunk.
        #expect(rejects(PagePatch(
            pageID: page, expectHead: head,
            hunks: [PagePatchHunk(startByte: 0, endByte: 5, oldText: "Hello", newText: "x", reason: "r")],
            defectClasses: [.listNestingDamage])))
        // An oversized payload rejects.
        let giant = String(repeating: "x", count: PagePatch.maxPayloadBytes)
        #expect(rejects(PagePatch(
            pageID: page, expectHead: head,
            hunks: [PagePatchHunk(startByte: 0, endByte: 5, oldText: "Hello", newText: giant, reason: "r")],
            defectClasses: [.fenceBoundaryDamage])))
    }

    // MARK: - Exact bytes (AC.6 untouchedBytesRemainExact)

    /// A committed patch preserves every byte outside the hunks EXACTLY —
    /// no canonicalization, no cosmetic fixup, no whitespace normalization —
    /// even where an ordinary `page add` upsert would rewrite.
    @Test func untouchedBytesRemainExact() throws {
        let store = try tempStore()
        let source = try store.addSource(filename: "s.md", data: Data("raw".utf8))
        // The body is DELIBERATELY noncanonical: an unresolvable raw-title
        // link, double blank lines, trailing spaces — `upsertPage` would
        // canonicalize/normalize; the patch must not.
        let body = "Keep   this  exactly.\n\n\n[[Source: Smith2023]] stays\n"
        let page = try store.createPage(
            title: "Patch Page", body: body,
            provenance: [.init(sourceID: source.id, role: .primary)])
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Patch Page", body: body,
            expectedHeadVersionID: nil,
            provenance: [.init(sourceID: source.id, role: .primary)])
        let head = try #require(try store.pageHeadVersionID(pageID: page.id))

        // One hunk: replace "world"-shaped text at its ACTUAL byte offset.
        let target = "this"
        let offset = body.utf8.distance(
            from: body.utf8.startIndex,
            to: body.range(of: target)!.lowerBound.samePosition(in: body.utf8)!)
        let outcome = try store.patchPage(
            PagePatch(
                pageID: page.id, expectHead: head,
                hunks: [PagePatchHunk(
                    startByte: offset, endByte: offset + target.utf8.count,
                    oldText: target, newText: "that", reason: "typo")],
                defectClasses: [.encodingDamage]),
            author: PageAuthor.agent("lint").rawValue)

        let stored = try store.getPage(id: page.id)
        #expect(stored.bodyMarkdown == "Keep   that  exactly.\n\n\n[[Source: Smith2023]] stays\n")
        #expect(outcome.writtenHead != head)
        #expect(outcome.writtenFingerprint == LintPageSnapshot.fingerprint(of: stored.bodyMarkdown))
        #expect(outcome.appliedClasses == [.encodingDamage])
    }

    // MARK: - Atomicity + event counts (AC.6 rollbackAndEventCounts)

    /// A rejected patch writes NO version, changes NO bytes, and emits NO
    /// page event; a CAS conflict behaves the same.
    @Test func rejectedPatchWritesNothingAndEmitsNothing() async throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Atomic", body: "first body")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Atomic", body: "first body", expectedHeadVersionID: nil)
        let head = try #require(try store.pageHeadVersionID(pageID: page.id))

        var events: [ResourceChangeEvent] = []
        let bus = WikiEventBus(wikiID: WikiID(rawValue: "01HZBUS0000000000000000001"))
        bus.subscribe(nil) { event in events.append(event) }
        store.eventBus = bus

        // Rejected: old-text mismatch.
        #expect(throws: PagePatchValidationError.self) {
            try store.patchPage(
                PagePatch(
                    pageID: page.id, expectHead: head,
                    hunks: [PagePatchHunk(startByte: 0, endByte: 5, oldText: "WRONG", newText: "x", reason: "r")],
                    defectClasses: [.encodingDamage]),
                author: nil)
        }
        // Conflicted: stale head.
        let otherHead = PageVersionID(rawValue: "01HZHEAD00000000000000000099")
        #expect(throws: PageConflictError.self) {
            try store.patchPage(
                PagePatch(
                    pageID: page.id, expectHead: otherHead,
                    hunks: [PagePatchHunk(startByte: 0, endByte: 5, oldText: "first", newText: "x", reason: "r")],
                    defectClasses: [.encodingDamage]),
                author: nil)
        }
        // Settle async event delivery.
        try await Task.sleep(for: .milliseconds(50))

        #expect(events.isEmpty, "a rejected or conflicted patch emits no page event")
        #expect(try store.getPage(id: page.id).bodyMarkdown == "first body")
        #expect(try store.pageVersionHistory(pageID: page.id).count == 1)
        #expect(try store.pageHeadVersionID(pageID: page.id) == head)

        // A COMMITTED patch emits exactly one event.
        _ = try store.patchPage(
            PagePatch(
                pageID: page.id, expectHead: head,
                hunks: [PagePatchHunk(startByte: 0, endByte: 5, oldText: "first", newText: "third", reason: "r")],
                defectClasses: [.encodingDamage]),
            author: nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(events.count == 1)
        #expect(events.first?.change == .updated)
    }

    // MARK: - Citation + provenance integrity (AC.8)

    /// A hunk that ADDS a citation with a quote verifies the quote against
    /// the source's stored text; an invented quote fails the run before any
    /// version is created.
    @Test func addedCitationQuoteIsChecked() throws {
        let store = try tempStore()
        let source = try store.addSource(
            filename: "Bassham1950.md",
            data: Data("raw".utf8))
        // Store the extracted markdown head containing the quotable text.
        _ = try store.appendDerivedMarkdown(
            sourceID: source.id,
            content: "The dark reactions of photosynthesis happen in the stroma.",
            origin: .extraction, producer: .tool(.pdf2md), providerID: nil,
            modelID: nil, toolVersion: nil, sourceVersionID: nil, note: nil)
        let page = try store.createPage(title: "Citations", body: "A claim.\n")
        let head = try #require(try store.pageHeadVersionID(pageID: page.id))

        // The genuine quote passes integrity and commits (quotes are
        // whitespace-normalized but CASE-SENSITIVE — match the source text).
        let composed = "A claim.[^1]\n\n[^1]: See [[source:\(source.id.rawValue)#\"The dark reactions of photosynthesis\"]].\n"
        let insertHunk = PagePatchHunk(
            startByte: 8, endByte: 8, oldText: "", newText: "[^1]\n\n[^1]: See [[source:\(source.id.rawValue)#\"The dark reactions of photosynthesis\"]].",
            reason: "attach the missing citation")

        // The genuine quote passes integrity and commits.
        let outcome = try store.patchPage(
            PagePatch(
                pageID: page.id, expectHead: head,
                hunks: [insertHunk],
                defectClasses: [.brokenTarget]),
            author: PageAuthor.agent("lint").rawValue)
        #expect(try store.getPage(id: page.id).bodyMarkdown == composed)
        // The added citation's source became a provenance input (role quoted),
        // UNIONED with the head's existing inputs — nothing deleted.
        let headSources = try store.pageHeadSources(pageID: page.id)
        #expect(headSources.contains { $0.sourceID == source.id && $0.role == .quoted })
        _ = outcome

        // An INVENTED quote fails before writing (page back to its prior
        // state — the committed version above is the head; a fresh head read).
        let currentHead = try #require(try store.pageHeadVersionID(pageID: page.id))
        let bodyNow = try store.getPage(id: page.id).bodyMarkdown
        let offset = bodyNow.utf8.count
        let invented = PagePatchHunk(
            startByte: offset, endByte: offset, oldText: "",
            newText: "\n\n[^2]: [[source:\(source.id.rawValue)#\"this sentence appears nowhere\"]].",
            reason: "fabrication test")
        #expect(throws: PagePatchIntegrityError.self) {
            try store.patchPage(
                PagePatch(
                    pageID: page.id, expectHead: currentHead,
                    hunks: [invented],
                    defectClasses: [.brokenTarget]),
                author: nil)
        }
        #expect(try store.getPage(id: page.id).bodyMarkdown == composed,
                "a rejected integrity check leaves the page unchanged")
        #expect(try store.pageHeadVersionID(pageID: page.id) == currentHead)
    }

    /// A citation whose quote text exists only in a NON-pinned extraction is
    /// rejected when the pin names a version that lacks it — the pin is
    /// authoritative (AC.8 pinnedVersionIsAuthoritative).
    @Test func pinnedQuoteChecksThePinnedVersion() throws {
        let store = try tempStore()
        let source = try store.addSource(filename: "Pinned.md", data: Data("raw".utf8))
        _ = try store.appendDerivedMarkdown(
            sourceID: source.id, content: "version one text", origin: .extraction,
            producer: .tool(.pdf2md), providerID: nil, modelID: nil,
            toolVersion: nil, sourceVersionID: nil, note: nil)
        _ = try store.appendDerivedMarkdown(
            sourceID: source.id, content: "version two text", origin: .extraction,
            producer: .tool(.pdf2md), providerID: nil, modelID: nil,
            toolVersion: nil, sourceVersionID: nil, note: nil)
        // Derive the pin ordinals from the store's ACTUAL version order —
        // ULIDs are not monotonic within one millisecond, so the seed's
        // write order does not pin the ordinal order.
        let history = try store.processedMarkdownHistory(sourceID: source.id)
        let ordered = history.sorted { $0.id.rawValue < $1.id.rawValue }
        let ordinalOf: (String) throws -> Int = { content in
            guard let index = ordered.firstIndex(where: { $0.content == content }) else {
                throw PagePatchIntegrityError.unresolvedAddedCitation(content)
            }
            return index + 1
        }
        let v1 = try ordinalOf("version one text")
        let v2 = try ordinalOf("version two text")
        let page = try store.createPage(title: "Pinned", body: "Claim.\n")
        let head = try #require(try store.pageHeadVersionID(pageID: page.id))

        // A quote from the OTHER version, cited against @v<other>, rejects —
        // the pin is authoritative (AC.8 pinnedVersionIsAuthoritative).
        #expect(throws: PagePatchIntegrityError.self) {
            try store.patchPage(
                PagePatch(
                    pageID: page.id, expectHead: head,
                    hunks: [PagePatchHunk(
                        startByte: 7, endByte: 7, oldText: "",
                        newText: "[[source:\(source.id.rawValue)@v\(v1)#\"version two text\"]]",
                        reason: "r")],
                    defectClasses: [.brokenTarget]),
                author: nil)
        }
        // The same quote against its OWN pin passes.
        _ = try store.patchPage(
            PagePatch(
                pageID: page.id, expectHead: head,
                hunks: [PagePatchHunk(
                    startByte: 7, endByte: 7, oldText: "",
                    newText: "[[source:\(source.id.rawValue)@v\(v2)#\"version two text\"]]",
                    reason: "r")],
                defectClasses: [.brokenTarget]),
            author: nil)
        #expect(try store.getPage(id: page.id).bodyMarkdown.contains("@v\(v2)"))
    }
}
