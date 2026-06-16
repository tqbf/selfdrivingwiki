import Foundation
import Observation

/// Tracks which wikis currently have a `claude -p` operation running, so the app
/// can make THAT wiki's in-app editor read-only and pause its autosave while the
/// agent writes via `wikictl` (`plans/llm-wiki.md` Phase C / decision #6 — prevent
/// the last-writer-wins clobber between in-app autosave and the agent's writes).
///
/// **Per-wiki** (decision: "locking one wiki's editor doesn't freeze others"):
/// the lock is keyed by wiki ULID, so an Ingest running on wiki A leaves wiki B's
/// editor fully editable. **State machine:** `lock(wikiID:)` on operation start,
/// `unlock(wikiID:)` from the spawn's `terminationHandler` — so a crashed or
/// killed agent still releases the lock. Idempotent both ways (a redundant
/// lock/unlock is a no-op), and re-entrant via a count so two ops on the same
/// wiki don't unlock each other prematurely.
///
/// `@MainActor @Observable` and UI-framework-agnostic (uses `Observation`, not
/// SwiftUI), exactly like `WikiStoreModel`, so the state machine is unit-tested
/// directly.
@MainActor
@Observable
public final class EditLock {
    /// Per-wiki count of in-flight operations. A wiki is locked iff its count > 0.
    /// A count (not a Bool) keeps the lock correct if two operations ever overlap
    /// on one wiki — the editor stays locked until the LAST one terminates.
    private var runningCounts: [String: Int] = [:]

    public init() {}

    /// True while an operation is running for `wikiID` (its editor should be
    /// read-only and its autosave paused). False for any wiki with no in-flight op.
    public func isLocked(wikiID: String) -> Bool {
        (runningCounts[wikiID] ?? 0) > 0
    }

    /// Mark an operation as started for `wikiID` (call on spawn).
    public func lock(wikiID: String) {
        runningCounts[wikiID, default: 0] += 1
    }

    /// Mark an operation as finished for `wikiID` (call from `terminationHandler`).
    /// Clamped at zero so a stray unlock can't drive the count negative.
    public func unlock(wikiID: String) {
        guard let count = runningCounts[wikiID], count > 0 else { return }
        if count == 1 {
            runningCounts[wikiID] = nil
        } else {
            runningCounts[wikiID] = count - 1
        }
    }
}
