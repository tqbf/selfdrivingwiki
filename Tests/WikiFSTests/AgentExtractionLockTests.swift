import Foundation
import Testing
@testable import WikiFS
import WikiFSCore

/// Tests for the SEPARATE extraction lock on `AgentLauncher` (option B): two
/// pdf2md conversions never overlap; a cancelled extraction waiter self-removes;
/// `releaseExtractionSlot` wakes the next live waiter FIFO. Critically, the
/// extraction lock is INDEPENDENT of the claude spawn slot — holding one never
/// blocks the other — and of the edit lock. Also covers the two-flag phase
/// split (`extractingFileIDs` vs `ingestingFileIDs`) and the row's
/// Extracting-vs-Ingesting label predicate.
///
/// These exercise the slot seams (`awaitExtractionSlot` / `releaseExtractionSlot`
/// / `extractionSlotWaiterCount` / `isExtractionSlotBusy` and the spawn-slot
/// siblings) directly, without spawning a real process — fast and deterministic.
@MainActor
struct AgentExtractionLockTests {

    private func makeLauncher() -> AgentLauncher {
        // Stub the PATH preflight so `run` (if ever used here) never touches the
        // login shell.
        let launcher = AgentLauncher()
        launcher.resolveClaude = { .found(path: "/usr/bin/true") }
        return launcher
    }

    // MARK: - Slot serialization

    @Test func extractionFastPathAcquiresWithoutSuspending() async {
        let launcher = makeLauncher()
        #expect(!launcher.isExtractionSlotBusy)
        #expect(!launcher.isRunning)
        let acquired = await launcher.awaitExtractionSlot()
        #expect(acquired)
        #expect(launcher.isExtractionSlotBusy)
        // Acquiring the extraction slot does NOT touch the spawn slot.
        #expect(!launcher.isRunning)
        #expect(launcher.extractionSlotWaiterCount == 0)
        launcher.releaseExtractionSlot()
        #expect(!launcher.isExtractionSlotBusy)
    }

    @Test func secondExtractionWaitsUntilFirstReleases() async {
        let launcher = makeLauncher()
        let first = await launcher.awaitExtractionSlot()
        #expect(first)
        #expect(launcher.isExtractionSlotBusy)

        // Second must suspend behind the first.
        let secondTask = Task { await launcher.awaitExtractionSlot() }
        await Task.yield()
        await Task.yield()
        #expect(launcher.extractionSlotWaiterCount == 1)
        #expect(launcher.isExtractionSlotBusy)

        // Releasing hands the slot to the waiter; isExtractionSlotBusy stays true
        // (atomic handoff) and the waiter reports it acquired the slot.
        launcher.releaseExtractionSlot()
        let secondAcquired = await secondTask.value
        #expect(secondAcquired)
        #expect(launcher.isExtractionSlotBusy)
        #expect(launcher.extractionSlotWaiterCount == 0)

        launcher.releaseExtractionSlot()
        #expect(!launcher.isExtractionSlotBusy)
    }

    // MARK: - Cancelled waiter self-removes

    @Test func cancelledExtractionWaiterSelfRemovesAndDoesNotStealSlot() async {
        let launcher = makeLauncher()
        let first = await launcher.awaitExtractionSlot()
        #expect(first)

        // A waiter that gets cancelled while queued must self-remove and return
        // false (it never acquired the slot).
        let waiterTask = Task<Void, Never> {
            _ = await launcher.awaitExtractionSlot()
        }
        await Task.yield()
        await Task.yield()
        #expect(launcher.extractionSlotWaiterCount == 1)

        waiterTask.cancel()
        await waiterTask.value
        #expect(launcher.extractionSlotWaiterCount == 0)

        // The slot is still held by the first; releasing frees it (no stale
        // handoff to the dead task).
        launcher.releaseExtractionSlot()
        #expect(!launcher.isExtractionSlotBusy)
    }

    @Test func releaseExtractionWakesNextLiveWaiterAfterACancelledOne() async {
        let launcher = makeLauncher()
        _ = await launcher.awaitExtractionSlot()

        // Enqueue a waiter that will be cancelled, then a live waiter behind it.
        let doomed = Task<Void, Never> { _ = await launcher.awaitExtractionSlot() }
        await Task.yield()
        await Task.yield()
        let live = Task { await launcher.awaitExtractionSlot() }
        await Task.yield()
        await Task.yield()
        #expect(launcher.extractionSlotWaiterCount == 2)

        doomed.cancel()
        await doomed.value
        // The cancelled one is gone; the live one is still queued.
        #expect(launcher.extractionSlotWaiterCount == 1)

        // Releasing must hand the slot to the LIVE waiter, skipping the dead one.
        launcher.releaseExtractionSlot()
        let liveAcquired = await live.value
        #expect(liveAcquired)
        #expect(launcher.isExtractionSlotBusy)
        launcher.releaseExtractionSlot()
    }

    // MARK: - Independence from the spawn slot (the key invariant)

    /// While the extraction slot is held, `awaitSpawnSlot()` for a query still
    /// returns `true` immediately (does not wait) — holding the extraction lock
    /// does NOT block the spawn slot. Assert via the test seams.
    @Test func extractionSlotHeldDoesNotBlockSpawnSlot() async {
        let launcher = makeLauncher()
        // Hold the extraction slot (simulating a pdf2md conversion in flight).
        let extractionAcquired = await launcher.awaitExtractionSlot()
        #expect(extractionAcquired)
        #expect(launcher.isExtractionSlotBusy)
        #expect(!launcher.isRunning)

        // A claude query run starts during the extraction. It takes the spawn
        // slot immediately — no waiting on the extraction slot.
        let spawnAcquired = await launcher.awaitSpawnSlot()
        #expect(spawnAcquired)
        #expect(launcher.isRunning)
        // The extraction slot is still held by the conversion; the two locks are
        // fully independent.
        #expect(launcher.isExtractionSlotBusy)
        #expect(launcher.spawnSlotWaiterCount == 0)
        #expect(launcher.extractionSlotWaiterCount == 0)

        // Teardown: release both, in either order.
        launcher.releaseSpawnSlot()
        launcher.releaseExtractionSlot()
        #expect(!launcher.isRunning)
        #expect(!launcher.isExtractionSlotBusy)
    }

    /// Independence the other way: holding the spawn slot does not block
    /// `awaitExtractionSlot()`.
    @Test func spawnSlotHeldDoesNotBlockExtractionSlot() async {
        let launcher = makeLauncher()
        _ = await launcher.awaitSpawnSlot()
        #expect(launcher.isRunning)
        #expect(!launcher.isExtractionSlotBusy)

        // An extraction starts while a claude run holds the spawn slot. It takes
        // the extraction slot immediately — no waiting on the spawn slot.
        let extractionAcquired = await launcher.awaitExtractionSlot()
        #expect(extractionAcquired)
        #expect(launcher.isExtractionSlotBusy)
        #expect(launcher.isRunning)
        #expect(launcher.spawnSlotWaiterCount == 0)
        #expect(launcher.extractionSlotWaiterCount == 0)

        launcher.releaseExtractionSlot()
        launcher.releaseSpawnSlot()
        #expect(!launcher.isExtractionSlotBusy)
        #expect(!launcher.isRunning)
    }

    // MARK: - Phase flags: extraction phase vs agent phase

    /// The extraction phase sets `extractingFileIDs` (NOT `ingestingFileIDs`),
    /// and `ingestingFileIDs` stays empty until the agent spawn commits. Driven
    /// via the slot seams + direct flag assignment mirroring what
    /// `runMultiIngest` does around the pdf2md block (acquire slot → insert id →
    /// release slot), without running a real pdf2md. Asserts the overload fix:
    /// a pure extraction no longer populates the agent-phase flag.
    @Test func extractionPhaseSetsExtractingFileIDsNotIngestingFileIDs() async {
        let launcher = makeLauncher()
        let id = PageID(rawValue: "01EXTRACTIONPHASE00")

        // Extraction phase: acquire the extraction slot and record the file.
        let acquired = await launcher.awaitExtractionSlot()
        #expect(acquired)
        launcher.extractingFileIDs.insert(id)
        #expect(launcher.extractingFileIDs.contains(id))
        // The agent-phase flag is NOT set during extraction — this is the bug fix.
        #expect(launcher.ingestingFileIDs.isEmpty)
        // The cross-file Ingest greyout (driven off `ingestingFileIDs`) is OFF.
        #expect(!launcher.ingestingFileIDs.contains(id))
        // The extraction lock does not touch the spawn slot or edit lock.
        #expect(!launcher.isRunning)

        // Extraction ends: clear the extraction-phase flag + release the slot.
        launcher.extractingFileIDs.remove(id)
        launcher.releaseExtractionSlot()
        #expect(launcher.extractingFileIDs.isEmpty)
        #expect(launcher.ingestingFileIDs.isEmpty)
        #expect(!launcher.isExtractionSlotBusy)
    }

    /// The agent phase sets `ingestingFileIDs` only at spawn commit (i.e. once
    /// the spawn slot is acquired), and the cross-file Ingest greyout activates
    /// only then. Acquire the spawn slot (simulating spawn commit) and assign the
    /// agent-phase flag, mirroring what `AgentLauncher.run` does around `onLock`.
    @Test func agentPhaseSetsIngestingFileIDsOnlyAtSpawnCommit() async {
        let launcher = makeLauncher()
        let idA = PageID(rawValue: "01AGENTPHASEA00000")
        let idB = PageID(rawValue: "01AGENTPHASEB00000")

        // Before spawn commit: neither phase flag set (no extraction running).
        #expect(launcher.extractingFileIDs.isEmpty)
        #expect(launcher.ingestingFileIDs.isEmpty)

        // Spawn commit: acquire the spawn slot, then assign the agent-phase flag.
        let acquired = await launcher.awaitSpawnSlot()
        #expect(acquired)
        launcher.ingestingFileIDs = [idA, idB]
        #expect(launcher.ingestingFileIDs.contains(idA))
        // The extraction-phase flag is NOT set by the agent phase.
        #expect(launcher.extractingFileIDs.isEmpty)
        // The cross-file Ingest greyout is now active for any other file.
        #expect(!launcher.ingestingFileIDs.isEmpty)

        // finish() clears the agent-phase flag and releases the spawn slot.
        // Simulate via the public seam: clear + release (finish is private).
        launcher.ingestingFileIDs = []
        launcher.releaseSpawnSlot()
        #expect(launcher.ingestingFileIDs.isEmpty)
        #expect(!launcher.isRunning)
    }

    /// While file A is in the EXTRACTION phase, file B's Ingest is not greyed
    /// out (the cross-file greyout keys off `ingestingFileIDs`, not
    /// `extractingFileIDs`), and B may start its own extraction (serialized on
    /// the extraction slot). This is the core user-facing invariant.
    @Test func pureExtractionDoesNotGreyOutPeerIngest() async {
        let launcher = makeLauncher()
        let idA = PageID(rawValue: "01PEEREXTRACTIONA0")
        let idB = PageID(rawValue: "01PEEREXTRACTIONB0")

        // A is mid-extraction.
        _ = await launcher.awaitExtractionSlot()
        launcher.extractingFileIDs.insert(idA)

        // The cross-file Ingest greyout predicate is `!ingestingFileIDs.isEmpty`
        // (see WikiDetailView.isAnyFileIngesting). During A's extraction it is OFF.
        let isAnyFileIngesting = !launcher.ingestingFileIDs.isEmpty
        #expect(!isAnyFileIngesting)
        // B's id is not in the extraction set, so B's row is neither extracting
        // nor ingesting — free to ingest.
        #expect(!launcher.extractingFileIDs.contains(idB))
        #expect(!launcher.ingestingFileIDs.contains(idB))

        launcher.extractingFileIDs.remove(idA)
        launcher.releaseExtractionSlot()
    }

    // MARK: - Row label predicate (Extracting… vs Ingesting…)

    /// `IngestedFileRow.rowStatus` is the pure predicate backing the row's
    /// trailing status icon. Extraction phase beats agent phase beats the idle
    /// glyphs — a pure extraction shows "Extracting…", never "Ingesting…".
    @Test func rowStatusPrecedence() {
        func s(_ e: Bool, _ i: Bool, _ ingested: Bool) -> IngestedFileRow.RowStatus {
            IngestedFileRow.rowStatus(isExtracting: e, isIngesting: i, hasBeenIngested: ingested)
        }
        // Idle states.
        #expect(s(false, false, false) == .ready)
        #expect(s(false, false, true) == .ingested)
        // Agent phase only.
        #expect(s(false, true, false) == .ingesting)
        #expect(s(false, true, true) == .ingesting)
        // Extraction phase only.
        #expect(s(true, false, false) == .extracting)
        #expect(s(true, false, true) == .extracting)
        // Extraction beats agent (a file should not be both, but if flags ever
        // overlap the extraction label wins — the more precise phase).
        #expect(s(true, true, false) == .extracting)
        #expect(s(true, true, true) == .extracting)
    }

    // MARK: - Stop cancels extractTask

    /// `stop()` must cancel a stored `extractTask` (the standalone Extract Markdown
    /// path) so the pdf2md subprocess is terminated via `PdfExtractionService`'s
    /// `onCancel` handler. Without this, the Stop button is a no-op during a
    /// standalone extraction — the bug this test guards against.
    @Test func stopCancelsExtractTask() async {
        let launcher = makeLauncher()
        let task = Task { @MainActor in
            // Sleep until cancelled — simulates a running extraction.
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
        }
        launcher.extractTask = task
        #expect(!task.isCancelled)

        launcher.stop()
        // stop() cancels extractTask. The sleep throws on cancellation; yield so
        // the cooperative cancel propagates, then wait for the task to complete.
        await Task.yield()
        await task.value
        #expect(task.isCancelled)
    }

    /// `stop()` cancels the extractTask but does NOT touch extractTask if it is nil
    /// (no standalone extraction in flight). This is a no-op guard — stop() should
    /// never crash or hang when called with no extraction running.
    @Test func stopWithNoExtractTaskIsNoOp() async {
        let launcher = makeLauncher()
        #expect(launcher.extractTask == nil)
        // Must not crash or hang.
        launcher.stop()
        #expect(launcher.extractTask == nil)
    }

    // MARK: - isExtracting flag during extraction phase

    /// `launcher.isExtracting` must be set to `true` during the extraction phase
    /// so `AgentTranscriptSidebar.showsConversion` renders the PDF Conversion box.
    /// The flag is managed by the caller (both the ingest path in
    /// `AgentOperationRunner.runMultiIngest` and the standalone path in
    /// `IngestedFileDetailView.runExtraction`), not by the slot itself — but the
    /// launcher must carry and expose it.
    @Test func isExtractingFlagExposedByLauncher() async {
        let launcher = makeLauncher()
        #expect(!launcher.isExtracting)

        // Simulate what runExtraction() does: flag on, do work, flag off.
        launcher.isExtracting = true
        #expect(launcher.isExtracting)
        launcher.isExtracting = false
        #expect(!launcher.isExtracting)
    }

    // MARK: - stopExtraction vs stopAgent separation

    /// `stopExtraction()` cancels `extractTask` (the standalone Extract Markdown
    /// path) and clears extraction-phase flags, but does NOT call `finish()`
    /// or touch `isRunning` — the agent continues unimpeded.
    @Test func stopExtractionCancelsExtractTask() async {
        let launcher = makeLauncher()
        let task = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
        }
        launcher.extractTask = task
        #expect(!task.isCancelled)

        launcher.stopExtraction()
        await Task.yield()
        await task.value
        #expect(task.isCancelled)
        // Does NOT touch the spawn slot or edit lock.
        #expect(!launcher.isRunning)
    }

    /// `stopExtraction()` clears extraction-phase UI flags so the sidebar
    /// dismisses the PDF Conversion box.
    @Test func stopExtractionClearsExtractionFlags() async {
        let launcher = makeLauncher()
        launcher.isExtracting = true
        launcher.extractionPID = 12345
        launcher.extractionLog = "converting…"
        launcher.extractingFileIDs = [PageID(rawValue: "01STOPEXTRACT00")]

        launcher.stopExtraction()
        #expect(!launcher.isExtracting)
        #expect(launcher.extractionPID == nil)
        #expect(launcher.extractionLog.isEmpty)
        #expect(launcher.extractingFileIDs.isEmpty)
    }

    /// `stopExtraction()` without a stored Task is safe — clears flags, no crash.
    @Test func stopExtractionWithNoTaskIsSafe() async {
        let launcher = makeLauncher()
        launcher.isExtracting = true
        launcher.extractingFileIDs = [PageID(rawValue: "01NOOPEXTRACT00")]

        launcher.stopExtraction()
        #expect(!launcher.isExtracting)
        #expect(launcher.extractingFileIDs.isEmpty)
    }

    /// `stopAgent()` does NOT clear extraction-phase flags — the two are
    /// independent. A standalone extraction running alongside a query continues.
    @Test func stopAgentDoesNotClearExtractionFlags() async {
        let launcher = makeLauncher()
        let extractionID = PageID(rawValue: "01EXTRACTCONTINUES")
        launcher.isExtracting = true
        launcher.extractionPID = 99999
        launcher.extractionLog = "still converting…"
        launcher.extractingFileIDs = [extractionID]

        // Simulate an agent run in progress.
        _ = await launcher.awaitSpawnSlot()
        #expect(launcher.isRunning)

        launcher.stopAgent()
        // stopAgent() calls finish() which releases the spawn slot → isRunning = false.
        #expect(!launcher.isRunning)
        // Extraction flags are untouched.
        #expect(launcher.isExtracting)
        #expect(launcher.extractionPID == 99999)
        #expect(launcher.extractionLog == "still converting…")
        #expect(launcher.extractingFileIDs.contains(extractionID))
    }
}