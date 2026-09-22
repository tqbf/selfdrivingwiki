import Foundation
import WikiFSCore

/// `wikictl extractor sync <package> [--force]` — create one byteless source
/// per configured acquisition key of `<package>` and enqueue its durable
/// extraction job. This is the CLI seam of the extractor-package acquisition
/// API: today one package (`zotero`) is syncable; adding acquisition package
/// #2 means one dispatch case, never a new CLI family.
///
/// The command is ENQUEUE-ONLY: it writes the `.extraction` queue item
/// through the injected closure (production wires `QueueStore.enqueue`, the
/// same immediate durable store write `QueueEngine.enqueue` performs). It
/// never constructs a `QueueEngine` (that needs a `workerFactory` whose
/// provider implementations live in targets `WikiCtlCore` cannot link) and
/// never waits for completion (waiters are per-engine in-memory; a
/// daemon-side completion could never resume a CLI waiter). The app or the
/// wikid daemon rehydrates and drains the persisted items on its next
/// dispatch scan / launch.
///
/// Hard failures exit nonzero with a typed message: an unconfigured library
/// ID, no configured attachment keys, or no configured API key (a
/// describe-only presence check — the value is never read here). A key this
/// process cannot READ (no shared-keychain entitlement) defers the check to
/// the draining host instead of failing.
public enum ExtractorSyncCommand {

    /// The packages this command can sync. One case per acquisition
    /// package; each maps to one config sidecar + sync entry.
    public enum Package: String, CaseIterable, Sendable {
        /// The reviewed `org.selfdrivingwiki.zotero` package over
        /// `zotero-config.json`.
        case zotero

        public static let supportedPackages = Package.allCases.map(\.rawValue)
    }

    /// The family's operations. One case per leaf (`sync` today).
    public enum Action: Equatable, Sendable {
        case sync(Package, force: Bool)
    }

    /// One typed hard failure with a caller-facing message.
    public enum Failure: Error, Equatable, LocalizedError {
        /// The named package has no sync entry.
        case unknownPackage(String)

        public var errorDescription: String? {
            switch self {
            case .unknownPackage(let name):
                return "Unknown extraction package '\(name)'. Supported: \(Package.supportedPackages.joined(separator: ", "))."
            }
        }
    }

    public static func run(
        package: Package,
        force: Bool,
        in store: GRDBWikiStore,
        containerDirectory: URL,
        credentials: any CredentialDescribing = KeychainCredentialService(),
        enqueue: (SourceID) async throws -> Void
    ) async throws -> String {
        switch package {
        case .zotero:
            return try await runZotero(
                force: force, in: store, containerDirectory: containerDirectory,
                credentials: credentials, enqueue: enqueue)
        }
    }

    private static func runZotero(
        force: Bool,
        in store: GRDBWikiStore,
        containerDirectory: URL,
        credentials: any CredentialDescribing,
        enqueue: (SourceID) async throws -> Void
    ) async throws -> String {
        let config = ZoteroConfig.load(from: containerDirectory)
        // Hard gates first — nonzero exits with a typed message.
        guard config.isConfigured, let _ = config.libraryID else {
            throw ZoteroSyncError.libraryNotConfigured
        }
        guard !config.attachments.isEmpty else {
            throw ZoteroSyncError.noAttachments
        }
        // API-key presence — still describe-only (the value is never read
        // here), but "absent" and "unreadable here" are different outcomes.
        // A bare CLI Mach-O cannot carry keychain-access-groups (AMFI
        // SIGKILLs any that claim them without an embedded profile — see
        // build.sh), so on a configured machine EVERY shared-keychain read in
        // this process fails, and describe surfaces that as
        // verificationFailed, not as "unset". Failing the sync there would
        // block the documented flow even though the entitled host draining
        // this job (app / wikid.xpc) resolves the same key fine. Absent →
        // hard typed failure; unreadable → defer, and say so in the output.
        var keyCheckDeferred = false
        let keyInfo = credentials.describe(.zoteroAPIKey())
        if keyInfo.isConfigured == false {
            guard keyInfo.verificationFailed else {
                throw ZoteroSyncError.apiKeyNotConfigured
            }
            keyCheckDeferred = true
        }

        let outcomes = try await ZoteroSync.syncAttachments(
            store: store,
            config: config,
            enqueue: enqueue,
            force: force)

        var lines: [String] = []
        lines.append("Zotero sync: \(outcomes.count) attachment(s)")
        for outcome in outcomes {
            switch outcome.action {
            case .created:
                lines.append(
                    "  created  \(outcome.attachmentKey) → source \(outcome.sourceID.rawValue) (extraction enqueued)")
            case .reenqueued:
                lines.append(
                    "  re-enqueued  \(outcome.attachmentKey) → source \(outcome.sourceID.rawValue)")
            case .skipped:
                lines.append(
                    "  skipped  \(outcome.attachmentKey) → source \(outcome.sourceID.rawValue) already synced (use --force to re-extract)")
            }
        }
        lines.append(
            "Enqueued items drain when the app or the wikid daemon next runs its dispatch scan.")
        if keyCheckDeferred {
            lines.append(
                "Note: the API key could not be verified from this process; the host that drains these jobs will check it before downloading.")
        }
        return lines.joined(separator: "\n")
    }
}
