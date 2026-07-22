import Foundation
import Testing
@testable import WikiFSCore

/// Unit tests for the centralized `WorkspaceStatus` FSM
/// (`GRDBWikiStore.transitionWorkspace` — the single write seam for the
/// `workspaces.status` column; see `plans/workspace-status-fsm.md`).
///
/// Covers:
/// - **AC.1** — `WorkspaceStatus.allowedTargets` matches the FSM spec for all
///   5 states (pure; terminal states are terminal).
/// - **AC.2** — `transitionWorkspace` throws `.invalidStateTransition` on
///   illegal moves, driven through the public API (so the reachable-status
///   reality at each call site is exercised, not just the spec).
/// - **AC.6** — every legal transition reachable from the public API, and a
///   representative set of illegal ones (`merged→merging`, `abandoned→abandoned`,
///   `merged→abandoned`, `open→open` via retry on a non-conflicted workspace).
@MainActor
@Suite(.timeLimit(.minutes(5)))
struct WorkspaceTransitionTests {

    private func tempStore() throws -> GRDBWikiStore {
        try TestStoreFactory.inMemory()
    }

    // MARK: - AC.1: the spec (pure)

    @Test func allowedTargetsMatchesFSMSpec() {
        #expect(WorkspaceStatus.open.allowedTargets == [.merging, .abandoned])
        #expect(WorkspaceStatus.merging.allowedTargets == [.merged, .conflicted, .abandoned])
        #expect(WorkspaceStatus.merged.allowedTargets == [])
        #expect(WorkspaceStatus.conflicted.allowedTargets == [.open, .abandoned])
        #expect(WorkspaceStatus.abandoned.allowedTargets == [])
    }

    @Test func mergedAndAbandonedAreTerminal() {
        #expect(WorkspaceStatus.merged.allowedTargets.isEmpty)
        #expect(WorkspaceStatus.abandoned.allowedTargets.isEmpty)
    }

    /// Every state except the initial `.open` must appear as *some* state's
    /// allowed target — otherwise it would be unreachable, a spec bug.
    @Test func everyNonInitialStateIsReachable() {
        let all = Set(WorkspaceStatus.allCases)
        let reachable = Set(WorkspaceStatus.allCases.flatMap { $0.allowedTargets })
        #expect(reachable.isSuperset(of: all.subtracting([.open])))
        // The initial state itself is reached only by INSERT (createWorkspace),
        // never by a transition, so it need not be any target.
    }

    // MARK: - AC.6: legal transitions via the public API

    /// `open` → `merging` → `merged` (fast-forward merge: ws change alone on main).
    @Test func legal_open_toMerging_toMerged() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "FF Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "FF Page", body: "v1",
            expectedHeadVersionID: nil)

        let wsID = try store.createWorkspace(name: nil, activityID: nil)
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: page.id, title: "FF Page", body: "ws body")

        _ = try store.workspaceMerge(workspaceID: wsID)
        #expect(try store.workspaceSummary(id: wsID)?.status == .merged)
    }

    /// `open` → (`merging` rolled back) → `conflicted` (merge parks on a conflict).
    /// Exercises the catch-block write site whose `allowedFrom` is `[.open]`
    /// (NOT `.merging`) because `mutate()`'s savepoint rolled the step-1 write back.
    @Test func legal_open_toConflicted_parkOnConflict() throws {
        let store = try tempStore()
        let wsID = try readyConflictedWorkspace(store: store)
        #expect(try store.workspaceSummary(id: wsID)?.status == .conflicted)
    }

    /// `conflicted` → `open` → `merging` → `merged` (resolve + retry).
    /// Exercises the `.conflicted` → `.open` write site in `workspaceRetryMerge`.
    @Test func legal_conflicted_toOpen_toMerged_viaRetry() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Retry Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Retry Page", body: "line1\nline2",
            expectedHeadVersionID: nil)

        let wsID = try store.createWorkspace(name: nil, activityID: nil)
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: page.id, title: "Retry Page",
            body: "line1\nws-line2")

        let mainHead = try store.pageHeadVersionID(pageID: page.id)
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Retry Page",
            body: "line1\nmain-line2", expectedHeadVersionID: mainHead)

        _ = try store.workspaceMerge(workspaceID: wsID)
        #expect(try store.workspaceSummary(id: wsID)?.status == .conflicted)

        try store.workspaceResolveConflict(
            workspaceID: wsID, pageID: page.id,
            body: "line1\nmain-line2\nws-line2")

        try store.workspaceRetryMerge(workspaceID: wsID)
        #expect(try store.workspaceSummary(id: wsID)?.status == .merged)
    }

    /// `open` → `abandoned` (give up on an open workspace).
    @Test func legal_open_toAbandoned() throws {
        let store = try tempStore()
        let wsID = try store.createWorkspace(name: nil, activityID: nil)
        try store.abandonWorkspace(id: wsID)
        #expect(try store.workspaceSummary(id: wsID)?.status == .abandoned)
        #expect(try store.workspaceRefs(workspaceID: wsID).isEmpty)
    }

    /// `conflicted` → `abandoned` (give up on a parked workspace).
    @Test func legal_conflicted_toAbandoned() throws {
        let store = try tempStore()
        let wsID = try readyConflictedWorkspace(store: store)
        #expect(try store.workspaceSummary(id: wsID)?.status == .conflicted)
        try store.abandonWorkspace(id: wsID)
        #expect(try store.workspaceSummary(id: wsID)?.status == .abandoned)
    }

    // MARK: - AC.2: illegal transitions throw `.invalidStateTransition`

    /// `merged` → `merging`: re-merging an already-merged workspace is illegal.
    @Test func illegal_merged_toMerging() throws {
        let store = try tempStore()
        let wsID = try readyMergedWorkspace(store: store)
        try assertInvalidTransition(from: .merged, to: .merging) {
            _ = try store.workspaceMerge(workspaceID: wsID)
        }
        // State must be unchanged after a rejected transition.
        #expect(try store.workspaceSummary(id: wsID)?.status == .merged)
    }

    /// `abandoned` → `abandoned`: abandoning an already-abandoned workspace.
    @Test func illegal_abandoned_toAbandoned() throws {
        let store = try tempStore()
        let wsID = try store.createWorkspace(name: nil, activityID: nil)
        try store.abandonWorkspace(id: wsID)
        try assertInvalidTransition(from: .abandoned, to: .abandoned) {
            try store.abandonWorkspace(id: wsID)
        }
        #expect(try store.workspaceSummary(id: wsID)?.status == .abandoned)
    }

    /// `merged` → `abandoned`: a terminal-success workspace cannot be abandoned.
    @Test func illegal_merged_toAbandoned() throws {
        let store = try tempStore()
        let wsID = try readyMergedWorkspace(store: store)
        try assertInvalidTransition(from: .merged, to: .abandoned) {
            try store.abandonWorkspace(id: wsID)
        }
        #expect(try store.workspaceSummary(id: wsID)?.status == .merged)
    }

    /// `open` → `open` via `workspaceRetryMerge`: retry is only legal from
    /// `.conflicted`. On a fresh open workspace the validator rejects it.
    @Test func illegal_open_toOpen_viaRetry() throws {
        let store = try tempStore()
        let wsID = try store.createWorkspace(name: nil, activityID: nil)
        try assertInvalidTransition(from: .open, to: .open) {
            try store.workspaceRetryMerge(workspaceID: wsID)
        }
        #expect(try store.workspaceSummary(id: wsID)?.status == .open)
    }

    // MARK: - Helpers

    /// A workspace parked at `.conflicted` (conflict-merge setup, no resolve).
    private func readyConflictedWorkspace(store: GRDBWikiStore) throws -> String {
        let page = try store.createPage(title: "Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Page", body: "line1\nline2",
            expectedHeadVersionID: nil)
        let wsID = try store.createWorkspace(name: nil, activityID: nil)
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: page.id, title: "Page",
            body: "line1\nws-line2")
        let mainHead = try store.pageHeadVersionID(pageID: page.id)
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Page",
            body: "line1\nmain-line2", expectedHeadVersionID: mainHead)
        _ = try store.workspaceMerge(workspaceID: wsID)
        return wsID
    }

    /// A workspace at `.merged` (fast-forward merge completes cleanly).
    private func readyMergedWorkspace(store: GRDBWikiStore) throws -> String {
        let page = try store.createPage(title: "Merged Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Merged Page", body: "v1",
            expectedHeadVersionID: nil)
        let wsID = try store.createWorkspace(name: nil, activityID: nil)
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: page.id, title: "Merged Page", body: "ws body")
        _ = try store.workspaceMerge(workspaceID: wsID)
        return wsID
    }

    /// Assert `action` throws `WorkspaceError.invalidStateTransition` with the
    /// given `from`/`to`. Runs `action` exactly once.
    private func assertInvalidTransition(
        from: WorkspaceStatus, to: WorkspaceStatus,
        _ action: () throws -> Void
    ) throws {
        do {
            try action()
            Issue.record("expected WorkspaceError.invalidStateTransition(\(from) → \(to))")
        } catch let err as WorkspaceError {
            #expect(
                err == .invalidStateTransition(from: from, to: to),
                "got \(err)"
            )
        } catch {
            Issue.record("expected WorkspaceError, got \(type(of: error)): \(error)")
        }
    }
}
