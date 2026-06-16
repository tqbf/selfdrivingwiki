import AppKit
import FileProvider
import Observation
import WikiFSCore

/// Drives the File Provider domains from the app — now ONE domain per wiki
/// (`plans/llm-wiki.md` Phase 0). Registers/removes a domain per wiki, resolves
/// the user-visible Unix path of the active wiki's mount (always asked of the
/// system — never hardcoded), and signals the daemon when a wiki changes so
/// Terminal reads stay fresh.
///
/// **Domain identity = the wiki's ULID.** `domainFor(id:displayName:)` builds an
/// `NSFileProviderDomain(identifier: <ulid>, displayName: <name>)`; the extension
/// reads `domain.identifier` to pick `<ulid>.sqlite`. The display name only sets
/// the Finder mount label (`~/Library/CloudStorage/Self Driving Wiki-<name>`), so a rename
/// is cosmetic and never breaks the DB mapping.
@MainActor
@Observable
final class FileProviderSpike {
    var status = "Not registered"
    /// The user-visible mount path of the ACTIVE wiki (resolved at select time).
    var path: String?
    var isResolvingPath = false

    /// The wiki whose mount `path` currently reflects, so `signalChange` and the
    /// path popover target the right domain.
    private var activeWikiID: String?
    private var activeDisplayName: String?

    /// Build the File Provider domain for a wiki. Identifier is the ULID (stable
    /// across rename); displayName drives the `Self Driving Wiki-<name>` mount label.
    private func domain(id: String, displayName: String) -> NSFileProviderDomain {
        NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: id),
            displayName: displayName
        )
    }

    // MARK: - Per-wiki registration

    /// Idempotent ADD-IF-ABSENT registration for ONE wiki's domain, hardened to
    /// VERIFY + bounded-RETRY + NUDGE so a freshly-created wiki mounts immediately
    /// even when `fileproviderd` is momentarily busy.
    ///
    /// Background (Phase D gate): a freshly-created wiki ("GateD") did not mount
    /// until relaunch and showed NO error. The create→register→mount path is the
    /// same `add(domain)` launch uses; the defect was that registration was
    /// *brittle and silent* — a single `add`, with any failure swallowed into an
    /// unsurfaced `status` and never verified. So a busy daemon gave us no mount
    /// and no signal. This now:
    ///
    /// 1. **Surfaces failures** — a real `add` error (anything other than
    ///    already-exists) is logged to the console AND retained in `status`, never
    ///    swallowed.
    /// 2. **Verifies + retries** — after each `add` it confirms the domain
    ///    actually appears in `NSFileProviderManager.domains()`; if not (daemon
    ///    busy) it backs off and retries, up to `DomainRegistrationPolicy.maxAttempts`.
    /// 3. **Nudges enumeration** — on success it signals the new domain's root /
    ///    working-set enumerator (the same `signalEnumerator` path `signalChange`
    ///    uses, scoped to THIS domain) so the daemon materializes the root promptly
    ///    instead of waiting for an external trigger.
    ///
    /// Idempotent and safe to call repeatedly: launch calls it per wiki, create
    /// calls it once; an already-registered domain short-circuits to a nudge. The
    /// `WIKIFS_REENUMERATE` one-shot remove+re-add hatch is preserved. The backoff
    /// is an async sleep — it never blocks the main actor.
    @discardableResult
    func registerDomain(id: String, displayName: String) async -> Bool {
        let domain = domain(id: id, displayName: displayName)

        if ProcessInfo.processInfo.environment["WIKIFS_REENUMERATE"] == "1" {
            try? await NSFileProviderManager.remove(domain)
        }

        var attemptsMade = 0
        while attemptsMade < DomainRegistrationPolicy.maxAttempts {
            // Add only if absent — a present domain (already registered, or a
            // racing add that won) must not error out the whole flow.
            if !(await isDomainRegistered(id: id)) {
                do {
                    try await NSFileProviderManager.add(domain)
                } catch {
                    // Distinguish benign already-exists (the verify below confirms
                    // presence) from a real failure we must not bury: log it AND
                    // keep it in `status` so it shows in the console and the UI.
                    print("FileProviderSpike.registerDomain(\(displayName)): add failed: \(error)")
                    status = "Register \(displayName) failed: \(error.localizedDescription)"
                }
            }

            attemptsMade += 1
            let present = await isDomainRegistered(id: id)
            switch DomainRegistrationPolicy.decide(domainPresent: present, attemptsMade: attemptsMade) {
            case .registered:
                // Materialize the root now instead of waiting for an external
                // trigger — this is what makes the mount appear right after create.
                await nudgeInitialEnumeration(forWikiID: id)
                status = "Registered \(displayName)"
                return true

            case .retry:
                try? await Task.sleep(for: DomainRegistrationPolicy.retryBackoff)

            case .failed:
                print("""
                    FileProviderSpike.registerDomain(\(displayName)): domain \(id) \
                    still absent after \(attemptsMade) attempts — daemon may be wedged.
                    """)
                status = "Register \(displayName) failed: domain did not appear after \(attemptsMade) tries."
                return false
            }
        }
        return false
    }

    /// Is `id`'s domain present in the daemon's current domain list? Maps the
    /// `domains()` result to raw identifiers and defers the membership test to the
    /// pure policy helper. A failed `domains()` call reads as "not present" so the
    /// retry loop keeps trying.
    private func isDomainRegistered(id: String) async -> Bool {
        let domainIDs = (try? await NSFileProviderManager.domains())?
            .map(\.identifier.rawValue) ?? []
        return DomainRegistrationPolicy.isRegistered(domainIDs: domainIDs, wikiID: id)
    }

    /// Nudge the freshly-registered domain's root + working-set enumerator so the
    /// daemon materializes the root promptly after create. Reuses the same
    /// `signalEnumerator` path `signalChange` uses, scoped to THIS domain.
    /// Best-effort.
    private func nudgeInitialEnumeration(forWikiID id: String) async {
        let domain = domain(id: id, displayName: id)
        guard let manager = NSFileProviderManager(for: domain) else { return }
        for container in [NSFileProviderItemIdentifier.rootContainer, .workingSet] {
            await signalEnumerator(manager: manager, container: container, timeout: .seconds(3))
        }
    }

    /// Remove ONE wiki's domain (on delete). Clears the cached active path if it
    /// belonged to that wiki.
    func removeDomain(id: String) async {
        let domain = domain(id: id, displayName: id)
        do {
            try await NSFileProviderManager.remove(domain)
            if activeWikiID == id {
                activeWikiID = nil
                path = nil
                status = "Removed"
            }
        } catch {
            status = "remove(domain) failed: \(error.localizedDescription)"
        }
    }

    /// Make `id` the active wiki for path/signal purposes and resolve its mount
    /// path. Called when the user switches wikis.
    func activate(id: String, displayName: String) async {
        activeWikiID = id
        activeDisplayName = displayName
        await resolvePath(id: id, displayName: displayName)
    }

    /// Re-resolve the ACTIVE wiki's mount path (used by the path popover, which
    /// doesn't track the wiki id itself). No-op if no wiki is active yet.
    func resolvePath() async {
        guard let id = activeWikiID, let name = activeDisplayName else { return }
        await resolvePath(id: id, displayName: name)
    }

    func resolvePath(id: String, displayName: String) async {
        path = nil
        isResolvingPath = true
        defer { isResolvingPath = false }

        let domain = domain(id: id, displayName: displayName)
        guard let manager = NSFileProviderManager(for: domain) else {
            status = "No manager for domain"
            return
        }
        do {
            let url = try await userVisibleURL(
                manager: manager,
                itemIdentifier: .rootContainer,
                timeout: .seconds(5))
            path = url.path
            status = "Mounted"
        } catch {
            status = "Resolving mount timed out; retrying domain registration…"
            if await registerDomain(id: id, displayName: displayName) {
                await nudgeInitialEnumeration(forWikiID: id)
                do {
                    let url = try await userVisibleURL(
                        manager: manager,
                        itemIdentifier: .rootContainer,
                        timeout: .seconds(5))
                    path = url.path
                    status = "Mounted"
                    return
                } catch {
                    status = "Mount unavailable: \(error.localizedDescription)"
                }
            } else {
                status = "Mount unavailable: \(error.localizedDescription)"
            }
        }
    }

    /// Open an ingested file in its default app (e.g. Preview for a PDF), in the
    /// ACTIVE wiki's domain. Resolves the file's user-visible URL from the daemon
    /// by its `by-id` leaf identifier (built from the shared prefix so it can't
    /// drift), then hands it to `NSWorkspace`. URL asked at click time.
    func openIngestedFile(id: PageID) async {
        guard let wikiID = activeWikiID else { return }
        let domain = domain(id: wikiID, displayName: wikiID)
        guard let manager = NSFileProviderManager(for: domain) else {
            status = "No manager for domain"
            return
        }
        let identifier = NSFileProviderItemIdentifier(WikiFSContainerID.fileByID(id.rawValue))
        do {
            let url = try await userVisibleURL(
                manager: manager,
                itemIdentifier: identifier,
                timeout: .seconds(5))
            NSWorkspace.shared.open(url)
        } catch {
            status = "open file failed: \(error.localizedDescription)"
        }
    }

    /// Tell the daemon the ACTIVE wiki changed so it re-runs `enumerateChanges`
    /// and re-fetches edited bytes. Signals the page containers, the root, the
    /// indexes folder, and the files views, plus the working set — the same set
    /// v0 signaled, now scoped to the active wiki's domain. Best-effort.
    func signalChange() async {
        guard let wikiID = activeWikiID else { return }
        await signalChange(forWikiID: wikiID)
    }

    /// Signal a SPECIFIC wiki's domain (Phase A change bridge): a `wikictl` write
    /// can land in a wiki that is NOT the one on screen, and that wiki's mount
    /// must still refresh. Signals the same container set as the active-wiki
    /// path, scoped to the named wiki's domain. Best-effort.
    func signalChange(forWikiID wikiID: String) async {
        let domain = domain(id: wikiID, displayName: wikiID)
        guard let manager = NSFileProviderManager(for: domain) else { return }
        let containers: [NSFileProviderItemIdentifier] = [
            NSFileProviderItemIdentifier(WikiFSContainerID.pagesByTitle),
            NSFileProviderItemIdentifier(WikiFSContainerID.pagesByID),
            .rootContainer,
            NSFileProviderItemIdentifier(WikiFSContainerID.indexes),
            NSFileProviderItemIdentifier(WikiFSContainerID.files),
            NSFileProviderItemIdentifier(WikiFSContainerID.filesByID),
            NSFileProviderItemIdentifier(WikiFSContainerID.filesByName),
            .workingSet,
        ]
        for container in containers {
            await signalEnumerator(manager: manager, container: container, timeout: .seconds(3))
        }
    }

    private func signalEnumerator(
        manager: NSFileProviderManager,
        container: NSFileProviderItemIdentifier,
        timeout: Duration
    ) async {
        await withCheckedContinuation { continuation in
            let resolution = SignalResolution(continuation: continuation)
            manager.signalEnumerator(for: container) { _ in
                Task { @MainActor in
                    resolution.finish()
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                await MainActor.run {
                    resolution.finish()
                }
            }
        }
    }

    private func userVisibleURL(
        manager: NSFileProviderManager,
        itemIdentifier: NSFileProviderItemIdentifier,
        timeout: Duration
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let resolution = MountURLResolution(continuation: continuation)
            Task { @MainActor in
                do {
                    let url = try await manager.getUserVisibleURL(for: itemIdentifier)
                    resolution.succeed(url)
                } catch {
                    resolution.fail(error)
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                await MainActor.run {
                    resolution.fail(MountResolutionError.timedOut)
                }
            }
        }
    }

    private enum MountResolutionError: LocalizedError {
        case timedOut

        var errorDescription: String? {
            switch self {
            case .timedOut:
                "File Provider did not return a mount URL in time"
            }
        }
    }

    @MainActor
    private final class MountURLResolution {
        private var continuation: CheckedContinuation<URL, Error>?

        init(continuation: CheckedContinuation<URL, Error>) {
            self.continuation = continuation
        }

        func succeed(_ url: URL) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(returning: url)
        }

        func fail(_ error: Error) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(throwing: error)
        }
    }

    @MainActor
    private final class SignalResolution {
        private var continuation: CheckedContinuation<Void, Never>?

        init(continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func finish() {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume()
        }
    }
}
