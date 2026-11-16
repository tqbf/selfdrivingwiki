//
//  ModelDelayedStoreTests.swift
//  P1.4 delayed-store semantics suite (plans/daemon-only-access.md Phase 1
//  item 4, designed in tmp/p1-delayed-store-design.md).
//
//  Pins `WikiStoreModel`'s async-concurrency semantics against
//  `ModelDelayedWikiStore` — an in-memory `GRDBWikiStore` wrapped in a
//  generated proxy whose `getPage` / `listPages` / `upsertPage` answers the
//  suite can gate, count, or fail on demand. Six scenarios:
//
//  1. Rapid A→B→C navigation lands only C (generation-checked loads).
//  2. A load completion released LAST is discarded (stale-completion pin).
//  3. Typing during a pending save keeps the draft and saves once.
//  4. A failed save on switch surfaces the error and preserves the store.
//  5. Overlapping event reloads coalesce into ONE follow-up reload.
//  6. Initialization readiness gates first render (bootstrap barrier).
//
//  Repo concurrency rule: every gate wait races a timeout
//  (`DelayedStoreGate` + `waitForEntry`), so a lost completion is a fast
//  diagnosed failure, never a hung `swift test`.
//
#if os(macOS)
import Foundation
import Testing
import WikiFSEngine
@testable import WikiFSCore

/// The error the failed-save scenario injects into the store's write seam.
private struct SaveAlwaysFailsError: Error, CustomStringConvertible {
    var description: String { "injected save failure (ModelDelayedStoreTests)" }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct ModelDelayedStoreTests {

    // MARK: - Fixtures

    private func makeModel() throws -> (model: WikiStoreModel, store: ModelDelayedWikiStore, controller: TestStoreController, bus: WikiEventBus) {
        let controller = TestStoreController()
        let store = try ModelDelayedWikiStore(controller: controller)
        let bus = WikiEventBus(wikiID: WikiID(rawValue: "model-delayed-tests"))
        // The bus must exist before the model is created — the model's init
        // subscribes to `store.eventBus` exactly once.
        store.eventBus = bus
        let model = WikiStoreModel(store: store)
        return (model, store, controller, bus)
    }

    private func seedPage(_ store: ModelDelayedWikiStore, title: String, body: String) async throws -> PageID {
        let page = try await store.createPage(title: title, body: body, createdBy: nil, provenance: [])
        return page.id
    }

    /// Yield the main actor a few rounds so spawned model tasks can run up to
    /// their next suspension point (a gate, a store hop, or completion).
    private func pump(steps: Int = 25) async {
        for _ in 0..<steps {
            await Task.yield()
        }
    }

    private func pageKey(_ id: PageID) -> String { "getPage:\(id.rawValue)" }

    // MARK: 1 — Rapid A→B→C navigation lands only C

    /// `beginSelectionTransition` bumps the load generation synchronously, so
    /// when A's and B's store reads complete after C already landed, the
    /// post-await generation check discards them: the editor keeps exactly
    /// C's content.
    @Test func rapidABCNavigationLandsOnlyCContent() async throws {
        let (model, store, controller, _) = try makeModel()
        let a = try await seedPage(store, title: "Alpha", body: "alpha-body-marker")
        let b = try await seedPage(store, title: "Beta", body: "beta-body-marker")
        let c = try await seedPage(store, title: "Gamma", body: "gamma-body-marker")

        // A and B park inside the store read; C answers immediately.
        controller.installGate(DelayedStoreGate(name: "getPage:A"), forKey: pageKey(a))
        controller.installGate(DelayedStoreGate(name: "getPage:B"), forKey: pageKey(b))

        model.select(.page(a))
        try await controller.waitForEntry(pageKey(a))
        model.select(.page(b))
        try await controller.waitForEntry(pageKey(b))
        model.select(.page(c))
        try await controller.waitForEntry("\(pageKey(c)):returned")
        await pump()
        await model.quiesceSelectionTransitions()

        // Only C's content landed (the observable landing state — no private
        // generation counter is read).
        #expect(model.draftTitle == "Gamma", "rapid A→B→C must land C's title, got '\(model.draftTitle)'")
        #expect(model.draftBody.contains("gamma-body-marker"), "rapid A→B→C must land C's body, got '\(model.draftBody)'")
        #expect(!model.draftBody.contains("alpha-body-marker"), "A's content must not appear, got '\(model.draftBody)'")
        #expect(!model.draftBody.contains("beta-body-marker"), "B's content must not appear, got '\(model.draftBody)'")
        guard case .page(let landed)? = model.selection, landed == c else {
            Issue.record("selection must be C after A→B→C, got \(String(describing: model.selection))")
            return
        }

        // Release the parked A/B reads: their completions are stale now.
        controller.gate(forKey: pageKey(a))?.open()
        controller.gate(forKey: pageKey(b))?.open()
        try await controller.waitForEntry("\(pageKey(a)):returned")
        try await controller.waitForEntry("\(pageKey(b)):returned")
        await pump()
        await model.quiesceSelectionTransitions()

        #expect(model.draftTitle == "Gamma", "stale completions must not overwrite C's title, got '\(model.draftTitle)'")
        #expect(model.draftBody.contains("gamma-body-marker"), "stale completions must not overwrite C's body, got '\(model.draftBody)'")
        #expect(controller.entryCount(pageKey(a)) == 1, "A was fetched exactly once and its completion discarded (count \(controller.entryCount(pageKey(a))))")
        #expect(controller.entryCount(pageKey(b)) == 1, "B was fetched exactly once and its completion discarded (count \(controller.entryCount(pageKey(b))))")
    }

    // MARK: 2 — Stale completion released LAST is discarded

    /// Same mechanism as scenario 1 with the releases reordered: C lands
    /// while A's read is still parked, then A completes LAST — its result
    /// must never touch the current page projection.
    @Test func staleALoadCompletionReleasedLastIsDiscarded() async throws {
        let (model, store, controller, _) = try makeModel()
        let a = try await seedPage(store, title: "Alpha", body: "alpha-late-marker")
        let c = try await seedPage(store, title: "Gamma", body: "gamma-current-marker")

        controller.installGate(DelayedStoreGate(name: "getPage:A-late"), forKey: pageKey(a))

        model.select(.page(a))
        try await controller.waitForEntry(pageKey(a))
        model.select(.page(c))
        try await controller.waitForEntry("\(pageKey(c)):returned")
        await pump()
        await model.quiesceSelectionTransitions()
        #expect(model.draftTitle == "Gamma", "C must land while A is parked, got '\(model.draftTitle)'")

        // A's completion arrives LAST — after C is already on screen.
        controller.gate(forKey: pageKey(a))?.open()
        try await controller.waitForEntry("\(pageKey(a)):returned")
        await pump()
        await model.quiesceSelectionTransitions()

        #expect(model.draftTitle == "Gamma", "A's late completion must not touch the title, got '\(model.draftTitle)'")
        #expect(model.draftBody.contains("gamma-current-marker"), "A's late completion must not touch the body, got '\(model.draftBody)'")
        #expect(!model.draftBody.contains("alpha-late-marker"), "A's late content must never appear, got '\(model.draftBody)'")
    }

    // MARK: 3 — Typing during a pending save keeps the draft, saves once

    /// `save()` reads title/body at call time; while that write is parked at
    /// the store, a keystroke changes the draft. The in-flight save commits
    /// exactly once with the PRE-keystroke content, the editor keeps the
    /// keystroke, and the preserved dirty state keeps an external event
    /// reload from treating the editor as clean and reverting the keystroke.
    @Test func typingDuringPendingSaveKeepsDraftAndSavesOnce() async throws {
        let (model, store, controller, bus) = try makeModel()
        let a = try await seedPage(store, title: "Alpha", body: "seed-body")

        model.select(.page(a))
        try await controller.waitForEntry("\(pageKey(a)):returned")
        await model.quiesceSelectionTransitions()
        #expect(model.draftTitle == "Alpha", "fixture: page A must be loaded, got '\(model.draftTitle)'")

        model.draftBody = "v1"
        model.bodyChanged()
        controller.installGate(DelayedStoreGate(name: "upsertPage"), forKey: "upsertPage")
        let saveTask = Task { await model.save() }
        try await controller.waitForEntry("upsertPage:\(a.rawValue)")

        // The keystroke lands while the save is suspended at the store.
        model.draftBody = "v2"
        model.bodyChanged()

        controller.gate(forKey: "upsertPage")?.open()
        await saveTask.value
        await model.quiesceSelectionTransitions()

        let upserts = controller.allUpserts()
        #expect(upserts.count == 1, "the pending save committed exactly once, got \(upserts.count) upserts")
        #expect(upserts.first?.rawBody == "v1", "the in-flight save wrote the PRE-keystroke content, got '\(upserts.first?.rawBody ?? "nil")'")
        #expect(model.draftBody == "v2", "the keystroke must survive the pending save, got '\(model.draftBody)'")

        // Dirty state preserved: an event-driven reload must skip the
        // clean-draft refresh (it would otherwise revert the editor to the
        // store's older "v1" and lose the keystroke).
        bus.emit(ResourceChangeEvent(wikiID: bus.wikiID, kind: .page, id: a.rawValue, change: .updated))
        await pump()
        await model.quiesceSelectionTransitions()
        #expect(model.draftBody == "v2", "a reload must not clobber the unsaved keystroke, got '\(model.draftBody)'")
    }

    // MARK: 4 — Failed save on switch surfaces the error, store preserved

    /// Switching away from a dirty page flushes the captured draft through
    /// `PageUpsert.upsert` → `store.upsertPage`. When that write fails, the
    /// model surfaces the failure through `storeError` (the same non-fatal
    /// alert `save()` uses), the outgoing page's store content is intact, and
    /// the incoming page still loads — the failed flush must not wedge the
    /// transition.
    @Test func failedSaveOnSwitchSurfacesErrorAndPreservesStoreContent() async throws {
        let (model, store, controller, _) = try makeModel()
        let a = try await seedPage(store, title: "Alpha", body: "alpha-original-body")
        let b = try await seedPage(store, title: "Beta", body: "beta-original-body")

        controller.setError(SaveAlwaysFailsError(), forKey: "upsertPage")

        model.select(.page(a))
        try await controller.waitForEntry("\(pageKey(a)):returned")
        await model.quiesceSelectionTransitions()
        #expect(model.draftTitle == "Alpha", "fixture: page A must be loaded, got '\(model.draftTitle)'")

        // Unsaved edits, then navigate away — the transition flushes A's
        // captured draft and the write fails.
        model.draftBody = "alpha-unsaved-edit"
        model.bodyChanged()
        model.select(.page(b))
        try await controller.waitForEntry("upsertPage:\(a.rawValue)")
        try await controller.waitForEntry("\(pageKey(b)):returned")
        await pump()
        await model.quiesceSelectionTransitions()

        #expect(controller.allUpserts().count == 1, "the outgoing flush attempted exactly one save, got \(controller.allUpserts().count)")
        #expect(model.storeError != nil, "the failed flush must surface through storeError")
        if let surfaced = model.storeError {
            #expect(surfaced.title == "Page Not Saved", "the alert must identify the save failure, got '\(surfaced.title)'")
            #expect(surfaced.message.contains("Alpha"), "the alert must name the outgoing page, got '\(surfaced.message)'")
        }
        #expect(model.draftTitle == "Beta", "the incoming page loads after the failed flush, got '\(model.draftTitle)'")
        #expect(model.draftBody.contains("beta-original-body"), "the incoming page's content is intact, got '\(model.draftBody)'")

        // The outgoing page's store content is preserved (no half-write).
        let alpha = try await store.getPage(id: a)
        #expect(alpha.title == "Alpha", "outgoing page kept its store title, got '\(alpha.title)'")
        #expect(alpha.bodyMarkdown.contains("alpha-original-body"), "outgoing page kept its store body, got '\(alpha.bodyMarkdown)'")
    }

    // MARK: 5 — Overlapping event reloads coalesce

    /// While one bus-driven `reloadFromStoreAsync` drain is parked at
    /// `listPages`, N further bus events only set `reloadPending`; the drain
    /// performs exactly ONE coalesced follow-up reload — `listPages` runs
    /// twice from the bus path (initial + follow-up), never N+1 times.
    @Test func overlappingEventReloadsCoalesceIntoOneFollowUp() async throws {
        let (model, store, controller, bus) = try makeModel()
        _ = try await seedPage(store, title: "Alpha", body: "alpha-body-marker")
        _ = try await seedPage(store, title: "Beta", body: "beta-body-marker")

        await model.bootstrapFromStore()
        let baseline = controller.callCount("listPages")
        #expect(baseline >= 1, "fixture: bootstrap must have loaded the summaries once, got \(baseline)")

        let gate = DelayedStoreGate(name: "listPages")
        controller.installGate(gate, forKey: "listPages")

        bus.emit(ResourceChangeEvent(wikiID: bus.wikiID, kind: .page, id: "any-page", change: .updated))
        try await controller.waitForEntry("listPages", minimum: baseline + 1)

        // Three more events while the first drain is parked in listPages.
        for _ in 0..<3 {
            bus.emit(ResourceChangeEvent(wikiID: bus.wikiID, kind: .page, id: "any-page", change: .updated))
        }
        await pump()

        gate.open()
        try await controller.waitForEntry("listPages:returned")
        await model.quiesceSelectionTransitions()
        await pump()

        let total = controller.callCount("listPages")
        #expect(total == baseline + 2, "N overlapping events coalesce into ONE follow-up reload (expected baseline \(baseline) + 2 reloads, got \(total))")
    }

    // MARK: 6 — Initialization readiness gates first render

    /// `bootstrapFromStore()` populates the projections before it returns:
    /// while it is parked at `listPages` the summaries stay empty and
    /// title/id-based selection guards refuse to resolve; after it returns
    /// the projections are populated and selection resolves.
    @Test func bootstrapGatesFirstRenderAndPreBootstrapSelectionDoesNotResolve() async throws {
        let (model, store, controller, _) = try makeModel()
        let a = try await seedPage(store, title: "Alpha", body: "alpha-body-marker")
        _ = try await seedPage(store, title: "Beta", body: "beta-body-marker")

        controller.installGate(DelayedStoreGate(name: "listPages"), forKey: "listPages")
        #expect(model.summaries.isEmpty, "a fresh model has empty projections")

        let bootTask = Task { await model.bootstrapFromStore() }
        try await controller.waitForEntry("listPages", minimum: 1)
        #expect(model.summaries.isEmpty, "bootstrap must not populate projections before it returns, got \(model.summaries.count) rows")
        #expect(model.selectPage(byTitle: "Alpha") == false, "pre-bootstrap byTitle selection must not resolve (guards on the empty projection)")
        #expect(model.selectPage(byID: a) == false, "pre-bootstrap byID selection must not resolve (guards on the empty projection)")

        controller.gate(forKey: "listPages")?.open()
        await bootTask.value

        #expect(model.summaries.count == 2, "bootstrap populated the projections before returning, got \(model.summaries.count) rows")
        #expect(model.summaries.contains(where: { $0.id == a }), "bootstrap loaded the seeded pages")
        #expect(model.selectPage(byTitle: "Alpha") == true, "post-bootstrap byTitle selection resolves")
    }
}
#endif // os(macOS)
