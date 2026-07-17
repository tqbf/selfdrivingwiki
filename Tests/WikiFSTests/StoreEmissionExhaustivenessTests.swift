import Testing
import Foundation
@testable import WikiFSCore

/// Partition-completeness guard (AC.2). Every `public func` on
/// `SQLiteWikiStore` must be classified into exactly one of
/// {EMIT, READ, NO_EMIT}, and every EMIT member must route through `mutate()`.
///
/// This is a *forward-looking* regression net, not a today-snapshot: a newly
/// added public mutating method that is left unclassified (or an EMIT method
/// that stops routing through `mutate()`) fails the test. See the Appendix of
/// `plans/event-bus.md` and `plans/architecture-roadmap.md` §3 decision 5.
struct StoreEmissionExhaustivenessTests {

    /// Loads the store source via the test file's own path (robust to the
    /// package being checked out anywhere). Returns nil if the file can't be
    /// found so the test can fail loudly rather than crash.
    private func storeSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        // Tests/WikiFSTests/<this>.swift -> up three = package root.
        let root = testFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Sources/WikiFSCore/SQLiteWikiStore.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every `public func` name declared on the store, in declaration order.
    private func publicFuncNames(_ source: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "public\\s+func\\s+([A-Za-z_][A-Za-z0-9_]*)")
        let ns = source as NSString
        let matches = pattern.matches(in: source, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { m in
            guard m.numberOfRanges > 1 else { return nil }
            return ns.substring(with: m.range(at: 1))
        }
    }

    /// The source text span for one method: from its `public func <name>` line
    /// up to (not including) the next function declaration of any access level.
    private func methodSpan(_ source: String, name: String) -> String {
        let lines = source.components(separatedBy: "\n")
        let declPattern = try! NSRegularExpression(pattern: "^\\s*(public|private|internal|fileprivate)?\\s*func\\s+")
        guard let start = lines.firstIndex(where: { $0.contains("public func \(name)(") || $0.contains("public func \(name)<") || $0.contains("public func \(name) ") || trimmedName($0) == name }) else {
            return ""
        }
        // Collect from start until the next func decl after start.
        var collected: [String] = []
        for line in lines[start...] {
            if !collected.isEmpty, declFirstMatch(declPattern, line) { break }
            collected.append(line)
        }
        return collected.joined(separator: "\n")
    }

    private func trimmedName(_ line: String) -> String {
        // "    public func fooBar(" -> "fooBar"
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("public func ") else { return "" }
        let rest = t.dropFirst("public func ".count)
        return String(rest.prefix(while: { $0.isLetter || $0 == "_" || $0.isNumber }))
    }

    private func declFirstMatch(_ re: NSRegularExpression, _ line: String) -> Bool {
        let r = NSRange(location: 0, length: (line as NSString).length)
        return re.firstMatch(in: line, range: r) != nil
    }

    // MARK: - The three partitions (seeded from the Appendix; kept in sync).

    private let emit: Set<String> = [
        "createPage", "updatePage", "deletePage", "replaceLinks",
        "appendPageVersion", "revertPage",
        "addSource", "addSnapshotImage", "addBytelessSource", "deleteSource",
        "appendContentVersion", "rollbackSourceContent", "renameSource",
        "setSourceDisplayName", "markSourceIngested", "updateSystemPrompt", "appendLog", "updateWikiIndex",
        "createBookmarkNode", "updateBookmarkNode", "deleteBookmarkNode",
        "moveBookmarkNode", "appendProcessedMarkdown", "recordMarkdownExtraction",
        "revertProcessedMarkdown", "setActiveMarkdown",
        "createChat", "appendChatMessages", "renameChat", "deleteChat",
        "updateChatSummary",
        "upsertConnection", "deleteConnection", "renameConnection",
    ]

    private let noEmit: Set<String> = [
        // Provenance helper (its effect folds into the snapshot/source flow that
        // already emits). Derived embeddings / search index (not in the change
        // token, no projected content change).
        "ensureFetchActivity", "storePageChunks", "storeSourceChunks", "storeChatChunks", "rebuildFTS",
        // Blob GC (#253): vacuuming orphaned blobs changes no projected
        // ResourceKind (blobs fold into the changeToken only via their version
        // rows), so no event is emitted.
        "vacuumBlobs",
        // Activity GC (#257): same rationale — vacuuming orphaned activities
        // changes no projected ResourceKind.
        "vacuumActivities",
        // Page-version GC (Phase 4): same rationale — vacuuming orphaned page
        // versions changes no projected ResourceKind (the served tree is
        // determined by the page-content ref targets, all in the reachable set).
        "vacuumPageVersions",
        // Workspaces (W1, PR #312): workspace writes are invisible to the FP
        // token — main is untouched until merge. The merge's per-page effects
        // emit via fastForwardPage/fastForwardCreatePage (which update the
        // pages mirror + main refs, triggering the existing page change path).
        "createWorkspace", "workspaceWritePage", "abandonWorkspace", "workspaceMerge",
        "workspaceRefresh", "workspaceResolveConflict", "workspaceRetryMerge",
        "setWorkspaceIndexBody",
        "reapStaleWorkspaces",
        // Wiki metadata (v37, issue #477): metadata flags gate one-time
        // maintenance work — they don't change projected ResourceKind.
        "setMetadata",
    ]

    /// Every EMIT member must route through `mutate()` (AC.2). A newly added
    /// mutator that bypasses the seam fails here — the load-bearing invariant.
    @Test func everyEmitMethodRoutesThroughMutate() throws {
        let source = try storeSource()
        for name in emit {
            let span = methodSpan(source, name: name)
            #expect(span.contains("mutate("), "EMIT method \(name) does not route through mutate()")
        }
    }

    /// The three partitions cover the whole public surface exactly once.
    @Test func partitionsCoverEveryPublicFunc() throws {
        let source = try storeSource()
        let all = Set(publicFuncNames(source))

        // READ = everything not EMIT or NO_EMIT.
        let read = all.subtracting(emit).subtracting(noEmit)

        // No overlap between EMIT and NO_EMIT.
        #expect(emit.intersection(noEmit).isEmpty, "EMIT ∩ NO_EMIT must be empty")

        // EMIT and NO_EMIT must each only name real public funcs (catches a
        // rename or a typo in the seed sets).
        #expect(emit.isSubset(of: all), "EMIT names a non-public func: \(emit.subtracting(all).sorted())")
        #expect(noEmit.isSubset(of: all), "NO_EMIT names a non-public func: \(noEmit.subtracting(all).sorted())")

        // The union must equal the full surface — no gap, no overlap.
        let union = emit.union(noEmit).union(read)
        #expect(union == all, "partition is incomplete; missing: \(all.subtracting(union).sorted()), extra: \(union.subtracting(all).sorted())")

        // READ methods must NOT route through mutate() (a read that mutates is a
        // smell; a read accidentally wrapped in mutate() would emit spuriously).
        for name in read {
            let span = methodSpan(source, name: name)
            #expect(!span.contains("mutate("), "READ method \(name) routes through mutate() — should not emit")
        }
    }
}
