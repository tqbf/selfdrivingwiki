import Foundation
import Testing
@testable import WikiFSCore

/// Tests for the Phase C edit-lock state machine (`EditLock`) and the
/// `WikiStoreModel` agent-run lock hooks. Decision #6: lock-on-start /
/// unlock-on-terminate, PER-WIKI, autosave paused while locked.
@MainActor
struct EditLockTests {

    // MARK: - EditLock state machine

    @Test func startsUnlocked() {
        let lock = EditLock()
        #expect(!lock.isLocked(wikiID: "A"))
    }

    @Test func locksOnStartUnlocksOnTerminate() {
        let lock = EditLock()
        lock.lock(wikiID: "A")
        #expect(lock.isLocked(wikiID: "A"))
        lock.unlock(wikiID: "A")
        #expect(!lock.isLocked(wikiID: "A"))
    }

    @Test func lockIsPerWiki() {
        let lock = EditLock()
        lock.lock(wikiID: "A")
        // Locking A must not freeze B.
        #expect(lock.isLocked(wikiID: "A"))
        #expect(!lock.isLocked(wikiID: "B"))
        lock.lock(wikiID: "B")
        lock.unlock(wikiID: "A")
        // Unlocking A leaves B locked.
        #expect(!lock.isLocked(wikiID: "A"))
        #expect(lock.isLocked(wikiID: "B"))
    }

    @Test func reentrantLockStaysLockedUntilLastUnlock() {
        let lock = EditLock()
        lock.lock(wikiID: "A")
        lock.lock(wikiID: "A")
        lock.unlock(wikiID: "A")
        // One op still running — must stay locked.
        #expect(lock.isLocked(wikiID: "A"))
        lock.unlock(wikiID: "A")
        #expect(!lock.isLocked(wikiID: "A"))
    }

    @Test func strayUnlockIsClampedAtZero() {
        let lock = EditLock()
        lock.unlock(wikiID: "A")  // never locked
        #expect(!lock.isLocked(wikiID: "A"))
        // A subsequent lock/unlock pair still behaves correctly.
        lock.lock(wikiID: "A")
        #expect(lock.isLocked(wikiID: "A"))
        lock.unlock(wikiID: "A")
        #expect(!lock.isLocked(wikiID: "A"))
    }

    // MARK: - WikiStoreModel agent-run lock

    private func makeModel() throws -> WikiStoreModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-editlock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try SQLiteWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
        return WikiStoreModel(store: store)
    }

    @Test func beginAgentRunSetsRunningEndClearsIt() throws {
        let model = try makeModel()
        #expect(!model.isAgentRunning)
        model.beginAgentRun()
        #expect(model.isAgentRunning)
        model.endAgentRun()
        #expect(!model.isAgentRunning)
    }

    @Test func autosaveDoesNotPersistDraftEditsMadeWhileLocked() async throws {
        let model = try makeModel()
        model.newPage(title: "Page")
        let id = model.summaries.first!.id
        model.select(.page(id))

        model.beginAgentRun()
        // Edit the draft + trigger autosave — the scheduler is paused while locked,
        // so it never fires. Give a real autosave debounce more than enough time.
        model.draftBody = "edited while agent running"
        model.bodyChanged()
        try await Task.sleep(for: .milliseconds(700))

        // Ending the run reloads the draft from the (unchanged) store: the edit is
        // discarded, proving the in-app autosave never clobbered the store.
        model.endAgentRun()
        model.select(nil)
        model.select(.page(id))
        #expect(model.draftBody != "edited while agent running")
    }

    @Test func endAgentRunRebuildsSidebarFromStore() throws {
        let model = try makeModel()
        model.newPage(title: "Home")
        model.beginAgentRun()
        // endAgentRun does a full from-source rebuild (so pages the agent's wikictl
        // calls wrote show up) and clears the flag.
        model.endAgentRun()
        #expect(!model.isAgentRunning)
        #expect(model.summaries.contains { $0.title == "Home" })
    }
}
