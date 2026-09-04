#if os(macOS)
import Foundation
import WikiFSTypes

// pattern: Finite State Machine — one lifecycle enum, no parallel Boolean flags.

/// The reader's DOM-renderer lifecycle for one placeholder. It replaces the
/// overlay-era `RendererAttachmentState` + `InlineRendererAttachmentState`
/// pair with a single finite machine whose states cannot encode impossible
/// combinations.
@MainActor
enum ReaderDOMRendererLifecycle: Equatable {
    /// The disclosure row is collapsed; no frame exists.
    case collapsed
    /// The user expanded the row; the frame/element is loading in the DOM.
    case loading
    /// The frame/element finished loading and is active in the document flow.
    case active
    /// Activation was refused for a retryable resource reason (row budget,
    /// frame budget). The row stays collapsed with a status message.
    case retryableResourceRefusal(RendererDOMRefusalReason)
    /// The renderer failed; the row shows a readable failure status.
    case failed
    /// The row was closed/removed; its DOM surface is gone and its bridge
    /// session is released.
    case removed

    var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    var canExpand: Bool {
        switch self {
        case .collapsed, .retryableResourceRefusal, .failed:
            return true
        case .loading, .active, .removed:
            return false
        }
    }
}

/// Why activation was refused. Retryable: the user can try again after
/// collapsing another row.
@MainActor
enum RendererDOMRefusalReason: Equatable {
    case rowBudget
    case frameBudget
    case resourcePressure
}

/// Per-document product budgets, unchanged from the overlay era. The
/// four-expanded-row budget and the six-inline-renderer budget are distinct
/// role semantics the tests pin separately; they are not consolidated.
enum ReaderDOMRendererBudget {
    static let maximumExpandedRows = 4
    static let maximumInlineRenderers = 6
    /// Bounded concurrent package frames per reader document. Equivalent to
    /// the era when each inline renderer owned a separate WKWebView permit.
    static let maximumPackageFrames = 6
    /// A package frame must finish loading within this interval or its
    /// lifecycle fails and its bridge session is released.
    static let frameLoadTimeout: Duration = .seconds(30)
}

/// One placeholder's machine record. The coordinator owns the map; values are
/// value types so every transition is a single assignment.
@MainActor
struct ReaderDOMRendererRecord: Equatable {
    var lifecycle: ReaderDOMRendererLifecycle = .collapsed
    var embeddingRole: RendererEmbeddingRole?
    /// The placeholder's activation context generation. A stale callback
    /// (older generation) must never mutate a newer document's state.
    var generation: Int = 0
    /// The DOM surface identity (frame token or element id) once loading.
    var surfaceID: String?
    var refusalMessage: String?

    mutating func transition(
        to next: ReaderDOMRendererLifecycle,
        generation currentGeneration: Int
    ) -> Bool {
        guard generation == currentGeneration else { return false }
        guard Self.isLegalTransition(from: lifecycle, to: next) else { return false }
        lifecycle = next
        return true
    }

    /// Legal transitions. Any transition not listed is a no-op and returns
    /// false, so a missed write site cannot encode an impossible state.
    static func isLegalTransition(
        from: ReaderDOMRendererLifecycle,
        to: ReaderDOMRendererLifecycle
    ) -> Bool {
        switch (from, to) {
        case (.collapsed, .loading),
             (.collapsed, .retryableResourceRefusal(.rowBudget)),
             (.collapsed, .retryableResourceRefusal(.frameBudget)),
             (.collapsed, .retryableResourceRefusal(.resourcePressure)),
             (.collapsed, .failed),
             (.loading, .active),
             (.loading, .failed),
             (.loading, .collapsed),
             (.active, .collapsed),
             (.active, .failed),
             (.retryableResourceRefusal, .loading),
             (.retryableResourceRefusal, .collapsed),
             (.failed, .loading),
             (.failed, .collapsed):
            return true
        case (_, .removed):
            // Removal is legal from any non-removed state (document
            // replacement, reload, dismantle, revocation).
            return from != .removed
        default:
            return false
        }
    }
}

/// The functional core: a map of placeholder records with budgeted expansion
/// and inline mounting, generation-checked so stale callbacks fail closed.
/// This is the DOM-era replacement for `RendererAttachmentCoordinator`.
@MainActor
final class ReaderDOMRendererCoordinator {
    private var records: [RendererAttachmentPlaceholderID: ReaderDOMRendererRecord] = [:]
    let generation: Int
    private let maximumExpandedRows: Int
    private let maximumInlineRenderers: Int
    private let maximumPackageFrames: Int

    init(
        generation: Int,
        maximumExpandedRows: Int = ReaderDOMRendererBudget.maximumExpandedRows,
        maximumInlineRenderers: Int = ReaderDOMRendererBudget.maximumInlineRenderers,
        maximumPackageFrames: Int = ReaderDOMRendererBudget.maximumPackageFrames
    ) {
        self.generation = generation
        self.maximumExpandedRows = max(0, maximumExpandedRows)
        self.maximumInlineRenderers = max(0, maximumInlineRenderers)
        self.maximumPackageFrames = max(0, maximumPackageFrames)
    }

    func lifecycle(for placeholderID: RendererAttachmentPlaceholderID) -> ReaderDOMRendererLifecycle {
        records[placeholderID]?.lifecycle ?? .collapsed
    }

    func record(for placeholderID: RendererAttachmentPlaceholderID) -> ReaderDOMRendererRecord? {
        records[placeholderID]
    }

    var placeholderIDs: [RendererAttachmentPlaceholderID] { Array(records.keys) }

    /// Registers (or re-registers after document replacement) a placeholder at
    /// its initial collapsed state. Returns false if the map is full.
    @discardableResult
    func register(
        _ placeholderID: RendererAttachmentPlaceholderID,
        role: RendererEmbeddingRole,
        generation documentGeneration: Int
    ) -> Bool {
        guard records.count < RendererAttachmentHostPolicy.maximumPlaceholderCount
                || records[placeholderID] != nil
        else { return false }
        records[placeholderID] = ReaderDOMRendererRecord(
            lifecycle: .collapsed,
            embeddingRole: role,
            generation: documentGeneration)
        return true
    }

    /// Begins loading for one placeholder. Returns the refusal reason when the
    /// row or frame budget is exhausted; returns nil when loading may proceed.
    func beginLoading(
        _ placeholderID: RendererAttachmentPlaceholderID,
        surfaceID: String
    ) -> RendererDOMRefusalReason? {
        guard var record = records[placeholderID],
              record.lifecycle.canExpand,
              record.generation == generation
        else { return .resourcePressure }
        let role = record.embeddingRole ?? .disclosureRow
        switch role {
        case .disclosureRow:
            // Loading and active rows both hold a row slot: a collapsed-but-
            // loading row is not available to a new expansion.
            let heldRows = records.values.filter {
                $0.embeddingRole == .disclosureRow && $0.lifecycle != .collapsed && $0.lifecycle != .removed
            }.count
            if heldRows >= maximumExpandedRows { return .rowBudget }
        case .inlineContent:
            let mountedInline = records.values.filter {
                $0.embeddingRole == .inlineContent && $0.lifecycle != .collapsed && $0.lifecycle != .removed
            }.count
            if mountedInline >= maximumInlineRenderers { return .resourcePressure }
        }
        let frameCount = records.values.filter {
            $0.surfaceID != nil && ($0.lifecycle == .loading || $0.lifecycle.isActive)
        }.count
        if frameCount >= maximumPackageFrames { return .frameBudget }
        record.surfaceID = surfaceID
        guard record.transition(to: .loading, generation: generation) else {
            return .resourcePressure
        }
        records[placeholderID] = record
        return nil
    }

    /// The frame/element finished loading.
    func finishLoading(_ placeholderID: RendererAttachmentPlaceholderID) {
        guard var record = records[placeholderID],
              record.lifecycle == .loading,
              record.generation == generation
        else { return }
        _ = record.transition(to: .active, generation: generation)
        records[placeholderID] = record
    }

    /// The user collapsed the row (or Escape restored it).
    func collapse(_ placeholderID: RendererAttachmentPlaceholderID) {
        guard var record = records[placeholderID],
              record.generation == generation else { return }
        guard record.transition(to: .collapsed, generation: generation) else { return }
        record.surfaceID = nil
        record.refusalMessage = nil
        records[placeholderID] = record
    }

    /// Activation was refused for a retryable resource reason.
    func refuse(
        _ placeholderID: RendererAttachmentPlaceholderID,
        reason: RendererDOMRefusalReason,
        message: String
    ) {
        guard var record = records[placeholderID],
              record.generation == generation else { return }
        guard record.transition(to: .retryableResourceRefusal(reason), generation: generation) else { return }
        record.refusalMessage = message
        record.surfaceID = nil
        records[placeholderID] = record
    }

    /// The renderer failed; the row keeps readable failure status.
    func fail(_ placeholderID: RendererAttachmentPlaceholderID) {
        guard var record = records[placeholderID],
              record.generation == generation,
              record.lifecycle != .removed else { return }
        _ = record.transition(to: .failed, generation: generation)
        record.surfaceID = nil
        records[placeholderID] = record
    }

    /// The placeholder is gone (DOM removal, reload, dismantle, revocation).
    /// Removal never checks the generation: a stale document's teardown must
    /// always be able to clean up its own records.
    func remove(_ placeholderID: RendererAttachmentPlaceholderID) {
        guard var record = records[placeholderID] else { return }
        _ = record.transition(to: .removed, generation: record.generation)
        record.surfaceID = nil
        records[placeholderID] = record
    }

    /// Removes every record (reader dismantle, document replacement).
    func removeAll() {
        records.removeAll()
    }
}
#endif
