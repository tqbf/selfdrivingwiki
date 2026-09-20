import Foundation

// Zotero attachment sync — the store-level acquisition entry shared by
// `wikictl zotero sync` today and the Settings UI later. Plain async, NOT
// `@MainActor`: the CLI is a no-MainActor process, and the store is
// method-atomic, so a plain entry drives both hosts.
//
// One configured attachment key becomes ONE byteless `.zotero` source whose
// URL is the canonical Zotero API file endpoint. The durable `.extraction`
// queue item is written by the caller through the injected `enqueue`
// closure — enqueue-only (the same immediate durable store write
// `QueueEngine.enqueue` performs), WITHOUT constructing a `QueueEngine`:
// the app or the wikid daemon rehydrates and drains the persisted item on
// its next dispatch scan / launch.

/// One attachment key's sync outcome.
public struct ZoteroSyncOutcome: Sendable, Equatable {
    public enum Action: Sendable, Equatable, CustomStringConvertible {
        /// A new byteless source was created and its extraction enqueued.
        case created
        /// A source for this attachment URL already exists (no `--force`).
        case skipped
        /// An existing source was re-enqueued (`--force`).
        case reenqueued

        public var description: String {
            switch self {
            case .created: return "created"
            case .skipped: return "skipped"
            case .reenqueued: return "re-enqueued"
            }
        }
    }

    public let attachmentKey: String
    public let action: Action
    public let sourceID: SourceID

    public init(attachmentKey: String, action: Action, sourceID: SourceID) {
        self.attachmentKey = attachmentKey
        self.action = action
        self.sourceID = sourceID
    }
}

public enum ZoteroSyncError: Error, Equatable, LocalizedError {
    /// `zotero-config.json` has no usable library ID.
    case libraryNotConfigured
    /// No attachment keys are configured — nothing to sync.
    case noAttachments

    public var errorDescription: String? {
        switch self {
        case .libraryNotConfigured:
            return "The Zotero library ID is not configured. Set it in Settings → Extraction → Zotero."
        case .noAttachments:
            return "No Zotero attachment keys are configured."
        }
    }
}

/// The acquisition sync: config → byteless `.zotero` sources → enqueued
/// extraction jobs.
public enum ZoteroSync {

    /// The canonical file endpoint the sync writes as the source URL —
    /// exactly the URL shape the reviewed package accepts. Nil for a
    /// malformed library ID or attachment key; the config gates reject
    /// those before sync.
    public static func attachmentFileURL(libraryID: String, attachmentKey: String) -> URL? {
        URL(string: "https://api.zotero.org/users/\(libraryID)/items/\(attachmentKey)/file")
    }

    /// Syncs every configured attachment key of `config` into `store`.
    ///
    /// - Parameters:
    ///   - store: the wiki's store (one SQLite file per wiki — sources land
    ///     in this wiki).
    ///   - config: the loaded `zotero-config.json`.
    ///   - enqueue: the durable enqueue seam. Called once per created or
    ///     `--force`-re-enqueued source; implementations write the
    ///     `.extraction` queue item through `QueueStore.enqueue` and return.
    ///   - force: re-enqueue extraction for already-synced attachment URLs.
    public static func syncAttachments(
        store: any WikiStore,
        config: ZoteroConfig,
        enqueue: (SourceID) async throws -> Void,
        force: Bool = false
    ) async throws -> [ZoteroSyncOutcome] {
        guard config.isConfigured, let libraryID = config.libraryID else {
            throw ZoteroSyncError.libraryNotConfigured
        }
        guard !config.attachments.isEmpty else {
            throw ZoteroSyncError.noAttachments
        }

        var outcomes: [ZoteroSyncOutcome] = []
        outcomes.reserveCapacity(config.attachments.count)
        for attachmentKey in config.attachments {
            guard let fileURL = attachmentFileURL(
                libraryID: libraryID, attachmentKey: attachmentKey) else {
                throw ZoteroConfigError.invalidAttachmentKey(
                    "attachment key \(attachmentKey) does not form a valid Zotero URL")
            }
            let identity = URLFetchService.urlIdentity(fileURL.absoluteString)
            let existing = try identity.flatMap { try store.sourceMatchingURLIdentity($0) }
            if let existing {
                if force {
                    try await enqueue(existing.id)
                    outcomes.append(ZoteroSyncOutcome(
                        attachmentKey: attachmentKey,
                        action: .reenqueued,
                        sourceID: existing.id))
                } else {
                    outcomes.append(ZoteroSyncOutcome(
                        attachmentKey: attachmentKey,
                        action: .skipped,
                        sourceID: existing.id))
                }
                continue
            }

            let summary = try store.addBytelessSource(
                filename: attachmentKey,
                mimeType: ContentTypeRegistry.zoteroAttachment,
                provenance: SourceProvenance(
                    agentName: SourceProvider.zotero.rawValue,
                    activityKind: "fetch",
                    plan: fileURL.absoluteString,
                    externalRef: fileURL.absoluteString,
                    externalIdentity: attachmentKey),
                role: .primary)
            try await enqueue(summary.id)
            outcomes.append(ZoteroSyncOutcome(
                attachmentKey: attachmentKey,
                action: .created,
                sourceID: summary.id))
        }
        return outcomes
    }
}
