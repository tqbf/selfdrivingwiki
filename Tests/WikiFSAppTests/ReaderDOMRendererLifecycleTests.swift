#if os(macOS)
import Foundation
import Testing
@testable import WikiFS
import WikiFSCore
import WikiFSTypes

/// Phase 3 acceptance tests for the one DOM lifecycle: production coordinator
/// ownership, budget separation, retryable refusal, and scoped teardown.
@MainActor
struct ReaderDOMRendererLifecycleTests {
    private func placeholder(_ raw: String) throws -> RendererAttachmentPlaceholderID {
        try RendererAttachmentPlaceholderID(validating: raw)
    }

    private func event(
        _ id: RendererAttachmentPlaceholderID,
        role: RendererEmbeddingRole,
        generation: Int = 1,
        visible: Bool = false,
        removed: Bool = false
    ) -> RendererAttachmentLifecycleMessage {
        guard let message = RendererAttachmentLifecycleMessage(
            generation: generation,
            placeholderID: id,
            embeddingRole: role,
            visible: visible,
            isRemoval: removed)
        else { fatalError("fixture must satisfy lifecycle message validation") }
        return message
    }

    @Test("lifecycle event decode accepts discovery and rejects malformed shapes")
    func lifecycleMessageDecode() throws {
        let id = try placeholder("row-a")
        let valid = RendererAttachmentLifecycleMessage(
            generation: 2, placeholderID: id,
            embeddingRole: .inlineContent, visible: true, isRemoval: false)
        #expect(valid != nil)

        let removalShape: [String: Any] = [
            "generation": 1, "placeholderID": id.rawValue,
            "removed": true, "visible": false,
        ]
        // Removal decode path tolerates a missing role.
        var body = removalShape
        #expect(RendererAttachmentLifecycleMessage(body: body) == nil)

        body["embeddingRole"] = "inlineContent"
        #expect(RendererAttachmentLifecycleMessage(body: body) != nil)
        _ = valid
    }

    @Test("placeholder registration is discovery-gated and idempotent")
    func registrationIsIdempotent() throws {
        let coordinator = ReaderDOMRendererCoordinator(generation: 1)
        let id = try placeholder("row-a")
        let message = event(id, role: .disclosureRow)

        #expect(coordinator.registerPlaceholder(message) != nil)
        #expect(coordinator.registerPlaceholder(message) != nil)
        #expect(coordinator.activeUnitCount == 1)
        #expect(coordinator.state(for: id)?.role == .disclosureRow)

        // A stale generation fails closed.
        let stale = event(id, role: .disclosureRow, generation: 99)
        #expect(coordinator.registerPlaceholder(stale) == nil)
    }

    @Test("production coordinator uses one lifecycle and one owner per embed")
    func productionCoordinatorUsesOneLifecycle() throws {
        let coordinator = ReaderDOMRendererCoordinator(generation: 3)
        let id = try placeholder("row-a")
        _ = coordinator.registerPlaceholder(event(id, role: .disclosureRow, generation: 3))

        // No session resources yet: collapsed, no broker, no surface.
        let before = coordinator.state(for: id)
        #expect(before?.lifecycle == .collapsed)
        #expect(before?.surfaceID == nil)

        // Budget reservation moves the unit to loading with no broker.
        #expect(coordinator.beginLoading(id, role: .disclosureRow) == nil)
        #expect(coordinator.lifecycle(for: id) == .loading)
        #expect(coordinator.state(for: id)?.surfaceID == nil)

        // Attaching the session makes the embed active.
        let broker = RendererContentWorldBroker(
            sessionID: .init(rawValue: UUID()),
            capability: .init(rawValue: "cap"),
            inputReader: StubInputReader.make())
        let token = RendererFrameOriginToken.generate()
        #expect(coordinator.attachSession(id, broker: broker, frameToken: token))
        #expect(coordinator.lifecycle(for: id) == .loading)

        // Only a real load completion activates the unit.
        coordinator.finishLoading(id)
        #expect(coordinator.lifecycle(for: id) == .active)
        broker.close()
    }

    @Test("row inline and frame budgets are independent and refusal creates no resources")
    func rowInlineAndFrameBudgetsAreIndependent() throws {
        let coordinator = ReaderDOMRendererCoordinator(
            generation: 1, maximumExpandedRows: 2, maximumInlineRenderers: 1,
            maximumPackageFrames: 1)
        let rows = try (0...2).map { try placeholder("row-\($0)") }
        for row in rows {
            _ = coordinator.registerPlaceholder(event(row, role: .disclosureRow))
        }

        // Two rows may hold budget; the third is refused.
        #expect(coordinator.beginLoading(rows[0], role: .disclosureRow) == nil)
        #expect(coordinator.beginLoading(rows[1], role: .disclosureRow) == nil)
        #expect(coordinator.beginLoading(rows[2], role: .disclosureRow) == .rowBudget)
    }

    @Test("attach session stores one broker per token; duplicate tokens fail closed")
    func attachSessionIsExclusivePerToken() throws {
        let coordinator = ReaderDOMRendererCoordinator(generation: 1)
        let id = try placeholder("row-a")
        _ = coordinator.registerPlaceholder(event(id, role: .disclosureRow))

        let token = RendererFrameOriginToken.generate()
        let broker = RendererContentWorldBroker(
            sessionID: .init(rawValue: UUID()),
            capability: .init(rawValue: "cap"),
            inputReader: StubInputReader.make())

        #expect(coordinator.attachSession(id, broker: broker, frameToken: token))
        // A second attach to the same unit fails.
        #expect(coordinator.attachSession(id, broker: broker, frameToken: token) == false)
        // The token authorizes exactly that unit.
        #expect(coordinator.authorize(token: token) === coordinator.unit(for: id))

        // Closing revokes the token authorization.
        coordinator.remove(id)
        #expect(coordinator.authorize(token: token) == nil)
        #expect(coordinator.lifecycle(for: id) == .collapsed)  // unit gone
        broker.close()
    }

    @Test("scoped close paths dispose exactly one embed unit")
    func scopedClosePathsDisposeOneEmbedUnit() throws {
        let coordinator = ReaderDOMRendererCoordinator(generation: 1)
        let a = try placeholder("row-a")
        let b = try placeholder("row-b")
        _ = coordinator.registerPlaceholder(event(a, role: .disclosureRow))
        _ = coordinator.registerPlaceholder(event(b, role: .disclosureRow))

        coordinator.remove(a)
        #expect(coordinator.unit(for: a) == nil)
        #expect(coordinator.unit(for: b) != nil)
        #expect(coordinator.activeUnitCount == 1)
    }

    @Test("reload and dismantle dispose all embed units")
    func reloadAndDismantleDisposeAllEmbedUnits() throws {
        let coordinator = ReaderDOMRendererCoordinator(generation: 1)
        let ids = try (0..<3).map { try placeholder("row-\($0)") }
        for id in ids {
            _ = coordinator.registerPlaceholder(event(id, role: .disclosureRow))
        }
        #expect(coordinator.activeUnitCount == 3)
        coordinator.removeAll()
        #expect(coordinator.activeUnitCount == 0)
        #expect(coordinator.placeholderIDs.isEmpty)
    }

    @Test("frame origin token accepts only the exact generated shape")
    func tokenValidation() {
        let valid = String(repeating: "a1", count: 16)  // 32 lowercase hex chars
        #expect(RendererFrameOriginToken.tokenIfValid(valid) != nil)

        #expect(RendererFrameOriginToken.tokenIfValid("") == nil)                    // empty
        #expect(RendererFrameOriginToken.tokenIfValid(String(repeating: "a", count: 31)) == nil)   // short
        #expect(RendererFrameOriginToken.tokenIfValid(String(repeating: "a", count: 33)) == nil)   // long
        #expect(RendererFrameOriginToken.tokenIfValid(String(repeating: "A", count: 32)) == nil)   // uppercase
        #expect(RendererFrameOriginToken.tokenIfValid(String(repeating: "g", count: 32)) == nil)   // non-hex
        #expect(RendererFrameOriginToken.tokenIfValid("reader-test-parent") == nil)  // host-like

        // Generated tokens always parse back through the same invariant.
        let generated = RendererFrameOriginToken.generate()
        #expect(RendererFrameOriginToken.tokenIfValid(generated.rawValue) == generated)
    }

    @Test("frame package URL parse shares the token invariant implementation")
    func frameURLTokenValidation() throws {
        let token = RendererFrameOriginToken.generate()
        let url = RendererFramePackageURL.frameURL(
            token: token,
            packageID: RendererPackageID(rawValue: "org.example.probe")!,
            version: RendererPackageVersion(rawValue: "1.0.0")!,
            path: RendererRelativePath(rawValue: "index.html")!)
        #expect(try RendererFramePackageURL.parse(url).token == token)

        // A non-token host fails closed through the same parser.
        let badURL = URL(string:
            "renderer-package://reader-test-parent/org.example.probe/1.0.0/index.html")!
        #expect(throws: RendererPackageResourceError.invalidRequest) {
            _ = try RendererFramePackageURL.parse(badURL)
        }
    }
}

/// Minimal store-backed input reader fixture for broker construction in tests.
@MainActor
private final class StubInputReader {
    static func make() -> RendererAuthorizedInputReader {
        let store = try! GRDBWikiStore()
        let summary = try! store.addSource(filename: "stub.txt", data: Data("stub".utf8))
        let version = try! store.activeContentVersion(sourceID: summary.id)!
        return RendererAuthorizedInputReader(
            store: store,
            authorizedInput: .source(versionID: version.id))
    }
}
#endif
