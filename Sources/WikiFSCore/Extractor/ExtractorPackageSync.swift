import Foundation
import WikiFSTypes

// Package-declared acquisition sync — the store-level entry behind
// `wikictl extractor sync <package>`. Plain async, NOT `@MainActor`: the CLI
// is a no-MainActor process, and the store is method-atomic, so a plain
// entry drives both hosts.
//
// Every package-specific fact comes from the registration's sync
// declaration: the URL template produces the source URL, the package
// identity produces the provenance agent name, and the declared MIME is the
// byteless source's content type. One configured list item becomes ONE
// byteless source; the durable `.extraction` queue item is written by the
// caller through the injected `enqueue` closure — enqueue-only (the same
// immediate durable store write `QueueEngine.enqueue` performs), WITHOUT
// constructing a `QueueEngine`: the app or the wikid daemon rehydrates and
// drains the persisted item on its next dispatch scan / launch.

/// One item's sync outcome.
public struct ExtractorSyncOutcome: Sendable, Equatable {
    public enum Action: Sendable, Equatable, CustomStringConvertible {
        /// A new byteless source was created and its extraction enqueued.
        case created
        /// A source for this item's URL already exists (no `--force`).
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

    public let itemKey: String
    public let action: Action
    public let sourceID: SourceID
    public let jobID: QueueItem.ID?

    public init(
        itemKey: String,
        action: Action,
        sourceID: SourceID,
        jobID: QueueItem.ID? = nil
    ) {
        self.itemKey = itemKey
        self.action = action
        self.sourceID = sourceID
        self.jobID = jobID
    }
}

public enum ExtractorSyncEngineError: Error, Equatable, LocalizedError {
    /// An item did not form a valid source URL with the configured field
    /// values — the interpolated-template gate.
    case invalidItem(itemKey: String)

    public var errorDescription: String? {
        switch self {
        case .invalidItem(let itemKey):
            return "item \(itemKey) does not form a valid source URL"
        }
    }
}

/// The package facts the sync's provenance needs. Derived from catalog
/// data, never host literals: the agent name is the package ID's last
/// label, which the origin-provider display table may or may not know —
/// an unknown name degrades to the generic origin, it never fails the sync.
public struct ExtractorSyncPackageIdentity: Sendable, Hashable {
    public let packageID: ExtractorPackageID
    public let displayName: String

    /// `org.example.attachment` → `attachment`. Package IDs have at least
    /// two labels, so the fallback is unreachable; kept total anyway.
    public var shortName: String {
        packageID.rawValue.split(separator: ".").last.map(String.init)
            ?? packageID.rawValue
    }

    public init(packageID: ExtractorPackageID, displayName: String) {
        self.packageID = packageID
        self.displayName = displayName
    }
}

/// The acquisition sync: declared config → byteless sources → enqueued
/// extraction jobs. Fully generic — no package name, kind, or template is
/// compiled in.
public enum ExtractorPackageSync {

    /// Syncs every configured item of `config` into `store`.
    ///
    /// - Parameters:
    ///   - store: the wiki's store (one SQLite file per wiki — sources land
    ///     in this wiki).
    ///   - declaration: the registration's sync declaration.
    ///   - packageIdentity: provenance identity (agent name + display name).
    ///   - config: the loaded, validated sidecar values.
    ///   - sourceMIMEType: the byteless sources' content type — the
    ///     declaration's explicit MIME or the registration's single MIME.
    ///   - enqueue: the durable enqueue seam. Called once per created or
    ///     `--force`-re-enqueued source; implementations write the
    ///     `.extraction` queue item through `QueueStore.enqueue` and return.
    ///   - force: re-enqueue extraction for already-synced item URLs.
    public static func syncItems(
        store: any WikiStore,
        declaration: ExtractorSyncDeclaration,
        packageIdentity: ExtractorSyncPackageIdentity,
        config: ExtractorSyncSidecarValues,
        sourceMIMEType: ExtractorMIMEType,
        enqueue: (SourceID) async throws -> Void,
        force: Bool = false
    ) async throws -> [ExtractorSyncOutcome] {
        try await syncItems(
            store: store,
            declaration: declaration,
            packageIdentity: packageIdentity,
            config: config,
            sourceMIMEType: sourceMIMEType,
            enqueueJob: { sourceID in
                try await enqueue(sourceID)
                return nil
            },
            force: force)
    }

    /// Sync variant that preserves the stable durable queue item identifier.
    public static func syncItems(
        store: any WikiStore,
        declaration: ExtractorSyncDeclaration,
        packageIdentity: ExtractorSyncPackageIdentity,
        config: ExtractorSyncSidecarValues,
        sourceMIMEType: ExtractorMIMEType,
        enqueueJob: (SourceID) async throws -> QueueItem.ID?,
        force: Bool = false
    ) async throws -> [ExtractorSyncOutcome] {
        var outcomes: [ExtractorSyncOutcome] = []
        outcomes.reserveCapacity(config.items.count)
        for itemKey in config.items {
            guard let sourceURL = declaration.interpolatedURL(
                fieldValues: config.fieldValues, itemKey: itemKey) else {
                throw ExtractorSyncEngineError.invalidItem(itemKey: itemKey)
            }
            let identity = URLFetchService.urlIdentity(sourceURL.absoluteString)
            let existing = try identity.flatMap { try store.sourceMatchingURLIdentity($0) }
            if let existing {
                if force {
                    let jobID = try await enqueueJob(existing.id)
                    outcomes.append(ExtractorSyncOutcome(
                        itemKey: itemKey, action: .reenqueued,
                        sourceID: existing.id, jobID: jobID))
                } else {
                    outcomes.append(ExtractorSyncOutcome(
                        itemKey: itemKey, action: .skipped, sourceID: existing.id))
                }
                continue
            }

            let summary = try store.addBytelessSource(
                filename: itemKey,
                mimeType: sourceMIMEType.rawValue,
                provenance: SourceProvenance(
                    agentName: packageIdentity.shortName,
                    activityKind: "fetch",
                    plan: sourceURL.absoluteString,
                    externalRef: sourceURL.absoluteString,
                    externalIdentity: itemKey),
                role: .primary)
            let jobID = try await enqueueJob(summary.id)
            outcomes.append(ExtractorSyncOutcome(
                itemKey: itemKey, action: .created,
                sourceID: summary.id, jobID: jobID))
        }
        return outcomes
    }
}
