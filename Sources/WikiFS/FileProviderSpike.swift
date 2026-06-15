import AppKit
import FileProvider
import Observation
import WikiFSCore

/// Drives the File Provider domain from the app: register it, resolve the
/// user-visible Unix path (always asked of the system — never hardcoded), and
/// signal the daemon when the wiki changes so Terminal reads stay fresh.
@MainActor
@Observable
final class FileProviderSpike {
    private static let domain = NSFileProviderDomain(
        identifier: NSFileProviderDomainIdentifier(rawValue: "WikiFS"),
        displayName: "WikiFS"
    )

    var status = "Not registered"
    var path: String?

    /// Idempotent launch-time registration: ADD-IF-ABSENT. Query the existing
    /// domains and add ours only when it's missing, then resolve the path.
    ///
    /// Phase 2 used `remove(_, mode: .removeAll)` + re-add on every launch as a
    /// blunt cache-buster. Phase 3 replaces that with real change signaling
    /// (`signalChange()`), so we keep the domain — and its materialized tree —
    /// across launches instead of tearing it down each time.
    func registerIfNeeded() async {
        // Structural-change escape hatch (Phase 4). `signalEnumerator` /
        // `enumerateChanges` reliably refreshes existing items and surfaces NEW
        // FILES (e.g. `manifest.json`), but the daemon does not always synthesize
        // a brand-new top-level FOLDER (e.g. `indexes/`) into a root it has
        // already materialized from an older appex. When the projection's shape
        // changes between versions, a one-shot remove+re-add forces a clean full
        // `enumerateItems` so the new tree appears. Gated on an env var so normal
        // launches keep the lightweight add-if-absent path (no Phase-2 teardown).
        if ProcessInfo.processInfo.environment["WIKIFS_REENUMERATE"] == "1" {
            try? await NSFileProviderManager.remove(Self.domain)
        }

        let alreadyRegistered = (try? await NSFileProviderManager.domains())?
            .contains { $0.identifier == Self.domain.identifier } ?? false

        if !alreadyRegistered {
            do {
                try await NSFileProviderManager.add(Self.domain)
                status = "Domain registered — resolving path…"
            } catch {
                // A racing add can still report "already exists"; treat as benign
                // and fall through to resolve the path.
                status = "add(domain): \(error.localizedDescription)"
            }
        }
        await resolvePath()
    }

    func resolvePath() async {
        guard let manager = NSFileProviderManager(for: Self.domain) else {
            status = "No manager for domain"
            return
        }
        do {
            let url = try await manager.getUserVisibleURL(for: .rootContainer)
            path = url.path
            status = "Mounted"
        } catch {
            status = "getUserVisibleURL failed: \(error.localizedDescription)"
        }
    }

    /// Open an ingested file in its default app (e.g. Preview for a PDF).
    ///
    /// Resolves the file's user-visible URL from the daemon by its `by-id` leaf
    /// identifier (the canonical path — built from the shared prefix so it can't
    /// drift from the projection), then hands it to `NSWorkspace`. The URL is
    /// asked of the system at click time, never hardcoded (INITIAL §10). Opening
    /// materializes the bytes on demand via the extension's `fetchContents`, so
    /// it works even when the file isn't yet cached locally.
    func openIngestedFile(id: PageID) async {
        guard let manager = NSFileProviderManager(for: Self.domain) else {
            status = "No manager for domain"
            return
        }
        let identifier = NSFileProviderItemIdentifier(WikiFSContainerID.fileByID(id.rawValue))
        do {
            let url = try await manager.getUserVisibleURL(for: identifier)
            NSWorkspace.shared.open(url)
        } catch {
            status = "open file failed: \(error.localizedDescription)"
        }
    }

    /// Tell the daemon the wiki changed so it re-runs `enumerateChanges` and
    /// re-fetches the edited page's bytes (INITIAL §6/§10). Signals BOTH page
    /// containers AND the working set:
    /// - signaling only the root would NOT refresh the page-list children (root
    ///   never lists page files), so the edited file would stay stale;
    /// - the working set is the daemon's actively-tracked materialized set.
    /// Best-effort + non-throwing: signaling is advisory, not load-bearing for
    /// correctness (the version bump is). Awaited so callers may show a status.
    func signalChange() async {
        guard let manager = NSFileProviderManager(for: Self.domain) else { return }
        let containers: [NSFileProviderItemIdentifier] = [
            NSFileProviderItemIdentifier(WikiFSContainerID.pagesByTitle),
            NSFileProviderItemIdentifier(WikiFSContainerID.pagesByID),
            // The generated index bytes (manifest.json at root; the JSONL files
            // under `indexes`) derive from page content, so an edit must
            // invalidate them too — signal both their containers (Phase 4).
            .rootContainer,
            NSFileProviderItemIdentifier(WikiFSContainerID.indexes),
            // Ingested files (Phase 5): a drop OR a removal changes the `files/`
            // tree and the files.jsonl/manifest indexes. The model fires
            // `onPageDidChange?()` (wired to this) after ingest AND delete, so
            // signaling both `files/` views (and `indexes`, already above)
            // refreshes the projection without relaunch.
            NSFileProviderItemIdentifier(WikiFSContainerID.files),
            NSFileProviderItemIdentifier(WikiFSContainerID.filesByID),
            NSFileProviderItemIdentifier(WikiFSContainerID.filesByName),
            .workingSet,
        ]
        for container in containers {
            await withCheckedContinuation { continuation in
                manager.signalEnumerator(for: container) { _ in
                    continuation.resume()
                }
            }
        }
    }

    func remove() async {
        do {
            try await NSFileProviderManager.remove(Self.domain)
            path = nil
            status = "Removed"
        } catch {
            status = "remove(domain) failed: \(error.localizedDescription)"
        }
    }
}
