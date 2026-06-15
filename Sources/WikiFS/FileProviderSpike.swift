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
/// the Finder mount label (`~/Library/CloudStorage/WikiFS-<name>`), so a rename
/// is cosmetic and never breaks the DB mapping.
@MainActor
@Observable
final class FileProviderSpike {
    var status = "Not registered"
    /// The user-visible mount path of the ACTIVE wiki (resolved at select time).
    var path: String?

    /// The wiki whose mount `path` currently reflects, so `signalChange` and the
    /// path popover target the right domain.
    private var activeWikiID: String?
    private var activeDisplayName: String?

    /// Build the File Provider domain for a wiki. Identifier is the ULID (stable
    /// across rename); displayName drives the `WikiFS-<name>` mount label.
    private func domain(id: String, displayName: String) -> NSFileProviderDomain {
        NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: id),
            displayName: displayName
        )
    }

    // MARK: - Per-wiki registration

    /// Idempotent ADD-IF-ABSENT registration for ONE wiki's domain. Generalizes
    /// the v0 single-domain logic: query existing domains, add ours only when
    /// missing. The `WIKIFS_REENUMERATE` escape hatch (a one-shot remove+re-add to
    /// force a clean full enumeration on a structurally-changed projection) is
    /// preserved, now scoped to the named wiki.
    func registerDomain(id: String, displayName: String) async {
        let domain = domain(id: id, displayName: displayName)

        if ProcessInfo.processInfo.environment["WIKIFS_REENUMERATE"] == "1" {
            try? await NSFileProviderManager.remove(domain)
        }

        let alreadyRegistered = (try? await NSFileProviderManager.domains())?
            .contains { $0.identifier == domain.identifier } ?? false

        if !alreadyRegistered {
            do {
                try await NSFileProviderManager.add(domain)
            } catch {
                // A racing add can still report "already exists"; benign.
                status = "add(domain \(displayName)): \(error.localizedDescription)"
            }
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
        let domain = domain(id: id, displayName: displayName)
        guard let manager = NSFileProviderManager(for: domain) else {
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
            let url = try await manager.getUserVisibleURL(for: identifier)
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
            await withCheckedContinuation { continuation in
                manager.signalEnumerator(for: container) { _ in
                    continuation.resume()
                }
            }
        }
    }
}
