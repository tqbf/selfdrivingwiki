import Foundation
import WikiCtlCore
import WikiFSCore

// The sanctioned LOCAL fixture leg for `wikictl extractor sync/fetch`
// (Phase 5 of plans/cli-domain-commands.md). These two dispatchers run ONLY
// inside an explicit `--database-path` fixture run — `WikiCtlRunner.runOrdinary`
// reaches the in-process store executor for explicit databases alone, and the
// boundary script's `QueueStore(` rule allowlists THIS file (and only this
// file) in the CLI targets as the carve-out.
//
// For every registry-selected run (`--wiki`), the ENTIRE command executes
// daemon-side (catalog + store + durable enqueue through the daemon's queue
// engine) and this file is never touched. The daemon's queue engine owns the
// durable enqueue; the direct `QueueStore` write below exists so the isolated
// fixture harness can stage extraction items without a running app.
//
// `QueueStore(` here is the sanctioned exception — see
// Tests/CordisTests/CordisBoundaryScriptTests.swift and
// scripts/check-cordis-boundaries.

/// `wikictl extractor sync <package>` dispatch for fixture runs: enqueue-only
/// queue wiring. The closure writes the durable `.extraction` item through
/// `QueueStore.enqueue` — the same immediate durable store write
/// `QueueEngine.enqueue` performs — WITHOUT constructing a `QueueEngine`
/// (that needs a worker factory whose provider implementations live in
/// targets `WikiCtlCore` cannot link) and WITHOUT waiting for completion
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

/// `wikictl extractor fetch <package> --item <key>` dispatch for fixture runs:
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
