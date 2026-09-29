import Foundation
import WikiFSCore
import WikiFSTypes

/// `wikictl extractor fetch <package> --item <key> [--force]` — acquire ONE
/// item through a package fetcher NOW, without touching the package's
/// configured watch list.
///
/// This is the ad-hoc acquisition verb. `sync` drains the sidecar's item
/// list (the UI-managed watch list); `fetch` takes a single item key on the
/// command line — the shape an agent needs right after it finds an item:
/// `wikictl extractor fetch zotero --item W23YU548` creates the byteless
/// source with full fetch provenance (agent name, fetch URL plan, external
/// identity = the item key) and enqueues its extraction. The queue's fetch
/// route then downloads through the package with its credential and writes
/// the neutral external provenance (`external_item_key` /
/// `external_item_title`), so the source shows its real origin ("Zotero / …")
/// instead of a generic import.
///
/// The command shares `sync`'s front half (`resolveAcquisition`: discovery,
/// ambiguity guard, credential gate) and its item engine
/// (`ExtractorPackageSync.syncItems` over a one-item config), so the two
/// commands accept the same packages, validate keys by the same rules, and
/// produce byte-identical provenance. It is ENQUEUE-ONLY, like `sync`: the
/// app or the wikid daemon drains the job.
public enum ExtractorFetchCommand {

    /// One typed hard failure with a caller-facing message. Package and
    /// credential failures reuse `ExtractorSyncCommand.Failure` so the two
    /// commands report identically.
    public enum Failure: Error, Equatable, LocalizedError {
        /// The `--item` key violates the declaration's item validation
        /// (length / alphabet), or the hard host limits when no validation
        /// is declared — the same rules the sidecar applies to its list.
        case invalidItem(item: String, reason: String)

        public var errorDescription: String? {
            switch self {
            case .invalidItem(let item, let reason):
                return "Invalid item key '\(item)': \(reason)."
            }
        }
    }

    /// Runs fetch and reports the durable job ID returned by the queue store.
    public static func run(
        packageName: String,
        itemKey: String,
        force: Bool,
        in store: GRDBWikiStore,
        containerDirectory: URL,
        catalog: any ExtractorPackageCatalogReading,
        credentials: any CredentialDescribing = KeychainCredentialService(),
        enqueueJob: (SourceID) async throws -> QueueItem.ID?
    ) async throws -> String {
        // Same packages, same messages as `sync`.
        let resolved = try ExtractorSyncCommand.resolveAcquisition(
            packageName: packageName, catalog: catalog, credentials: credentials)
        let declaration = resolved.package.sync

        // Item-key validation — exactly the sidecar's rules, so an ad-hoc
        // key is held to the same contract as a configured one.
        let trimmed = itemKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if let validation = declaration.itemValidation {
            if let reason = validation.invalidReason(forItem: trimmed) {
                throw Failure.invalidItem(item: trimmed, reason: reason)
            }
        } else if trimmed.isEmpty
            || trimmed.utf8.count > ExtractorHostLimits.maximumSyncItemLength {
            throw Failure.invalidItem(
                item: trimmed,
                reason: trimmed.isEmpty
                    ? "is empty"
                    : "exceeds the supported length")
        }

        // Template fields (libraryID, …) still come from the sidecar — the
        // fetch URL needs them — but the watch list is NOT consulted: the
        // one item comes from --item, so the list may legitimately be empty
        // or absent. The sidecar is never modified.
        let fieldValues = try ExtractorSyncSidecar.loadFieldValues(
            declaration: declaration, from: containerDirectory)
        let config = ExtractorSyncSidecarValues(fieldValues: fieldValues, items: [trimmed])

        let outcomes = try await ExtractorPackageSync.syncItems(
            store: store,
            declaration: declaration,
            packageIdentity: ExtractorSyncPackageIdentity(
                packageID: resolved.package.record.revision.packageID,
                displayName: resolved.package.record.displayName),
            config: config,
            sourceMIMEType: resolved.sourceMIMEType,
            enqueueJob: { sourceID in
                do {
                    return try await enqueueJob(sourceID)
                } catch {
                    // Never silent: the source row is durable either way, so
                    // the failure must say what exists and what retries it.
                    throw ExtractorSyncCommand.Failure.enqueueRejected(
                        sourceID: sourceID,
                        packageName: packageName,
                        detail: String(describing: error))
                }
            },
            force: force)

        return try ExtractorSyncCommand.renderOutcomes(
            outcomes,
            header: "\(resolved.package.record.displayName) fetch",
            credentialCheckDeferred: resolved.credentialCheckDeferred,
            requiredCredentialLabel: resolved.requiredRequirement?.label,
            extractionCompleted: { sourceID in
                try store.processedMarkdownAlternatives(sourceID: sourceID).isEmpty == false
            })
    }
}
