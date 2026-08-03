@preconcurrency import FileProvider
import Foundation
import WikiFSCore

/// The real `FileProviderDomainService` — a thin pass-through to
/// `NSFileProviderManager`'s domain-lifecycle statics.
///
/// Holds NO policy: every decision (add-if-absent, retry budget, whether a rename
/// may remove anything) lives in `FileProviderFacade` / `DomainRegistrationPolicy`
/// where it can be tested against a fake. This type exists purely so that those
/// decisions have something injectable to talk to.
struct SystemFileProviderDomainService: FileProviderDomainService {
    func add(id: WikiID, displayName: String) async throws {
        try await NSFileProviderManager.add(Self.domain(id: id, displayName: displayName))
    }

    func remove(id: WikiID, reason: DomainRemovalReason) async throws {
        // Log BEFORE the call, unconditionally: this deletes the daemon's replica,
        // and #919's crash lands in FileProvider XPC internals with no frame of
        // ours on the thread. A timestamped "teardown started, because X" line is
        // the only way a later crash report can be correlated against an
        // in-flight removal.
        DebugLog.fileprovider("domainService.remove(\(id.rawValue)): reason=\(reason.rawValue)")
        try await NSFileProviderManager.remove(Self.domain(id: id, displayName: id.rawValue))
    }

    func domains() async -> [RegisteredDomain] {
        // NSFileProviderDomain is not Sendable, so calling domains() from a
        // @MainActor context is a strict-concurrency error under Swift 6. Run the
        // call detached and extract only Sendable values before returning.
        await Task.detached {
            do {
                return try await NSFileProviderManager.domains()
                    .map { RegisteredDomain(id: WikiID(rawValue: $0.identifier.rawValue), displayName: $0.displayName) }
            } catch {
                DebugLog.fileprovider("domainService.domains(): list failed: \(error)")
                return []
            }
        }.value
    }

    /// Domain identity = the wiki's ULID; `displayName` only sets the Finder mount
    /// label. `remove` passes the id as the name because removal keys on the
    /// identifier alone.
    private static func domain(id: WikiID, displayName: String) -> NSFileProviderDomain {
        NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: id.rawValue),
            displayName: displayName
        )
    }
}
