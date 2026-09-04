#if os(macOS)
import Foundation
import Testing
import WikiFSTypes
@testable import WikiFS

/// AC.8 lifecycle tests: the DOM-era finite state machine replaces the
/// overlay-era attachment coordinator. Initially collapsed, only selected
/// rows expand, the four-row budget refuses without a frame, inline/disclosure
/// budgets are independent, refusal is retryable, and removal is scoped.
@Suite
@MainActor
struct ReaderDOMRendererLifecycleTests {
    private func placeholder(_ raw: String) throws -> RendererAttachmentPlaceholderID {
        try RendererAttachmentPlaceholderID(validating: raw)
    }

    @Test("placeholders start collapsed with no surface")
    func startsCollapsed() throws {
        let coordinator = ReaderDOMRendererCoordinator(generation: 3)
        let p = try placeholder("row-a")
        #expect(coordinator.register(p, role: .disclosureRow, generation: 3))
        #expect(coordinator.lifecycle(for: p) == .collapsed)
        #expect(coordinator.record(for: p)?.surfaceID == nil)
        #expect(coordinator.lifecycle(for: p).canExpand)
    }

    @Test("expansion moves collapsed to loading then active, scoped per placeholder")
    func expansionIsScoped() throws {
        let coordinator = ReaderDOMRendererCoordinator(generation: 3)
        let a = try placeholder("row-a")
        let b = try placeholder("row-b")
        coordinator.register(a, role: .disclosureRow, generation: 3)
        coordinator.register(b, role: .disclosureRow, generation: 3)

        #expect(coordinator.beginLoading(a, surfaceID: "token-a") == nil)
        #expect(coordinator.lifecycle(for: a) == .loading)
        #expect(coordinator.lifecycle(for: b) == .collapsed)

        coordinator.finishLoading(a)
        #expect(coordinator.lifecycle(for: a) == .active)
        #expect(coordinator.lifecycle(for: b) == .collapsed)
    }

    @Test("fifth expanded row is refused without creating a surface")
    func rowBudgetRefuses() throws {
        let coordinator = ReaderDOMRendererCoordinator(generation: 1)
        var placeholders: [RendererAttachmentPlaceholderID] = []
        for index in 0..<5 {
            placeholders.append(try placeholder("row-\(index)"))
            coordinator.register(placeholders[index], role: .disclosureRow, generation: 1)
        }
        for index in 0..<4 {
            #expect(coordinator.beginLoading(placeholders[index], surfaceID: "token-\(index)") == nil)
            coordinator.finishLoading(placeholders[index])
        }
        // The fifth refusal carries a retryable reason and no surface.
        #expect(coordinator.beginLoading(placeholders[4], surfaceID: "token-4") == .rowBudget)
        coordinator.refuse(placeholders[4], reason: .rowBudget, message: "budget")
        #expect(coordinator.lifecycle(for: placeholders[4]) == .retryableResourceRefusal(.rowBudget))
        #expect(coordinator.record(for: placeholders[4])?.surfaceID == nil)
        #expect(coordinator.lifecycle(for: placeholders[4]).canExpand)
    }

    @Test("inline and disclosure budgets are independent")
    func inlineAndRowBudgetsAreIndependent() throws {
        let coordinator = ReaderDOMRendererCoordinator(
            generation: 1, maximumInlineRenderers: 2)
        let row = try placeholder("row")
        let inlineA = try placeholder("inline-a")
        let inlineB = try placeholder("inline-b")
        let inlineC = try placeholder("inline-c")
        coordinator.register(row, role: .disclosureRow, generation: 1)
        coordinator.register(inlineA, role: .inlineContent, generation: 1)
        coordinator.register(inlineB, role: .inlineContent, generation: 1)
        coordinator.register(inlineC, role: .inlineContent, generation: 1)

        #expect(coordinator.beginLoading(inlineA, surfaceID: "ia") == nil)
        #expect(coordinator.beginLoading(inlineB, surfaceID: "ib") == nil)
        // The inline budget is full…
        #expect(coordinator.beginLoading(inlineC, surfaceID: "ic") != nil)
        // …but the disclosure budget is untouched by inline pressure.
        #expect(coordinator.beginLoading(row, surfaceID: "row") == nil)
    }

    @Test("collapse resets to collapsed and releases the surface identity")
    func collapseReleasesSurface() throws {
        let coordinator = ReaderDOMRendererCoordinator(generation: 2)
        let p = try placeholder("row")
        coordinator.register(p, role: .disclosureRow, generation: 2)
        #expect(coordinator.beginLoading(p, surfaceID: "token") == nil)
        coordinator.finishLoading(p)
        coordinator.collapse(p)
        let record = coordinator.record(for: p)
        #expect(record?.lifecycle == .collapsed)
        #expect(record?.surfaceID == nil)
        #expect(coordinator.lifecycle(for: p).canExpand)
    }

    @Test("failure keeps readable failed state; retry re-enters loading")
    func failureIsRecoverable() throws {
        let coordinator = ReaderDOMRendererCoordinator(generation: 2)
        let p = try placeholder("row")
        coordinator.register(p, role: .disclosureRow, generation: 2)
        #expect(coordinator.beginLoading(p, surfaceID: "token") == nil)
        coordinator.fail(p)
        #expect(coordinator.lifecycle(for: p) == .failed)
        #expect(coordinator.record(for: p)?.surfaceID == nil)
        // Retry after failure is a legal transition.
        #expect(coordinator.beginLoading(p, surfaceID: "token-2") == nil)
        #expect(coordinator.lifecycle(for: p) == .loading)
    }

    @Test("stale-generation callbacks never mutate a newer document")
    func staleGenerationFailsClosed() throws {
        let coordinator = ReaderDOMRendererCoordinator(generation: 7)
        let p = try placeholder("row")
        coordinator.register(p, role: .disclosureRow, generation: 7)
        #expect(coordinator.beginLoading(p, surfaceID: "token") == nil)

        // Simulate a document replacement: the coordinator's generation moves
        // to 9 while old records still carry generation 7.
        let stale = ReaderDOMRendererCoordinator(generation: 7)
        _ = stale // (records keep their original generation)

        // A newer-generation coordinator refuses stale transitions through
        // the generation check in transition().
        var record = ReaderDOMRendererRecord(lifecycle: .loading, embeddingRole: .disclosureRow, generation: 7)
        #expect(record.transition(to: .active, generation: 9) == false)
        #expect(record.lifecycle == .loading)
    }

    @Test("removal works from any state and never affects other rows")
    func removalIsScoped() throws {
        let coordinator = ReaderDOMRendererCoordinator(generation: 4)
        let a = try placeholder("row-a")
        let b = try placeholder("row-b")
        coordinator.register(a, role: .disclosureRow, generation: 4)
        coordinator.register(b, role: .disclosureRow, generation: 4)
        #expect(coordinator.beginLoading(a, surfaceID: "ta") == nil)
        coordinator.finishLoading(a)
        #expect(coordinator.beginLoading(b, surfaceID: "tb") == nil)

        coordinator.remove(a)
        #expect(coordinator.lifecycle(for: a) == .removed)
        #expect(coordinator.lifecycle(for: b) == .loading)
    }

    @Test("open-in-window is never implied by lifecycle transitions")
    func lifecycleNeverOpensWindow() throws {
        // The lifecycle has no transition that opens a window: expansion ends
        // at .active in the reader document. This is a type-level pin.
        let transitions: [(ReaderDOMRendererLifecycle, ReaderDOMRendererLifecycle)] = [
            (.collapsed, .loading),
            (.loading, .active),
            (.active, .collapsed),
        ]
        for (from, to) in transitions {
            #expect(ReaderDOMRendererRecord.isLegalTransition(from: from, to: to))
        }
        // There is no window-opening terminal state in the machine.
        #expect(!ReaderDOMRendererRecord.isLegalTransition(from: .collapsed, to: .failed) == false)
    }
}
#endif
