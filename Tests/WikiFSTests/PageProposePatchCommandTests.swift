import Foundation
import Testing
import WikiFSTypes
import WikiDaemonContract
@testable import WikiFSCore
@testable import WikiCtlCore

/// W5a tier 2: `page propose-patch` — the STAGED form of the patch write.
/// Parser parity with `page patch` (same acceptance AND same rejections,
/// relabeled), and the wire round trip: parse → daemon route → encode →
/// decode carries the exact hunks, classes, CAS head, and receipt.
@MainActor
@Suite
struct PageProposePatchCommandTests {

    private func hunkJSON(start: Int, end: Int, old: String, new: String, reason: String = "fix damage") -> String {
        #"{"startByte":\#(start),"endByte":\#(end),"oldText":"\#(old)","newText":"\#(new)","reason":"\#(reason)"}"#
    }

    private func parse(_ arguments: [String]) throws -> ArgumentParser.Command {
        try ArgumentParser.parse(
            ["--wiki", "test", "page", "propose-patch"] + arguments, env: { _ in nil }).command
    }

    // MARK: - Parser parity with page patch

    @Test func parserAcceptsAlternatingPairsAndRoundTrips() throws {
        let command = try parse([
            "--id", "01HZPATCH0000000000000000001",
            "--expect-head", "01HZHEAD00000000000000000001",
            "--hunk", hunkJSON(start: 0, end: 5, old: "AAAAA", new: "BBBBB"),
            "--defect", "D01",
            "--hunk", hunkJSON(start: 10, end: 12, old: "CC", new: "", reason: "drop merge marker"),
            "--defect", "D15",
            "--author", "agent:lint",
            "--lint-receipt", "receipt-token",
        ])
        guard case .page(.proposePatch(let id, let expectHead, let hunks, let classes, let author, let receipt)) = command else {
            Issue.record("expected .page(.proposePatch)")
            return
        }
        #expect(id == PageID(rawValue: "01HZPATCH0000000000000000001"))
        #expect(expectHead == PageVersionID(rawValue: "01HZHEAD00000000000000000001"))
        #expect(hunks.count == 2)
        #expect(classes == [.fenceBoundaryDamage, .duplicateBlocksOrMergeResidue])
        #expect(hunks[0].startByte == 0 && hunks[0].endByte == 5)
        #expect(hunks[0].oldText == "AAAAA" && hunks[0].newText == "BBBBB")
        #expect(hunks[1].newText.isEmpty)
        #expect(author == "agent:lint")
        #expect(receipt == "receipt-token")
    }

    /// The `--hunk-file` form round-trips through propose-patch too.
    @Test func hunkFileFormRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("propose-patch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dir)
        }
        let path = dir.appendingPathComponent("hunks.json")
        let document = PagePatchHunkFile(hunks: [
            .init(defect: "D25", startByte: 0, endByte: 3, oldText: "```", newText: "", reason: "unwrap"),
        ])
        try JSONEncoder().encode(document).write(to: path)
        let command = try parse([
            "--id", "01HZPATCH0000000000000000001",
            "--expect-head", "01HZHEAD00000000000000000001",
            "--hunk-file", path.path,
            "--lint-receipt", "receipt-token",
        ])
        guard case .page(.proposePatch(_, _, let hunks, let classes, _, _)) = command else {
            Issue.record("expected .page(.proposePatch)")
            return
        }
        #expect(hunks.count == 1 && classes == [.wholeBodyFenceWrap])
    }

    /// The same malformed-pairing rejections as `page patch`, labeled with
    /// the propose command name.
    @Test func parserRejectsMalformedPairingLikePatch() throws {
        let head = [
            "--id", "01HZPATCH0000000000000000001",
            "--expect-head", "01HZHEAD00000000000000000001",
        ]

        func usageMessage(_ arguments: [String]) -> String {
            do {
                _ = try parse(head + arguments)
                return "expected a usage failure"
            } catch {
                return String(describing: error)
            }
        }

        #expect(usageMessage([]).contains("propose-patch: at least one --hunk"))
        #expect(usageMessage([
            "--hunk", hunkJSON(start: 0, end: 1, old: "A", new: "B"),
            "--defect", "D01",
            "--hunk-file", "/tmp/hunks.json",
        ]).contains("propose-patch: --hunk-file cannot be combined"))
        #expect(usageMessage([
            "--hunk", hunkJSON(start: 0, end: 1, old: "A", new: "B"),
            "--defect", "D99",
        ]).contains("propose-patch: unknown defect class"))
        // Missing id / head, same as patch.
        #expect(usageMessageWith(head: [], arguments: [
            "--hunk", hunkJSON(start: 0, end: 1, old: "A", new: "B"),
            "--defect", "D01",
        ]).contains("--id is required"))
        #expect(usageMessageWith(head: ["--id", "01HZPATCH0000000000000000001"], arguments: [
            "--hunk", hunkJSON(start: 0, end: 1, old: "A", new: "B"),
            "--defect", "D01",
        ]).contains("--expect-head is required"))
    }

    private func usageMessageWith(head: [String], arguments: [String]) -> String {
        do {
            _ = try parse(head + arguments)
            return "expected a usage failure"
        } catch {
            return String(describing: error)
        }
    }

    // MARK: - Wire round trip (parse → route → encode → decode)

    /// The daemon route maps the action to the proposePatch operation and
    /// the encoded payload decodes to the exact same hunks, CAS head, and
    /// receipt the CLI parsed.
    @Test func wireRoundTripCarriesHunksHeadAndReceipt() throws {
        let invocation = try ArgumentParser.parse(
            [
                "--wiki", "test", "page", "propose-patch",
                "--id", "01HZPATCH0000000000000000001",
                "--expect-head", "01HZHEAD00000000000000000001",
                "--hunk", hunkJSON(start: 0, end: 5, old: "AAAAA", new: "BBBBB"),
                "--defect", "D01",
                "--lint-receipt", "receipt-token",
            ],
            env: { _ in nil })
        guard case .page(.proposePatch(let id, let expectHead, let hunks, let classes, _, let receipt)) = invocation.command else {
            Issue.record("expected .page(.proposePatch)")
            return
        }
        let call = try #require(DaemonCommandRoute.call(for: invocation.command))
        #expect(call.family == .page)
        #expect(call.operation == DaemonDomainOperation.Page.proposePatch)

        let payload = try call.payload("01HZWIKI00000000000000000001")
        let request = try JSONDecoder().decode(DaemonPageProposePatchRequest.self, from: payload)
        #expect(request.wikiID == "01HZWIKI00000000000000000001")
        #expect(request.id == id.rawValue)
        #expect(request.expectHead == expectHead.rawValue)
        #expect(request.lintReceipt == receipt)
        #expect(request.hunks.count == hunks.count)
        #expect(request.hunks[0].defect == classes[0].rawValue)
        #expect(request.hunks[0].startByte == hunks[0].startByte)
        #expect(request.hunks[0].oldText == hunks[0].oldText)
        #expect(request.hunks[0].newText == hunks[0].newText)
    }

    /// The bare-store command layer refuses the action: staging needs the
    /// managed run's receipt, budget, and staged state, which only the
    /// daemon owns.
    @Test func bareStoreRunRefuses() async throws {
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Propose Target", body: "# P\n")
        do {
            _ = try PageCommand.run(
                .proposePatch(
                    id: page.id,
                    expectHead: PageVersionID(rawValue: "01HZHEAD00000000000000000001"),
                    hunks: [PagePatchHunk(startByte: 0, endByte: 1, oldText: "#", newText: "", reason: "r")],
                    defectClasses: [.fenceBoundaryDamage],
                    author: "agent:lint"),
                in: store, linter: nil)
            Issue.record("a bare-store propose must refuse")
        } catch let failure as PageCommand.Failure {
            #expect(failure.description.contains("managed lint run"))
        }
    }
}
