#if os(macOS)
import Foundation
import Testing
import WikiFSCore
@testable import WikiFS

/// The shared delete-confirmation coordinator (issue #219 hardening, AC.9 /
/// AC.10): every impact state routes to the correct typed outcome with the
/// exact action set, deletion is invoked ONLY through the typed decision
/// mapping, and an impact-read failure can never reach deletion. The
/// container wiring is asserted by a source contract (both containers must
/// construct the shared coordinator — no per-view duplicate flows).
@MainActor
struct DeletionConfirmationCoordinatorTests {

    // MARK: - Fixtures

    private var pageID: PageID { PageID(rawValue: "01PAGETARGET00000000000000") }
    private var sourceID: SourceID { SourceID(rawValue: "01SOURCETARGET000000000000") }

    private func impact(
        linking: [PageID] = [],
        bookmarkCount: Int = 0,
        bookmarkSeed: Int = 0,
        blockers: [ProvenanceDeletionBlocker] = [],
        linkEdges: Int = 0
    ) -> DeletionImpact {
        DeletionImpact(
            linkingPages: linking.map { DeletionLinkingPage(pageID: $0, title: "T-\($0.rawValue.prefix(4))") },
            bookmarks: (0..<bookmarkCount).map {
                DeletionBookmarkImpact(
                    nodeID: BookmarkID(rawValue: String(format: "01BM%02d00000000000000000000", $0 + bookmarkSeed)),
                    folderPath: ($0 + bookmarkSeed) % 2 == 0 ? "Research" : "Bookmarks")
            },
            provenanceBlockers: blockers,
            incomingLinkCount: linkEdges)
    }

    /// Records whether (and how) the coordinator invoked deletion.
    private final class DecisionSink: @unchecked Sendable {
        private let lock = NSLock()
        private var decisions: [DeletionDecision] = []
        func record(_ d: DeletionDecision) { lock.lock(); decisions.append(d); lock.unlock() }
        var all: [DeletionDecision] { lock.lock(); defer { lock.unlock() }; return decisions }
        var count: Int { all.count }
    }

    private func makeCoordinator(
        kind: DeletionResourceKind,
        impacts: [DeletionImpact],
        count: Int = 1,
        sink: DecisionSink
    ) -> DeletionConfirmationCoordinator {
        DeletionConfirmationCoordinator(
            kind: kind,
            loadImpacts: { impacts },
            onDelete: { sink.record($0) },
            selectionCount: count)
    }

    private func blocker() -> ProvenanceDeletionBlocker {
        ProvenanceDeletionBlocker(
            sourceID: SourceID(rawValue: "01SOURCETARGET000000000000"),
            pageVersionID: PageVersionID(rawValue: "01VERSION0000000000000000000"),
            pageID: PageID(rawValue: "01BLOCKERPAGE00000000000000"))
    }

    // MARK: - Page coordinator routes every impact state (AC.9)

    @Test func pageDeletionCoordinatorRoutesEveryImpactState() {
        let sink = DecisionSink()
        let linkingPage = PageID(rawValue: "01LINKINGPAGE0000000000000")

        // 1. No inbound references: delete immediately, no dialog.
        let immediate = makeCoordinator(kind: .page, impacts: [impact()], sink: sink).evaluate()
        #expect(immediate == .deleteImmediately)

        // 2. Inbound links: confirm with Unlink and Delete / Delete / Cancel.
        let withLinks = makeCoordinator(
            kind: .page, impacts: [impact(linking: [linkingPage], linkEdges: 2)], sink: sink).evaluate()
        guard case .confirm(let linksPresentation) = withLinks else {
            Issue.record("expected .confirm for inbound links")
            return
        }
        #expect(linksPresentation.offersUnlink)
        #expect(linksPresentation.actions == [.unlinkAndDelete, .delete, .cancel])
        #expect(linksPresentation.title == "Delete Page?")
        #expect(linksPresentation.message.contains("Linked from 1 page"))

        // 3. Bookmarks only: explain mandatory removal, Delete / Cancel.
        let bookmarksOnly = makeCoordinator(
            kind: .page, impacts: [impact(bookmarkCount: 2)], sink: sink).evaluate()
        guard case .confirm(let bmPresentation) = bookmarksOnly else {
            Issue.record("expected .confirm for bookmarks only")
            return
        }
        #expect(!bmPresentation.offersUnlink)
        #expect(bmPresentation.actions == [.delete, .cancel])
        #expect(bmPresentation.message.contains("2 bookmarks"))
        #expect(bmPresentation.message.contains("will be removed"))

        // 4. Provenance blocker: blocked with clickable blocking pages.
        let blockedPage = blocker().pageID
        let withResolver = DeletionConfirmationCoordinator(
            kind: .page,
            loadImpacts: { [impact(blockers: [blocker()])] },
            onDelete: { sink.record($0) },
            pageTitle: { _ in "Claim" },
            selectionCount: 1)
        guard case .blocked(let blockedPresentation) = withResolver.evaluate() else {
            Issue.record("expected .blocked for provenance blockers")
            return
        }
        #expect(blockedPresentation.title == "Source Is In Use")
        #expect(blockedPresentation.intro.contains("Remove those references"))
        // The blocking page resolves to a clickable entry.
        #expect(blockedPresentation.blockingPages == [
            DeletionLinkingPage(pageID: blockedPage, title: "Claim"),
        ])
        // The outcome exposes the same pages for the dialog's Open actions,
        // and still offers NO destructive actions in the blocked state.
        let blockedOutcome = withResolver.evaluate()
        if case .blocked = blockedOutcome {
            #expect(blockedOutcome.blockingPages.count == 1)
            #expect(blockedOutcome.availableActions.isEmpty)
        }

        // 5. Loader throws: failed, and NO decision recorded for any route.
        let failing = DeletionConfirmationCoordinator(
            kind: .page,
            loadImpacts: { throw StubError.bang },
            onDelete: { sink.record($0) },
            selectionCount: 1)
        guard case .failed = failing.evaluate() else {
            Issue.record("expected .failed for a throwing loader")
            return
        }
        // None of the routed states above invoked deletion by themselves.
        #expect(sink.count == 0)
    }

    // MARK: - Source coordinator routes every impact state (AC.9)

    @Test func sourceDeletionCoordinatorRoutesEveryImpactState() {
        let sink = DecisionSink()
        let citingPage = PageID(rawValue: "01CITINGPAGE0000000000000")

        // Citations wording differs; the action set does not.
        let withCitations = makeCoordinator(
            kind: .source, impacts: [impact(linking: [citingPage], linkEdges: 1)], sink: sink).evaluate()
        guard case .confirm(let presentation) = withCitations else {
            Issue.record("expected .confirm for citations")
            return
        }
        #expect(presentation.title == "Delete Source?")
        #expect(presentation.message.contains("Cited by 1 page"))
        #expect(presentation.actions == [.unlinkAndDelete, .delete, .cancel])

        // Blockers on a source → blocked with the named page.
        let blocked = makeCoordinator(
            kind: .source,
            impacts: [impact(blockers: [blocker()])],
            sink: sink).evaluate()
        guard case .blocked(let blockedPresentation) = blocked else {
            Issue.record("expected .blocked")
            return
        }
        #expect(blockedPresentation.title == "Source Is In Use")
        #expect(blockedPresentation.intro.contains("page versions"))
        // Without a title resolver the blocking page cannot be opened, so it
        // does not become a clickable entry (the intro still explains why).
        #expect(blockedPresentation.blockingPages.isEmpty)

        // Immediate when nothing references the source.
        #expect(makeCoordinator(kind: .source, impacts: [impact()], sink: sink).evaluate()
            == .deleteImmediately)
        #expect(sink.count == 0)
    }

    // MARK: - Typed decision mapping (AC.9)

    @Test func coordinatorMapsDialogActionsToTypedDecisions() {
        let sink = DecisionSink()
        let coordinator = makeCoordinator(
            kind: .page, impacts: [impact(linking: [pageID])], sink: sink)

        coordinator.perform(.unlinkAndDelete)
        coordinator.perform(.delete)
        coordinator.perform(.cancel)

        #expect(sink.all == [.unlink, .preserve])
        // Exactly two deletions — cancel never invokes the sink.
        #expect(sink.count == 2)
    }

    // MARK: - Batch presentation (AC.9: distinct pages, totals, paths)

    @Test func batchCoordinatorAggregatesDistinctReferences() {
        let sink = DecisionSink()
        let p1 = PageID(rawValue: "01LINKINGPAGE0000000000000")
        let p2 = PageID(rawValue: "01OTHERLINKER00000000000000")
        // Two sources, each cited by both pages, each with one bookmark in
        // the SAME folder: the dialog must show distinct pages, total
        // bookmarks, and distinct folder paths.
        let impacts = [
            impact(linking: [p1, p2], bookmarkCount: 2, linkEdges: 2),
            impact(linking: [p1, p2], bookmarkCount: 2, bookmarkSeed: 2, linkEdges: 2),
        ]
        let coordinator = DeletionConfirmationCoordinator(
            kind: .source,
            loadImpacts: { impacts },
            onDelete: { sink.record($0) },
            selectionCount: 2)

        guard case .confirm(let presentation) = coordinator.evaluate() else {
            Issue.record("expected .confirm")
            return
        }
        // Distinct linking pages appear once each.
        #expect(presentation.message.contains("Cited by 2 pages"))
        // Total bookmark count across the batch (2 + 2 distinct nodes).
        #expect(presentation.message.contains("4 bookmarks"))
        // Distinct folder paths only, sorted.
        #expect(presentation.message.contains("Bookmarks, Research"))
        #expect(!presentation.message.contains("Bookmarks, Research, Bookmarks"))
    }

    // MARK: - Impact-read failure can never delete (AC.10)

    private enum StubError: Error { case bang }

    @Test func impactReadFailureBlocksPageDeletion() {
        let sink = DecisionSink()
        let coordinator = DeletionConfirmationCoordinator(
            kind: .page,
            loadImpacts: { throw StubError.bang },
            onDelete: { sink.record($0) },
            selectionCount: 1)

        let outcome = coordinator.evaluate()
        guard case .failed(let presentation) = outcome else {
            Issue.record("expected .failed")
            return
        }
        #expect(presentation.title == "Couldn't Delete Page")
        #expect(!presentation.message.isEmpty)
        // No dialog surface offers deletion in the failed state.
        #expect(!outcome.dialogMessage.contains("Delete"))
        #expect(sink.count == 0)
    }

    @Test func impactReadFailureBlocksSourceDeletion() {
        let sink = DecisionSink()
        let coordinator = DeletionConfirmationCoordinator(
            kind: .source,
            loadImpacts: { throw StubError.bang },
            onDelete: { sink.record($0) },
            selectionCount: 1)

        guard case .failed(let presentation) = coordinator.evaluate() else {
            Issue.record("expected .failed")
            return
        }
        #expect(presentation.title == "Couldn't Delete Source")
        #expect(sink.count == 0)
    }

    @Test func failedCoordinatorStateNeverInvokesDeletion() {
        let sink = DecisionSink()
        let failing = DeletionConfirmationCoordinator(
            kind: .page,
            loadImpacts: { throw StubError.bang },
            onDelete: { sink.record($0) },
            selectionCount: 1)

        let outcome = failing.evaluate()
        guard case .failed = outcome else {
            Issue.record("expected .failed")
            return
        }
        // The failed state exposes NO dialog actions at all, so no user
        // action can route a deletion through it — and evaluate() itself
        // invoked the sink zero times.
        #expect(outcome.availableActions.isEmpty)
        #expect(sink.count == 0)
    }

    // MARK: - Container wiring contract (AC.9)

    /// Both containers must route deletion through the shared coordinator and
    /// its dialog surface — no per-view duplicate confirmation flows.
    @Test func pagesAndSourcesContainersUseDeletionCoordinator() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

        for relativePath in [
            "Sources/WikiFS/Pages/PagesContainerView.swift",
            "Sources/WikiFS/Sources/SourcesContainerView.swift",
        ] {
            let source = try String(
                contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            #expect(
                source.contains("DeletionConfirmationCoordinator("),
                "\(relativePath) must construct the shared coordinator")
            #expect(
                source.contains(".deletionOutcomeDialog"),
                "\(relativePath) must render the shared dialog surface")
            #expect(
                !source.contains("PendingPageDeletion") && !source.contains("PendingSourceDeletion"),
                "\(relativePath) must not carry a per-view pending-deletion struct")
            #expect(
                !source.contains("unlinkIncomingLinksTo") && !source.contains("removeBookmarksReferencing"),
                "\(relativePath) must not orchestrate store cleanup itself")
        }
    }
}
#endif
