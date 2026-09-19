import Foundation
import WikiFSCore

/// `wikictl zotero sync` — create one byteless `.zotero` source per
/// configured attachment key and enqueue its durable extraction job.
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
/// describe-only presence check — the value is never read here).
public enum ZoteroSyncCommand {

    /// One typed hard failure with a caller-facing message.
    public enum Failure: Error, Equatable, LocalizedError {
        /// The Zotero API key is not configured in Keychain (presence check).
        case apiKeyNotConfigured

        public var errorDescription: String? {
            switch self {
            case .apiKeyNotConfigured:
                return "The Zotero API key is not configured. Set it in the app (Settings → Zotero)."
            }
        }
    }

    public static func run(
        force: Bool,
        in store: GRDBWikiStore,
        containerDirectory: URL,
        credentials: any CredentialDescribing = KeychainCredentialService(),
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
        guard credentials.describe(.zoteroAPIKey()).isConfigured else {
            throw Failure.apiKeyNotConfigured
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
        return lines.joined(separator: "\n")
    }
}
