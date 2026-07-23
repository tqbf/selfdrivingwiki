#if os(macOS)
import Testing
@testable import WikiFS

/// Pins the Ingest button's disabled predicate (#867).
///
/// After the Phase C4 flip, ingest (and lint) are enqueued to the daemon
/// queue — the session's local `agentLauncher` is no longer on either path.
/// The button therefore must NOT consult `launcher.isRunning`: that flag is
/// disconnected from ingest/lint state, and a stale/stuck value permanently
/// wedged the button. The queue engine serializes runs and
/// `enqueueIngestion` dedupes an already-active source, so the launcher flag
/// is not part of the decision at all.
///
/// These tests exercise the pure `SourceDetailView.ingestButtonDisabled(...)`
/// seam directly. The decisive regression assertion is that there is NO
/// `isRunning` input to the function — a stuck launcher flag cannot reach it.
@Suite struct IngestButtonDisabledTests {

    @Test("Normal ingestible source — button enabled")
    func enabledWhenIngestibleAndUnlocked() {
        #expect(!SourceDetailView.ingestButtonDisabled(
            isEditLockedExternally: false, canIngest: true))
    }

    @Test("Byteless source with no markdown — disabled (!canIngest)")
    func disabledWhenNotIngestible() {
        #expect(SourceDetailView.ingestButtonDisabled(
            isEditLockedExternally: false, canIngest: false))
    }

    @Test("Edit lock held by another agent — disabled")
    func disabledWhenEditLockedExternally() {
        // canIngest is true here — the lock is the sole reason.
        #expect(SourceDetailView.ingestButtonDisabled(
            isEditLockedExternally: true, canIngest: true))
    }

    @Test("Lock + not ingestible — disabled (both gates agree)")
    func disabledWhenBothGatesTrip() {
        #expect(SourceDetailView.ingestButtonDisabled(
            isEditLockedExternally: true, canIngest: false))
    }

    // MARK: - #867 regression: no launcher isRunning dependency

    @Test("#867: a stuck launcher isRunning flag cannot disable the button")
    func launcherIsRunningIsNotPartOfTheDecision() {
        // The fix for #867 is structural: `ingestButtonDisabled` takes NO
        // launcher/lint/process-state parameter. After Phase C4, ingest is
        // daemon-queued, so `launcher.isRunning` is disconnected from
        // ingest/lint. This assertion pins that contract — a stuck launcher
        // flag has no path into the predicate, so an ingestible, unlocked
        // source stays enabled regardless of any launcher state.
        #expect(!SourceDetailView.ingestButtonDisabled(
            isEditLockedExternally: false, canIngest: true))
    }
}
#endif
