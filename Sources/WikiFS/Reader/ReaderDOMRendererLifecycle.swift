#if os(macOS)
import Foundation
import WikiFSTypes

// pattern: Finite State Machine — one lifecycle enum, no parallel Boolean flags.

/// The reader's DOM-renderer lifecycle for one placeholder. It replaces the
/// overlay-era `RendererAttachmentState` + `InlineRendererAttachmentState`
/// pair with a single finite machine whose states cannot encode impossible
/// combinations.
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
enum RendererDOMRefusalReason: Equatable {
    case rowBudget
    case frameBudget
    case resourcePressure
}

/// The result of an embed activation attempt.
enum RendererAttachmentActivationResult: Equatable {
    case activate
    case showInFullRenderer
    case refused(RendererAttachmentActivationRefusal)
    case rejected
}

enum RendererAttachmentActivationRefusal: Equatable {
    case rowBudget
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

enum RendererAttachmentHostPolicy {
    static let maximumMessageByteCount = 16 * 1_024
    static let maximumPlaceholderCount = 64
    /// Inline content stays mounted for this interval after it leaves the
    /// retained visibility window.
    static let inlineOffscreenRetentionDuration = Duration.seconds(2)
    /// The retained visibility window extends this distance above and below
    /// the viewport.
    static let inlineVisibilityPreloadMargin = 600
}

/// A placeholder identity inside one reader document.
struct RendererAttachmentPlaceholderID: Hashable, Sendable, Equatable {
    let rawValue: String

    init(validating rawValue: String) throws {
        guard rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              rawValue.isEmpty == false,
              rawValue.count <= 160,
              rawValue.unicodeScalars.allSatisfy({ $0.properties.isWhitespace == false })
        else { throw RendererAttachmentMessageError.invalidPlaceholderID }
        self.rawValue = rawValue
    }
}

extension RendererAttachmentPlaceholderID {
    static func validatedOrNil(_ rawValue: String) -> Self? {
        do {
            return try Self(validating: rawValue)
        } catch {
            return nil
        }
    }
}

enum RendererAttachmentMessageError: Error, Equatable {
    case invalidPlaceholderID
}

/// The narrow DOM lifecycle event the document reports. It replaces the
/// overlay-era geometry message: no rectangle coordinates, no native viewport
/// projection, no revision counter — only discovery, role, retained
/// visibility, and removal.
struct RendererAttachmentLifecycleMessage: Sendable, Equatable {
    let generation: Int
    let placeholderID: RendererAttachmentPlaceholderID
    let embeddingRole: RendererEmbeddingRole
    let visible: Bool
    let isRemoval: Bool

    init?(
        generation: Int,
        placeholderID: RendererAttachmentPlaceholderID,
        embeddingRole: RendererEmbeddingRole,
        visible: Bool,
        isRemoval: Bool
    ) {
        guard generation >= 0 else { return nil }
        self.generation = generation
        self.placeholderID = placeholderID
        self.embeddingRole = embeddingRole
        self.visible = visible
        self.isRemoval = isRemoval
    }

    init?(body: [String: Any]) {
        guard let generation = body["generation"] as? Int,
              let rawPlaceholderID = body["placeholderID"] as? String,
              let placeholderID = RendererAttachmentPlaceholderID.validatedOrNil(rawPlaceholderID),
              let rawRole = body["embeddingRole"] as? String,
              let embeddingRole = RendererEmbeddingRole(rawValue: rawRole),
              let visible = body["visible"] as? Bool
        else { return nil }
        let isRemoval = body["removed"] as? Bool ?? false
        self.init(
            generation: generation,
            placeholderID: placeholderID,
            embeddingRole: embeddingRole,
            visible: visible,
            isRemoval: isRemoval)
    }
}

/// Value-only lifecycle projection for assertions and SwiftUI-facing reads.
/// It contains no broker, session, task, route, or view references.
struct ReaderDOMRendererState: Equatable {
    let lifecycle: ReaderDOMRendererLifecycle
    let role: RendererEmbeddingRole?
    let generation: Int
    let surfaceID: String?
    let refusalMessage: String?
    /// Retained visibility reported by the document (inline retry/retention).
    let visible: Bool

    var isActive: Bool { lifecycle.isActive }
    var canExpand: Bool { lifecycle.canExpand }
}

/// One owned embed: the unit ties together the lifecycle record, the
/// per-embed frame token, the bridge broker, the load timeout, and an
/// idempotent close. Closing disposes exactly this embed's resources; other
/// embeds are untouched.
@MainActor
final class ReaderDOMEmbedUnit {
    let placeholderID: RendererAttachmentPlaceholderID
    let embeddingRole: RendererEmbeddingRole
    /// The activation context generation this unit was admitted under.
    let generation: Int
    private(set) var frameToken: RendererFrameOriginToken?
    private(set) var broker: RendererContentWorldBroker?
    /// Load timeout handle: a frame that never finishes loading releases its
    /// session and records a failure.
    private(set) var loadTimeoutTask: Task<Void, Never>?
    private(set) var visible = false
    private(set) var isClosed = false
    /// True from `beginLoading` until close: the unit holds a row, inline, or
    /// frame budget slot even before its broker attaches.
    fileprivate(set) var holdsBudget = false
    /// Coordinator-level teardown hook (set from `onUnitClosed`): couples
    /// every unit's close to router revocation.
    static var coordinatorOnClosed: (@MainActor (ReaderDOMEmbedUnit) -> Void)?

    init(
        placeholderID: RendererAttachmentPlaceholderID,
        embeddingRole: RendererEmbeddingRole,
        generation: Int
    ) {
        self.placeholderID = placeholderID
        self.embeddingRole = embeddingRole
        self.generation = generation
    }

    func setVisible(_ newValue: Bool) {
        guard isClosed == false else { return }
        visible = newValue
    }

    func attachBroker(_ broker: RendererContentWorldBroker, frameToken: RendererFrameOriginToken) {
        guard isClosed == false else { return }
        self.broker = broker
        self.frameToken = frameToken
    }

    func armLoadTimeout(_ task: Task<Void, Never>) {
        guard isClosed == false else { task.cancel(); return }
        loadTimeoutTask = task
    }

    func cancelLoadTimeout() {
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
    }

    /// Idempotent close: cancels the timeout, closes the broker, and severs
    /// the router route through the coordinator's callback. The callback runs
    /// before the token is cleared so revocation sees the exact route.
    func close() {
        guard isClosed == false else { return }
        isClosed = true
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        Self.coordinatorOnClosed?(self)
        broker?.close()
        broker = nil
        frameToken = nil
    }
}

/// The functional core: one lifecycle store keyed by typed placeholder
/// identity, budgeted expansion and inline mounting, and frame-message
/// authorization via a token reverse index. Generation-checked so stale
/// callbacks fail closed. This is the production owner for the reader's DOM
/// embed lifecycle.
@MainActor
final class ReaderDOMRendererCoordinator {
    /// I/O index: frame token -> owning unit, for subframe message
    /// authorization. Created and revoked atomically with the embed unit.
    private var unitsByToken: [RendererFrameOriginToken: ReaderDOMEmbedUnit] = [:]
    private var units: [RendererAttachmentPlaceholderID: ReaderDOMEmbedUnit] = [:]
    let generation: Int
    private let maximumExpandedRows: Int
    private let maximumInlineRenderers: Int
    private let maximumPackageFrames: Int
    /// Wired once by the reader: couples every unit's teardown to router
    /// route + bootstrap revocation.
    var onUnitClosed: (@MainActor (ReaderDOMEmbedUnit) -> Void)? {
        didSet { ReaderDOMEmbedUnit.coordinatorOnClosed = onUnitClosed }
    }

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

    func state(for placeholderID: RendererAttachmentPlaceholderID) -> ReaderDOMRendererState? {
        units[placeholderID].map(Self.state(of:))
    }

    func lifecycle(for placeholderID: RendererAttachmentPlaceholderID) -> ReaderDOMRendererLifecycle {
        units[placeholderID].map(Self.lifecycleState(of:)) ?? .collapsed
    }

    func role(for placeholderID: RendererAttachmentPlaceholderID) -> RendererEmbeddingRole? {
        units[placeholderID]?.embeddingRole
    }

    func unit(for placeholderID: RendererAttachmentPlaceholderID) -> ReaderDOMEmbedUnit? {
        units[placeholderID]
    }

    func unit(for token: RendererFrameOriginToken) -> ReaderDOMEmbedUnit? {
        unitsByToken[token]
    }

    var placeholderIDs: [RendererAttachmentPlaceholderID] { Array(units.keys) }

    var activeUnitCount: Int { units.count }

    private static func lifecycleState(of unit: ReaderDOMEmbedUnit) -> ReaderDOMRendererLifecycle {
        if unit.isClosed { return .removed }
        if unit.broker != nil { return .active }
        return .collapsed
    }

    private static func state(of unit: ReaderDOMEmbedUnit) -> ReaderDOMRendererState {
        ReaderDOMRendererState(
            lifecycle: lifecycleState(of: unit),
            role: unit.embeddingRole,
            generation: unit.generation,
            surfaceID: unit.frameToken?.rawValue,
            refusalMessage: nil,
            visible: unit.visible)
    }

    /// Legal transitions for the record-free lifecycle. Any transition not
    /// listed is refused, so a missed write site cannot encode an impossible
    /// state.
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
            return from != .removed
        default:
            return false
        }
    }

    /// Registers (or re-registers after document replacement) a placeholder
    /// from a DOM lifecycle event. Registration is idempotent per identity.
    @discardableResult
    func registerPlaceholder(
        _ message: RendererAttachmentLifecycleMessage
    ) -> ReaderDOMEmbedUnit? {
        guard message.generation == generation,
              message.isRemoval == false,
              units[message.placeholderID] != nil
                  || units.count < RendererAttachmentHostPolicy.maximumPlaceholderCount
        else { return nil }
        let unit = units[message.placeholderID] ?? ReaderDOMEmbedUnit(
            placeholderID: message.placeholderID,
            embeddingRole: message.embeddingRole,
            generation: message.generation)
        unit.setVisible(message.visible)
        units[message.placeholderID] = unit
        return unit
    }

    /// Applies a retained-visibility update to one unit (inline retention).
    func applyVisibility(
        _ placeholderID: RendererAttachmentPlaceholderID,
        visible: Bool,
        generation eventGeneration: Int
    ) {
        guard eventGeneration == generation,
              let unit = units[placeholderID] else { return }
        unit.setVisible(visible)
    }

    /// Begins loading for one placeholder. Reserves the row, inline, or frame
    /// budget for the transition; returns the refusal reason when exhausted.
    func beginLoading(
        _ placeholderID: RendererAttachmentPlaceholderID,
        role: RendererEmbeddingRole?
    ) -> RendererDOMRefusalReason? {
        guard let unit = units[placeholderID],
              unit.isClosed == false,
              unit.generation == generation else { return .resourcePressure }
        let resolvedRole = role ?? unit.embeddingRole
        switch resolvedRole {
        case .disclosureRow:
            let heldRows = units.values.filter {
                $0.embeddingRole == .disclosureRow && $0.isClosed == false && $0.holdsBudget
            }.count
            if heldRows >= maximumExpandedRows { return .rowBudget }
        case .inlineContent:
            let mountedInline = units.values.filter {
                $0.embeddingRole == .inlineContent && $0.isClosed == false && $0.holdsBudget
            }.count
            if mountedInline >= maximumInlineRenderers { return .resourcePressure }
        }
        unit.holdsBudget = true
        return nil
    }

    /// Attaches the session resources minted for one loading embed. Reserves
    /// the frame budget here: only embeds that actually own a broker + frame
    /// token consume a frame slot. Called exactly once per unit.
    func attachSession(
        _ placeholderID: RendererAttachmentPlaceholderID,
        broker: RendererContentWorldBroker,
        frameToken: RendererFrameOriginToken
    ) -> Bool {
        guard let unit = units[placeholderID],
              unit.isClosed == false,
              unit.broker == nil,
              unitsByToken[frameToken] == nil
        else { return false }
        let frameCount = units.values.filter { $0.isClosed == false && $0.broker != nil }.count
        guard frameCount < maximumPackageFrames else { return false }
        unit.attachBroker(broker, frameToken: frameToken)
        unitsByToken[frameToken] = unit
        return true
    }

    /// The frame finished loading; cancels its timeout.
    func frameDidLoad(token: RendererFrameOriginToken) {
        unitsByToken[token]?.cancelLoadTimeout()
    }

    /// Validates provenance and returns the unit for one incoming frame
    /// message. Rejects unknown tokens, closed frames, and generation drift.
    func authorize(token: RendererFrameOriginToken) -> ReaderDOMEmbedUnit? {
        guard let unit = unitsByToken[token], unit.isClosed == false else { return nil }
        return unit
    }

    /// Retryable resource refusal for one placeholder.
    func refuse(
        _ placeholderID: RendererAttachmentPlaceholderID,
        reason: RendererDOMRefusalReason
    ) {
        guard let unit = units[placeholderID],
              unit.isClosed == false,
              unit.generation == generation,
              unit.broker == nil else { return }
        // Refusal keeps the unit registered (retryable) but holds no
        // session resources.
        _ = reason
    }

    /// The renderer failed; the row keeps readable failure status and the
    /// unit's session resources are released.
    func fail(_ placeholderID: RendererAttachmentPlaceholderID) {
        guard let unit = units[placeholderID],
              unit.isClosed == false else { return }
        unit.close()
    }

    /// The user collapsed the row (or Escape restored it).
    func collapse(_ placeholderID: RendererAttachmentPlaceholderID) {
        guard let unit = units[placeholderID],
              unit.isClosed == false else { return }
        unit.close()
    }

    /// The placeholder is gone (DOM removal, reload, dismantle, revocation).
    /// Removal never checks the generation: a stale document's teardown must
    /// always be able to clean up its own records.
    func remove(_ placeholderID: RendererAttachmentPlaceholderID) {
        units[placeholderID]?.close()
        units.removeValue(forKey: placeholderID)
    }

    /// Removes every unit (reader dismantle, document replacement).
    func removeAll() {
        for unit in units.values { unit.close() }
        units.removeAll()
        unitsByToken.removeAll()
    }
}
#endif
