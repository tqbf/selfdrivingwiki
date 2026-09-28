import Foundation
import WikiFSCore

/// One-shot-per-wiki recovery capability for stranded fetch format jobs.
/// Conformances live on the app and daemon queue-extraction providers; the
/// wiki session boot and the dispatch path invoke it through this protocol,
/// never through a concrete provider type.
public protocol FetchFormatJobRecovering: Sendable {
    /// Runs at most one recovery pass per wiki per process for stranded
    /// `formatJobPending` markers (idempotent; safe from both hosts).
    func recoverStrandedFormatJobs(wikiID: WikiID, store: any WikiStore) async
}

/// The queue startup path's recovery for stranded fetch format jobs.
///
/// `attachAcquiredBytes` writes the acquired blob and the
/// `formatJobPending` marker in ONE wiki-store transaction, but the
/// follow-on enqueue is a separate queue-store write. A crash between the
/// two can strand the marker: bytes are persisted, the format job is not.
/// This scan — run by whichever host opens the wiki (app session open,
/// daemon wiki open or first dispatch) — converges each marker:
///
/// - No deduped item → enqueue the follow-on `.extraction` item with the
///   SAME typed key both hosts use, so a concurrent app/daemon race inserts
///   exactly one item.
/// - Deduped item exists and completed → settle the marker to `complete`
///   (the format job ran; the marker was written before the terminal state
///   landed, or the user retried and it succeeded).
/// - Deduped item exists queued/running → nothing; it will run.
/// - Deduped item exists failed → nothing; the existing user retry path
///   owns the terminal failed item, and settling happens after retry
///   succeeds.
///
/// A wiki neither host opens waits for its next open — documented in the
/// fetcher architecture page.
public enum FetchFormatJobRecovery {
    /// Runs one convergence pass over one opened wiki. Errors are logged,
    /// never thrown: recovery is best-effort per source, and one bad source
    /// must not block the others or the wiki open.
    public static func run(
        wikiID: WikiID,
        store: any WikiStore,
        queueStore: QueueStore
    ) async {
        let pending: [SourceID]
        do {
            pending = try store.sourcesWithPendingFormatJobs()
        } catch {
            DebugLog.store("FetchFormatJobRecovery: pending-format scan failed for wiki \(wikiID.rawValue): \(error)")
            return
        }
        for sourceID in pending {
            await converge(
                wikiID: wikiID, sourceID: sourceID,
                store: store, queueStore: queueStore)
        }
    }

    /// Converges one marker. Idempotent; safe to run from both hosts.
    static func converge(
        wikiID: WikiID,
        sourceID: SourceID,
        store: any WikiStore,
        queueStore: QueueStore
    ) async {
        // The dedupe key is scoped to the ACQUIRED content version, so the
        // recovery derives the exact same key the original enqueue used. A
        // missing acquired version means the marker is stale (no blob ever
        // landed) — leave it for diagnosis instead of enqueueing a job that
        // would convert nothing.
        let acquired: SourceVersion?
        do {
            acquired = try store.activeContentVersion(sourceID: sourceID)
        } catch {
            DebugLog.store("FetchFormatJobRecovery: acquired-version read failed for \(sourceID.rawValue): \(error)")
            return
        }
        guard let acquired else {
            DebugLog.store("FetchFormatJobRecovery: no acquired content version for \(sourceID.rawValue)")
            return
        }
        let key = QueueItemDedupeKey.followOnFormatExtraction(
            wikiID: wikiID,
            sourceID: sourceID,
            acquiredContentVersionID: acquired.id)
        let existing: QueueItem?
        do {
            existing = try queueStore.item(forDedupeKey: key)
        } catch {
            // A failed dedupe lookup must not enqueue a duplicate behind the
            // other host's back: surface it and let the next scan retry.
            DebugLog.store("FetchFormatJobRecovery: dedupe lookup failed for \(sourceID.rawValue): \(error)")
            return
        }
        if let existing {
            switch existing.state {
            case .completed:
                // The format job already ran (including after a user retry):
                // settle the marker instead of leaving a stale pending state.
                // The settle is VERSION-AWARE: a concurrent re-fetch that
                // committed a newer acquisition (re-marking formatJobPending)
                // is never clobbered by this stale scan.
                do {
                    let settled = try store.markFetchComplete(
                        sourceID: sourceID,
                        expectedContentVersionID: acquired.id)
                    if settled == false {
                        DebugLog.store("FetchFormatJobRecovery: settle skipped — active version moved past \(acquired.id.rawValue) for \(sourceID.rawValue)")
                    }
                } catch {
                    DebugLog.store("FetchFormatJobRecovery: settle failed for \(sourceID.rawValue): \(error)")
                }
            case .queued, .running, .failed, .cancelled:
                // The item exists; its own lifecycle owns the outcome. A
                // failed item stays for the user retry path — no second job.
                break
            }
            return
        }
        do {
            _ = try queueStore.enqueue(QueueItemRequest(
                queue: .extraction,
                wikiID: wikiID,
                payload: QueueItemPayload(sourceIDs: [sourceID]),
                dedupeKey: key))
        } catch {
            DebugLog.store("FetchFormatJobRecovery: follow-on enqueue failed for \(sourceID.rawValue): \(error)")
        }
    }
}
