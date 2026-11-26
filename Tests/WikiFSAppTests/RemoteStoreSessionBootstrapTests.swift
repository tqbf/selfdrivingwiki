#if os(macOS)
import CryptoKit
import Foundation
import Testing
@testable import WikiCtlCore
import WikiDaemonContract
import WikiFSCore
import WikiFSTypes
@testable import wikid

// Phase 2 item 2e (plans/daemon-only-access.md): the session bootstrap
// round trip over the REAL domain-socket transport against a fixture
// daemon:
//
// 1. The executor SERVES `sessionBootstrap` with the daemon-authoritative
//    values — the extraction claims its own workload execution resolves
//    through (the prepared store's registered inputs on the fixture
//    daemon), the renderer claims mirror (sorted presentation subset), the
//    wiki's change token, and the committed strategy snapshot.
// 2. The client APPLIES the payload on session open: the extraction mirror
//    lands verbatim in `registeredExtractionInputs`; the renderer claims
//    compose from the client machine catalog intersected with the daemon's
//    reported references (the daemon reports the SAME machine catalog its
//    composition projects, so the intersection is the full catalog); the
//    change token + strategy snapshot land in session state.
// 3. The flag-gated session wiring seam composes a `WikiStoreModel` FROM
//    the client's bootstrap-applied values and installs ONE coalesced
//    reload hook — proven live: a daemon-side commit + a gap event fires
//    exactly one reload that lands the new page in the model's summaries.
//
// Suite discipline per AGENTS.md #1051: `.serialized` + `.timeLimit`,
// non-blocking completion polls only.
@Suite(.serialized, .timeLimit(.minutes(8)))
@MainActor
struct RemoteStoreSessionBootstrapTests {

    // MARK: - Fixtures

    private func makeContainer() throws -> URL {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "rwsb-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: container, withIntermediateDirectories: true)
        return container
    }

    private func fixtureWiki(
        _ daemon: WikiDaemon, name: String = "Bootstrap Fixture"
    ) throws -> WikiID {
        let data = try #require(daemon.testFixtureCreateWiki(name: name))
        return try JSONDecoder().decode(WikiDescriptor.self, from: data).id
    }

    private func makeSocketServer(
        _ container: URL, _ daemon: WikiDaemon
    ) throws -> DaemonSearchSocketServer {
        let dispatcher = DaemonDomainSocketDispatcher(daemon: daemon)
        let server = try DaemonSearchSocketServer(containerDirectory: container) {
            data in
            await dispatcher.handle(data)
        }
        try server.start()
        return server
    }

    private func socketTransport(
        _ container: URL, timeout: TimeInterval = 30
    ) throws -> DomainSocketStoreTransport {
        DomainSocketStoreTransport(client: try DaemonDomainSocketClient(
            containerDirectory: container, timeout: timeout))
    }

    /// Seed the fixture store's daemon-authoritative claims: two extraction
    /// registrations + the machine renderer catalog (the SAME projection the
    /// daemon composition installs and the client composes from, so the
    /// mirror/intersection is deterministic on every machine).
    private func seedDaemonClaims(
        _ daemon: WikiDaemon, wikiID: WikiID
    ) async throws -> RegisteredExtractionInputs {
        let store = try await daemon.domainCommandStore(wikiID: wikiID)
        let seeded = RegisteredExtractionInputs(claims: [
            RegisteredExtractionInputs.Claim(
                kind: .docx, mimeTypes: [
                    "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
                ],
                filenameExtensions: ["docx"], wantsAgentCleanup: true),
            RegisteredExtractionInputs.Claim(
                kind: .html, mimeTypes: ["text/html"],
                filenameExtensions: ["html", "htm"]),
        ])
        store.registeredExtractionInputs = seeded
        store.registeredRendererSourceTypes =
            await RendererCatalogResolution.productionSourceTypes()
        return seeded
    }

    /// Raw store-family send over the real socket (the executor's own
    /// request shape).
    private func sendRaw(
        _ transport: DomainSocketStoreTransport, wikiID: String,
        operation: DaemonStoreOperation, payload: Data? = nil,
        stamp: DaemonMutationStamp? = nil
    ) async throws -> DaemonStoreReply {
        let storeRequest = DaemonStoreRequest(
            wikiID: wikiID, operation: operation.rawValue, stamp: stamp,
            payload: payload)
        let domainRequest = DaemonDomainRequest(
            requestID: UUID().uuidString, family: .store,
            operation: operation.rawValue,
            payload: try DaemonStoreWire.encode(storeRequest))
        let reply = try await transport.send(domainRequest, sinkRegistrationID: nil)
        if let domainError = reply.error {
            Issue.record(
                "domain rejection \(domainError.code.rawValue): \(domainError.message)")
        }
        guard let payloadData = reply.payload else {
            Issue.record("\(operation.rawValue) reply carried no payload")
            throw CancellationError()
        }
        return try DaemonStoreWire.decodeReply(payloadData)
    }

    // MARK: - Executor serves the daemon-authoritative payload

    @Test func executorServesTheDaemonAuthoritativeBootstrap()
        async throws {
        let container = try makeContainer()
        let daemon = WikiDaemon(containerDirectory: container)
        let wikiID = try fixtureWiki(daemon)
        let server = try makeSocketServer(container, daemon)
        defer { server.stop() }

        let seededInputs = try await seedDaemonClaims(daemon, wikiID: wikiID)

        let reply = try await sendRaw(
            try socketTransport(container), wikiID: wikiID.rawValue,
            operation: .sessionBootstrap)
        #expect(reply.error == nil)
        let result = try #require(reply.result)
        let bootstrap = try JSONDecoder().decode(
            DaemonStoreSessionBootstrap.self, from: result)

        // Extraction mirror: the seeded daemon claims cross INTACT.
        let mirroredClaims = bootstrap.registeredExtractionInputs.claims
        #expect(mirroredClaims.count == 2)
        let docx = mirroredClaims.first { $0.kind == ExtractorKind.docx.rawValue }
        #expect(docx?.mimeTypes == [
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        ])
        #expect(docx?.filenameExtensions == ["docx"])
        #expect(docx?.wantsAgentCleanup == true)
        let html = mirroredClaims.first { $0.kind == ExtractorKind.html.rawValue }
        #expect(html?.mimeTypes == ["text/html"])
        #expect(html?.filenameExtensions == ["html", "htm"])
        #expect(html?.wantsAgentCleanup == false)

        // Renderer mirror: the machine catalog's presentation subset,
        // sorted by descriptor reference for wire stability.
        let machineCatalog = await RendererCatalogResolution
            .productionSourceTypes()
        let expectedReferences = machineCatalog.claims.map {
            "\($0.reference.packageID.rawValue)/"
                + "\($0.reference.version.rawValue)/"
                + "\($0.reference.registrationID.rawValue)"
        }.sorted()
        #expect(
            bootstrap.registeredRendererSourceTypes.map(\.descriptorReference)
                == expectedReferences)
        let expectedByName = Dictionary(
            uniqueKeysWithValues: machineCatalog.claims.map { claim -> (String, RegisteredRendererSourceTypes.Claim) in
                (RemoteWikiStore.canonicalRendererReference(claim.reference), claim)
            })
        for wireClaim in bootstrap.registeredRendererSourceTypes {
            let core = try #require(expectedByName[wireClaim.descriptorReference])
            #expect(wireClaim.displayName == core.displayName)
            #expect(wireClaim.canonicalMIMEType == core.canonicalMIMEType.rawValue)
            #expect(
                wireClaim.mimeAliases
                    == Set(core.mimeAliases.map(\.rawValue)))
            #expect(
                wireClaim.filenameExtensions
                    == Set(core.filenameExtensions.map(\.rawValue)))
        }

        // Change token: the daemon's current value for this wiki.
        let daemonToken = await daemon.changeToken(wikiID: wikiID)
        #expect(bootstrap.changeToken == daemonToken)

        // Strategy snapshot: Default (never written) is the ABSENCE.
        #expect(bootstrap.strategySnapshot == nil)
        _ = seededInputs
    }

    @Test func bootstrapCarriesTheCommittedStrategySnapshot()
        async throws {
        let container = try makeContainer()
        let daemon = WikiDaemon(containerDirectory: container)
        let wikiID = try fixtureWiki(daemon)
        let server = try makeSocketServer(container, daemon)
        defer { server.stop() }

        _ = try await seedDaemonClaims(daemon, wikiID: wikiID)
        let store = try await daemon.domainCommandStore(wikiID: wikiID)
        let saved = try await store.saveWikiStrategy(
            name: "Bootstrap Strategy",
            instructions: "Keep pages short.",
            expectedRevision: nil)

        let reply = try await sendRaw(
            try socketTransport(container), wikiID: wikiID.rawValue,
            operation: .sessionBootstrap)
        let result = try #require(reply.result)
        let bootstrap = try JSONDecoder().decode(
            DaemonStoreSessionBootstrap.self, from: result)
        let snapshot = try #require(bootstrap.strategySnapshot)
        #expect(snapshot.name == "Bootstrap Strategy")
        #expect(snapshot.instructions == "Keep pages short.")
        guard case .saved(let revision, let savedStrategy) = saved else {
            Issue.record("expected a changed save, got \(saved)")
            return
        }
        #expect(snapshot.revision == revision.rawValue)
        #expect(savedStrategy?.name == "Bootstrap Strategy")
    }

    // MARK: - Client applies the payload on session open

    @Test func sessionOpenAppliesTheBootstrapIntoTheClientProperties()
        async throws {
        let container = try makeContainer()
        let daemon = WikiDaemon(containerDirectory: container)
        let wikiID = try fixtureWiki(daemon)
        let server = try makeSocketServer(container, daemon)
        defer { server.stop() }

        let seededInputs = try await seedDaemonClaims(daemon, wikiID: wikiID)

        let remote = RemoteWikiStore(
            transport: try socketTransport(container), wikiID: wikiID)
        // Before open: nothing applied.
        #expect(remote.registeredExtractionInputs.isEmpty)
        #expect(remote.registeredRendererSourceTypes.isEmpty)
        #expect(remote.sessionStrategySnapshot() == nil)

        try await remote.warmSession()

        // Extraction claims applied verbatim (mirror → core).
        let applied = remote.registeredExtractionInputs
        #expect(applied.claims.count == 2)
        let appliedDocx = applied.claims.first { $0.kind == .docx }
        #expect(appliedDocx?.wantsAgentCleanup == true)
        #expect(appliedDocx?.filenameExtensions == ["docx"])
        let appliedHTML = applied.claims.first { $0.kind == .html }
        #expect(appliedHTML?.mimeTypes == ["text/html"])
        #expect(applied == seededInputs)

        // Renderer claims composed from the machine catalog ∩ mirror — the
        // daemon reports the same catalog, so the full catalog applies.
        let machineCatalog = await RendererCatalogResolution
            .productionSourceTypes()
        #expect(
            remote.registeredRendererSourceTypes.claims
                == machineCatalog.claims)

        // Strategy snapshot state: Default = nil.
        #expect(remote.sessionStrategySnapshot() == nil)
    }

    // MARK: - The flag-gated session wiring seam (remote branch)

    @Test func seamComposesTheModelFromBootstrapAndReloadsOnceOnSignal()
        async throws {
        let container = try makeContainer()
        let daemon = WikiDaemon(containerDirectory: container)
        let wikiID = try fixtureWiki(daemon)
        let server = try makeSocketServer(container, daemon)
        defer { server.stop() }

        _ = try await seedDaemonClaims(daemon, wikiID: wikiID)

        let remote = RemoteWikiStore(
            transport: try socketTransport(container), wikiID: wikiID)
        let model = WikiStoreModel(store: remote)
        await model.bootstrapFromStore()
        let baselineCount = model.summaries.count

        // The seam composes model FROM the client's bootstrap-applied
        // values and installs the reload hook (works with the app-wide
        // switch off — only the direct remote branch runs).
        try await RemoteStoreSessionComposition.compose(
            model: model, remote: remote)
        #expect(model.registeredExtractionInputs == remote.registeredExtractionInputs)
        #expect(
            model.registeredRendererSourceTypes
                == remote.registeredRendererSourceTypes)
        #expect(remote.onReloadSignal != nil)

        // ONE coalesced reload on the store's signal: a daemon-side commit
        // lands in the model ONLY through the installed hook.
        let direct = try await daemon.domainCommandStore(wikiID: wikiID)
        _ = try await direct.createPage(
            title: "Reload Target", body: "signaled body", createdBy: nil,
            provenance: [])
        // A sequence GAP triggers the store's one reconciliation signal
        // (the domain socket has no reverse push; deliver the envelope the
        // way an in-band channel would).
        let envelope = try JSONEncoder().encode(DaemonStoreEventEnvelope(
            event: DaemonStoreEvent(
                epoch: daemon.daemonEpoch, wikiID: wikiID.rawValue,
                sequence: 10_000,
                changeToken: "tok-seam-\(UUID().uuidString)",
                batch: [DaemonResourceChangeEvent(
                    kind: "page", id: "01SEAM0000000000000000ZZ",
                    change: "created", seq: 10_000)])))
        remote.deliverEvent(envelope)

        let deadline = ContinuousClock.now + .seconds(10)
        while !model.summaries.contains(where: { $0.title == "Reload Target" }) {
            if ContinuousClock.now >= deadline {
                Issue.record(
                    "the reload signal never landed the daemon-side page")
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(model.summaries.count == baselineCount + 1)
    }
}
#endif
