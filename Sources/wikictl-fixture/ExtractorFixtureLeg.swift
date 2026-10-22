import Foundation
import WikiCtlCore
import WikiFSCore

// The LOCAL fixture leg for `wikictl-fixture extractor sync/fetch`. These two
// dispatchers run ONLY inside an explicit `--database-path` fixture run of the
// build-only fixture binary — the local executor in this target's main.swift
// reaches them for the extractor sync/fetch actions alone. They moved here
// from Sources/wikictl with the fixture-binary split (plans/cli-domain-
// commands.md §"The fixture binary") so the shipping wikictl carries no
// direct-queue pathway at all.
//
// For every registry-selected run (`--wiki`), the ENTIRE command executes
// daemon-side (catalog + store + durable enqueue through the daemon's queue
// engine) and this file is never touched. The daemon's queue engine owns the
// durable enqueue; the direct `QueueStore` write below exists so the isolated
// fixture harness can stage extraction items without a running app. The
// `wikictl-fixture` TARGET is outside the CLI-target scope of
// scripts/check-cordis-boundaries (exempt like the test targets); the
// `QueueStore(` constructs here would fail the check if this file moved back
// into Sources/wikictl or Sources/WikiCtlCore — that is the point.

/// `wikictl-fixture extractor sync <package>` dispatch: enqueue-only queue
/// wiring. The closure writes the durable `.extraction` item through
/// `QueueStore.enqueue` — the same immediate durable store write
/// `QueueEngine.enqueue` performs — WITHOUT constructing a `QueueEngine`
/// (that needs a worker factory whose provider implementations live in
/// targets this binary does not link) and WITHOUT waiting for completion
/// (waiters are per-engine in-memory; a daemon-side completion could never
/// resume a CLI waiter — it would hang). The app or the wikid daemon
/// rehydrates and drains the persisted items on its next dispatch scan /
/// launch.
func runExtractorSync(
    packageName: String,
    force: Bool,
    in store: GRDBWikiStore,
    wikiID: WikiID,
    containerDirectory: URL
) async throws -> SourceCommand.Result {
    let queueStore = try QueueStore(
        databaseURL: try DatabaseLocation.queueDatabaseURL())
    defer { queueStore.close() }
    // Discovery = durable machine catalog ∪ this process's reviewed overlay.
    // The reviewed root is wherever an `ExtractorPackages/` tree is staged
    // beside this binary (the build layout); when that does not resolve
    // (an app-bundled helper), the durable catalog the app published at
    // launch still carries the record.
    let reviewedRoot = ExtractorSyncCommand.reviewedPackageRoot()
    let catalog = try ExtractorSyncCommand.productionCatalogReader(
        containerDirectory: containerDirectory,
        reviewedPackageRoot: reviewedRoot)
    let output = try await ExtractorSyncCommand.run(
        packageName: packageName,
        force: force,
        in: store,
        containerDirectory: containerDirectory,
        catalog: catalog,
        enqueueJob: { sourceID in
            try queueStore.enqueue(QueueItemRequest(
                queue: .extraction,
                wikiID: wikiID,
                payload: QueueItemPayload(sourceIDs: [sourceID]))).id
        })
    return SourceCommand.Result(payload: .text(output), didCommit: true)
}

/// `wikictl-fixture extractor fetch <package> --item <key>` dispatch:
/// the same enqueue-only wiring as `runExtractorSync` — durable queue write,
/// no `QueueEngine`, no waiting (the daemon-side drain owns completion).
func runExtractorFetch(
    packageName: String,
    itemKey: String,
    force: Bool,
    in store: GRDBWikiStore,
    wikiID: WikiID,
    containerDirectory: URL
) async throws -> SourceCommand.Result {
    let queueStore = try QueueStore(
        databaseURL: try DatabaseLocation.queueDatabaseURL())
    defer { queueStore.close() }
    let reviewedRoot = ExtractorSyncCommand.reviewedPackageRoot()
    let catalog = try ExtractorSyncCommand.productionCatalogReader(
        containerDirectory: containerDirectory,
        reviewedPackageRoot: reviewedRoot)
    let output = try await ExtractorFetchCommand.run(
        packageName: packageName,
        itemKey: itemKey,
        force: force,
        in: store,
        containerDirectory: containerDirectory,
        catalog: catalog,
        enqueueJob: { sourceID in
            try queueStore.enqueue(QueueItemRequest(
                queue: .extraction,
                wikiID: wikiID,
                payload: QueueItemPayload(sourceIDs: [sourceID]))).id
        })
    return SourceCommand.Result(payload: .text(output), didCommit: true)
}
