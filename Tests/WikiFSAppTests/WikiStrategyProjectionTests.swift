#if os(macOS)
import FileProvider
import Foundation
import Testing
import WikiFSCore
@testable import WikiFSFileProvider

/// `WIKI-STRATEGY.md` projection (wiki strategies, phase 2 — plan-001 AC.3):
/// mounted agents can read the current shared strategy projection, updates
/// invalidate it, and writes are rejected.
///
/// Named per the approved plan's AC.3: `contentAndIdentity`,
/// `updateAdvancesToken`, `rejectsWrites`, `compiledAgentFilesRemainIdentical`
/// (plus supporting enumeration / working-set / failure / read-only-connection
/// tests).
///
/// Design facts these tests pin:
///   * content — byte-exact the shared `WikiStrategyRenderer` document: the
///     saved strategy when one is committed, the Default description on a
///     successful read of true absence (nil), NEVER a Default stand-in for an
///     unreadable strategy row (a failed read omits the doc — explicit
///     absence, the `manifest.json` failure convention — because masking
///     could conceal a custom strategy behind authoritative Default prose);
///   * identity — the identifier is the shared `WikiFSContainerID` constant,
///     so the extension and the app's `signalChange()` cannot drift;
///   * token — the node's content version is the store change token; a
///     changed strategy save advances the store's strategy fold (v56), an
///     unchanged save does not;
///   * read-only — proven through the REAL extension write callbacks
///     (`createItem`/`modifyItem`/`deleteItem` reject with the read-only
///     error), not capability flags alone; the item's capabilities are
///     read-only as supporting evidence;
///   * `CLAUDE.md`/`AGENTS.md` remain identical COMPILED documents
///     (`SystemPrompt.defaultBody`) and stay distinct from the live strategy
///     doc.
///
/// The store-side strategy API (`getWikiStrategy()` / `saveWikiStrategy`)
/// lives in `WikiStore`; the projection only reads through `getWikiStrategy`.
@Suite
struct WikiStrategyProjectionTests {

    private struct Seeded {
        let projection: Projection
        let store: GRDBWikiStore
        let databaseURL: URL
    }

    /// A fresh temp wiki DB + projection bound to it (the `databaseURL`
    /// injection seam, as in `ProjectionTreeTests`).
    private func seed() throws -> Seeded {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-strategy-\(UUID().uuidString).sqlite")
        let store = try GRDBWikiStore(databaseURL: url)
        let projection = Projection(
            wikiID: WikiID(rawValue: "proj-strategy-\(UUID().uuidString)"),
            databaseURL: url)
        return Seeded(projection: projection, store: store, databaseURL: url)
    }

    /// Saves a strategy through the store's public write boundary
    /// (`WikiStore.saveWikiStrategy`). `expectedRevision: nil` is the
    /// first-save CAS expectation (no row ever written on a fresh wiki).
    @discardableResult
    private func saveStrategy(
        name: String = "Research Notes Wiki",
        instructions: String = "Organize pages by project, then by date. Prefer short titles.",
        expectedRevision: WikiStrategyRevision? = nil,
        on store: GRDBWikiStore
    ) throws -> WikiStrategySaveOutcome {
        try store.saveWikiStrategy(
            name: name, instructions: instructions, expectedRevision: expectedRevision)
    }

    // MARK: - AC.3 contentAndIdentity

    @Test func contentAndIdentity() throws {
        let s = try seed()

        // Identity: the identifier IS the shared container constant, so the
        // extension and the app's signalChange() build the same one.
        #expect(Projection.Identity.wikiStrategyMD.rawValue == WikiFSContainerID.wikiStrategyMD)
        #expect(WikiFSContainerID.wikiStrategyMD == "wiki-strategy-md")

        // Default (no strategy committed): always projected on a readable
        // store, serving the renderer's Default description byte-exact.
        guard let defaultNode = s.projection.node(for: Projection.Identity.wikiStrategyMD) else {
            Issue.record("WIKI-STRATEGY.md node not found with no strategy saved"); return
        }
        #expect(defaultNode.name == "WIKI-STRATEGY.md")
        #expect(defaultNode.parent == .rootContainer)
        #expect(!defaultNode.isFolder)
        #expect(defaultNode.modified == nil)
        let defaultData = s.projection.contents(for: Projection.Identity.wikiStrategyMD)
        #expect(defaultData == Data(WikiStrategyRenderer.render(nil).utf8))
        #expect(defaultNode.size == defaultData?.count)

        // Saved strategy: the renderer's full document, byte-exact — the
        // projection adds nothing and drops nothing.
        try saveStrategy(on: s.store)
        let stored = try s.store.getWikiStrategy()
        #expect(stored != nil)
        let savedData = s.projection.contents(for: Projection.Identity.wikiStrategyMD)
        #expect(savedData == Data(WikiStrategyRenderer.render(stored).utf8))

        let text = savedData.map { String(decoding: $0, as: UTF8.self) } ?? ""
        #expect(text.hasPrefix("# Wiki Strategy"))
        #expect(text.contains("Research Notes Wiki"))
        #expect(text.contains("Organize pages by project"))
        #expect(!text.contains("\nDefault\n"))

        guard let savedNode = s.projection.node(for: Projection.Identity.wikiStrategyMD) else {
            Issue.record("WIKI-STRATEGY.md node not found after save"); return
        }
        #expect(savedNode.size == savedData?.count)
        #expect(savedNode.modified == stored?.updatedAt)
        #expect(savedData != defaultData)
    }

    // MARK: - AC.3 updateAdvancesToken

    @Test func updateAdvancesToken() throws {
        let s = try seed()
        guard let before = s.projection.node(for: Projection.Identity.wikiStrategyMD) else {
            Issue.record("WIKI-STRATEGY.md node not found"); return
        }

        // A changed strategy save advances the store's strategy fold (v56),
        // so the doc's token-derived content version advances and the served
        // content moves Default → custom. This is the invalidation contract:
        // after the save's ResourceChangeEvent (kind .strategy) lands, the
        // app signals root + working set, the daemon re-enumerates, sees a
        // new version, and re-fetches.
        try saveStrategy(on: s.store)
        guard let after = s.projection.node(for: Projection.Identity.wikiStrategyMD) else {
            Issue.record("WIKI-STRATEGY.md node not found after save"); return
        }
        #expect(after.contentVersion != before.contentVersion)
        #expect(s.projection.contents(for: Projection.Identity.wikiStrategyMD)
                == Data(WikiStrategyRenderer.render(try s.store.getWikiStrategy()).utf8))

        // An UNCHANGED save writes nothing, does not advance the revision,
        // and must not advance the projected version either.
        let outcome = try saveStrategy(
            expectedRevision: try s.store.wikiStrategyRevision(), on: s.store)
        #expect(outcome == .unchanged)
        guard let unchanged = s.projection.node(for: Projection.Identity.wikiStrategyMD) else {
            Issue.record("WIKI-STRATEGY.md node not found after unchanged save"); return
        }
        #expect(unchanged.contentVersion == after.contentVersion)
    }

    // MARK: - AC.3 rejectsWrites

    @Test func rejectsWrites() throws {
        let s = try seed()
        guard let node = s.projection.node(for: Projection.Identity.wikiStrategyMD) else {
            Issue.record("WIKI-STRATEGY.md node not found"); return
        }
        let item = WikiFSItem(node: node)

        // Supporting evidence (not the primary proof): the item's capability
        // flags advertise read-only for the strategy doc.
        #expect(item.capabilities == [.allowsReading])

        // Primary proof: the REAL extension write callbacks reject writes to
        // the strategy doc. The callbacks complete synchronously with the
        // read-only error, so no waiting machinery is needed.
        let extensionInstance = FileProviderExtension(domain: NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: "strategy-rejects-writes"),
            displayName: "Strategy Rejects Writes"))
        let request = NSFileProviderRequest()
        let baseVersion = NSFileProviderItemVersion(
            contentVersion: node.contentVersion, metadataVersion: node.metadataVersion)

        var createError: Error?
        _ = extensionInstance.createItem(
            basedOn: item, fields: [], contents: nil,
            options: NSFileProviderCreateItemOptions(), request: request
        ) { _, _, _, error in createError = error }

        var modifyError: Error?
        _ = extensionInstance.modifyItem(
            item, baseVersion: baseVersion, changedFields: [], contents: nil,
            options: NSFileProviderModifyItemOptions(), request: request
        ) { _, _, _, error in modifyError = error }

        var deleteError: Error?
        _ = extensionInstance.deleteItem(
            identifier: Projection.Identity.wikiStrategyMD, baseVersion: baseVersion,
            options: NSFileProviderDeleteItemOptions(), request: request
        ) { error in deleteError = error }

        for (label, error) in [("createItem", createError),
                               ("modifyItem", modifyError),
                               ("deleteItem", deleteError)] {
            guard let nsError = error as? NSError else {
                Issue.record("\(label) did not reject with an NSError"); continue
            }
            #expect(nsError.domain == NSCocoaErrorDomain)
            #expect(nsError.code == NSFeatureUnsupportedError)
        }

        // The store row is untouched by any attempted mount write: the
        // strategy still reads back exactly what was committed (here: none —
        // the Default state).
        #expect(try s.store.getWikiStrategy() == nil)
    }

    // MARK: - AC.3 compiledAgentFilesRemainIdentical

    @Test func compiledAgentFilesRemainIdentical() throws {
        let s = try seed()
        try saveStrategy(on: s.store)

        // CLAUDE.md and AGENTS.md serve identical bytes — the compiled
        // SystemPrompt.defaultBody — and saving a strategy does not leak into
        // them. They direct standalone agents to the strategy file; they are
        // not strategy carriers themselves.
        let claude = s.projection.contents(for: Projection.Identity.claudeMD)
        let agents = s.projection.contents(for: Projection.Identity.agentsMD)
        #expect(claude != nil)
        #expect(claude == agents)
        #expect(claude == Data(SystemPrompt.defaultBody.utf8))

        // The strategy doc is a distinct live document, not a third alias of
        // the compiled prompt.
        #expect(s.projection.contents(for: Projection.Identity.wikiStrategyMD) != claude)
    }

    // MARK: - Failure is explicit absence, never a Default stand-in

    @Test func unreadableStrategyIsAbsentNotDefault() throws {
        // A DB file that exists but carries no wiki schema (e.g. a read
        // connection against a pre-v56 database): the strategy row cannot be
        // read. The doc must be ABSENT — serving the Default description
        // would authoritatively deny a custom strategy that may exist.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-strategy-fail-\(UUID().uuidString).sqlite")
        try Data().write(to: url)  // empty file = a valid empty SQLite database
        let projection = Projection(
            wikiID: WikiID(rawValue: "proj-strategy-fail-\(UUID().uuidString)"),
            databaseURL: url)

        #expect(projection.node(for: Projection.Identity.wikiStrategyMD) == nil)
        #expect(projection.contents(for: Projection.Identity.wikiStrategyMD) == nil)
        #expect(!projection.children(of: .rootContainer).map(\.name).contains("WIKI-STRATEGY.md"))
    }

    // MARK: - Enumeration (root children + working set)

    @Test func rootChildrenIncludeStrategyDocAfterTreeMD() throws {
        let s = try seed()
        let names = s.projection.children(of: .rootContainer).map(\.name)
        guard let index = names.firstIndex(of: "WIKI-STRATEGY.md") else {
            Issue.record("WIKI-STRATEGY.md missing from root children"); return
        }
        #expect(names.firstIndex(of: "TREE.md") == index - 1)
    }

    @Test func workingSetIncludesStrategyDoc() throws {
        let s = try seed()
        let ids = Set(s.projection.children(of: .workingSet).map(\.id))
        #expect(ids.contains(Projection.Identity.wikiStrategyMD))
    }

    // MARK: - Read-only connection (supporting evidence)

    @Test func projectionServesStrategyFromReadOnlyConnection() throws {
        // The projection's only DB access is `GRDBWikiStore(readOnlyURL:)`
        // (see `openReadStore`). Observable proof at this layer: serving the
        // doc leaves the wiki DB main file byte-identical (a read-only
        // SQLite connection cannot write it). Snapshot AFTER seeding so
        // writer-side WAL checkpoints can't race the comparison.
        let s = try seed()
        _ = s.projection.children(of: .rootContainer)
        _ = s.projection.contents(for: Projection.Identity.wikiStrategyMD)
        let before = try Data(contentsOf: s.databaseURL)

        _ = s.projection.children(of: .rootContainer)
        _ = s.projection.children(of: .workingSet)
        _ = s.projection.node(for: Projection.Identity.wikiStrategyMD)
        _ = s.projection.contents(for: Projection.Identity.wikiStrategyMD)

        let after = try Data(contentsOf: s.databaseURL)
        #expect(before == after)
    }
}
#endif  // os(macOS)
