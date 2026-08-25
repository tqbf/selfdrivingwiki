#if os(macOS)
import CoreGraphics
import Foundation
import WikiFSTypes

// pattern: Functional Core — bounded attachment state and geometry are deterministic values.

enum RendererAttachmentHostPolicy {
    static let maximumMessageByteCount = 16 * 1_024
    static let maximumPlaceholderCount = 64
    static let maximumUpdatesPerPlaceholder = 1_024
    static let maximumCoordinateMagnitude = 1_000_000.0
    static let minimumReservedHeight = 96.0
    static let maximumReservedHeight = 1_200.0
    /// Per-document row policy; unrelated to inline content and the process-wide WebKit pool.
    static let maximumExpandedRendererRows = 4
    /// Per-document inline policy; unrelated to disclosure rows and the process-wide WebKit pool.
    static let maximumMountedInlineRenderers = 6
    /// Inline content stays mounted for this interval after it leaves the retained visibility window.
    static let inlineOffscreenRetentionDuration = Duration.seconds(2)
    /// The retained visibility window extends this distance above and below the viewport.
    static let inlineVisibilityPreloadMargin = 600
    static let jsonCanvasReservedHeight = 480.0

    static func preferredReservedHeight(for renderer: RendererReference?) -> CGFloat {
        renderer == BuiltInRendererReference.reference(for: .jsonCanvas)
            ? jsonCanvasReservedHeight
            : minimumReservedHeight
    }
}

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

struct RendererAttachmentGeometryMessage: Sendable, Equatable {
    let generation: Int
    let placeholderID: RendererAttachmentPlaceholderID
    let embeddingRole: RendererEmbeddingRole
    let cssRect: CGRect
    let visible: Bool
    let revision: Int

    init(
        generation: Int,
        placeholderID: RendererAttachmentPlaceholderID,
        embeddingRole: RendererEmbeddingRole = .disclosureRow,
        cssRect: CGRect,
        visible: Bool,
        revision: Int
    ) {
        self.generation = generation
        self.placeholderID = placeholderID
        self.embeddingRole = embeddingRole
        self.cssRect = cssRect
        self.visible = visible
        self.revision = revision
    }

    init?(body: [String: Any]) {
        guard let generation = body["generation"] as? Int,
              let rawPlaceholderID = body["placeholderID"] as? String,
              let placeholderID = RendererAttachmentPlaceholderID.validatedOrNil(rawPlaceholderID),
              let x = Self.number(body["x"]), let y = Self.number(body["y"]),
              let width = Self.number(body["width"]), let height = Self.number(body["height"]),
              let visible = body["visible"] as? Bool,
              let rawRole = body["embeddingRole"] as? String,
              let embeddingRole = RendererEmbeddingRole(rawValue: rawRole),
              let revision = body["revision"] as? Int
        else { return nil }
        let cssRect = CGRect(x: x, y: y, width: width, height: height)
        guard cssRect.isFiniteRect else { return nil }
        self.generation = generation
        self.placeholderID = placeholderID
        self.embeddingRole = embeddingRole
        self.cssRect = cssRect
        self.visible = visible
        self.revision = revision
    }

    private static func number(_ value: Any?) -> CGFloat? {
        if let value = value as? CGFloat, value.isFinite { return value }
        if let value = value as? Double, value.isFinite { return CGFloat(value) }
        if let value = value as? Int { return CGFloat(value) }
        return nil
    }
}

enum RendererAttachmentMessageError: Error, Equatable {
    case invalidPlaceholderID
}

enum RendererAttachmentGeometry {
    static func overlayRect(cssRect: CGRect, pageZoom: CGFloat, readerBounds: CGRect) -> CGRect {
        guard cssRect.isFiniteRect, pageZoom.isFinite, pageZoom > 0 else { return .zero }
        let x = cssRect.minX * pageZoom
        let y = readerBounds.height - cssRect.maxY * pageZoom
        return CGRect(x: x, y: y, width: cssRect.width * pageZoom, height: cssRect.height * pageZoom)
    }

    static func clip(rect: CGRect, to readerBounds: CGRect) -> CGRect {
        rect.intersection(readerBounds)
    }
}

enum RendererAttachmentState: Equatable {
    case unresolved
    case card
    case active
    case failed
    case closed
}

enum InlineRendererAttachmentState: Equatable {
    case fallback
    case eligible
    case waitingForResources
    case mounted
    case failed
    case removed
}

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

@MainActor
final class RendererAttachmentCoordinator {
    private struct Record {
        var role: RendererEmbeddingRole?
        var state: RendererAttachmentState = .unresolved
        var inlineState: InlineRendererAttachmentState = .fallback
        var latestRevision = -1
        var updateCount = 0
        var reservedHeight = RendererAttachmentHostPolicy.minimumReservedHeight
        var latestGeometry: RendererAttachmentGeometryMessage?
        var activationRefusal: RendererAttachmentActivationRefusal?
    }

    let generation: Int
    private let rowActiveLimit: Int
    private let inlineActiveLimit: Int
    private var records: [RendererAttachmentPlaceholderID: Record] = [:]

    init(
        generation: Int,
        activeLimit: Int = RendererAttachmentHostPolicy.maximumExpandedRendererRows,
        inlineActiveLimit: Int = RendererAttachmentHostPolicy.maximumMountedInlineRenderers
    ) {
        self.generation = generation
        self.rowActiveLimit = max(0, activeLimit)
        self.inlineActiveLimit = max(0, inlineActiveLimit)
    }

    func state(for placeholderID: RendererAttachmentPlaceholderID) -> RendererAttachmentState {
        records[placeholderID]?.state ?? .unresolved
    }

    func inlineState(for placeholderID: RendererAttachmentPlaceholderID) -> InlineRendererAttachmentState {
        records[placeholderID]?.inlineState ?? .fallback
    }

    func role(for placeholderID: RendererAttachmentPlaceholderID) -> RendererEmbeddingRole? {
        records[placeholderID]?.role
    }

    @discardableResult
    func ingest(_ message: RendererAttachmentGeometryMessage) -> Bool {
        guard message.generation == generation,
              isValid(message.cssRect),
              message.revision >= 0,
              records[message.placeholderID] != nil || records.count < RendererAttachmentHostPolicy.maximumPlaceholderCount
        else { return false }

        var record = records[message.placeholderID] ?? Record()
        guard record.state != .closed,
              record.inlineState != .removed,
              record.role == nil || record.role == message.embeddingRole,
              message.revision > record.latestRevision,
              record.updateCount < RendererAttachmentHostPolicy.maximumUpdatesPerPlaceholder
        else { return false }
        record.role = message.embeddingRole
        record.latestRevision = message.revision
        record.updateCount += 1
        record.latestGeometry = message
        switch message.embeddingRole {
        case .disclosureRow:
            if record.state == .unresolved { record.state = .card }
        case .inlineContent:
            if record.inlineState == .fallback, message.visible {
                record.inlineState = .eligible
            } else if record.inlineState == .eligible, !message.visible {
                record.inlineState = .fallback
            }
        }
        records[message.placeholderID] = record
        return true
    }

    func geometry(for placeholderID: RendererAttachmentPlaceholderID) -> RendererAttachmentGeometryMessage? {
        records[placeholderID]?.latestGeometry
    }

    var placeholderIDs: [RendererAttachmentPlaceholderID] { Array(records.keys) }

    func activationRefusal(for placeholderID: RendererAttachmentPlaceholderID) -> RendererAttachmentActivationRefusal? {
        records[placeholderID]?.activationRefusal
    }

    func reserveHeight(_ requested: CGFloat, for placeholderID: RendererAttachmentPlaceholderID) -> CGFloat {
        let height = min(
            RendererAttachmentHostPolicy.maximumReservedHeight,
            max(RendererAttachmentHostPolicy.minimumReservedHeight, requested.isFinite ? requested : RendererAttachmentHostPolicy.minimumReservedHeight))
        var record = records[placeholderID] ?? Record()
        guard record.state != .closed else { return record.reservedHeight }
        record.reservedHeight = height
        records[placeholderID] = record
        return height
    }

    func activate(_ placeholderID: RendererAttachmentPlaceholderID) -> RendererAttachmentActivationResult {
        guard var record = records[placeholderID], record.state == .card else { return .rejected }
        guard record.role == .disclosureRow else { return .rejected }
        let activeCount = records.values.filter { $0.role == .disclosureRow && $0.state == .active }.count
        guard activeCount < rowActiveLimit else {
            record.activationRefusal = .rowBudget
            records[placeholderID] = record
            return .refused(.rowBudget)
        }
        record.state = .active
        record.activationRefusal = nil
        records[placeholderID] = record
        return .activate
    }

    func collapse(_ placeholderID: RendererAttachmentPlaceholderID) {
        guard var record = records[placeholderID], record.state == .active else { return }
        record.state = .card
        record.activationRefusal = nil
        records[placeholderID] = record
    }

    func admitInline(_ placeholderID: RendererAttachmentPlaceholderID) -> RendererAttachmentActivationResult {
        guard var record = records[placeholderID],
              record.role == .inlineContent,
              record.inlineState == .eligible || record.inlineState == .waitingForResources
        else { return .rejected }
        let mountedCount = records.values.filter {
            $0.role == .inlineContent && $0.inlineState == .mounted
        }.count
        guard mountedCount < inlineActiveLimit else {
            record.inlineState = .waitingForResources
            record.activationRefusal = .resourcePressure
            records[placeholderID] = record
            return .refused(.resourcePressure)
        }
        record.inlineState = .mounted
        record.activationRefusal = nil
        records[placeholderID] = record
        return .activate
    }

    func releaseInline(_ placeholderID: RendererAttachmentPlaceholderID) {
        guard var record = records[placeholderID],
              record.role == .inlineContent,
              record.inlineState == .mounted || record.inlineState == .waitingForResources
        else { return }
        record.inlineState = .fallback
        record.activationRefusal = nil
        records[placeholderID] = record
    }

    func waitForInlineResources(_ placeholderID: RendererAttachmentPlaceholderID) {
        guard var record = records[placeholderID],
              record.role == .inlineContent,
              record.inlineState != .removed else { return }
        record.inlineState = .waitingForResources
        record.activationRefusal = .resourcePressure
        records[placeholderID] = record
    }

    func failInline(_ placeholderID: RendererAttachmentPlaceholderID) {
        guard var record = records[placeholderID],
              record.role == .inlineContent,
              record.inlineState != .removed else { return }
        record.inlineState = .failed
        records[placeholderID] = record
    }

    func removeInline(_ placeholderID: RendererAttachmentPlaceholderID) {
        guard var record = records[placeholderID], record.role == .inlineContent else { return }
        record.inlineState = .removed
        record.state = .closed
        records[placeholderID] = record
    }

    func refuse(_ placeholderID: RendererAttachmentPlaceholderID, reason: RendererAttachmentActivationRefusal) {
        guard var record = records[placeholderID], record.state == .card else { return }
        record.state = .card
        record.activationRefusal = reason
        records[placeholderID] = record
    }

    func fail(_ placeholderID: RendererAttachmentPlaceholderID) {
        guard var record = records[placeholderID], record.state != .closed else { return }
        record.state = .failed
        if record.role == .inlineContent { record.inlineState = .failed }
        records[placeholderID] = record
    }

    func closeAll() {
        for key in records.keys {
            records[key]?.state = .closed
            if records[key]?.role == .inlineContent {
                records[key]?.inlineState = .removed
            }
        }
    }

    func close(_ placeholderID: RendererAttachmentPlaceholderID) {
        guard var record = records[placeholderID] else { return }
        record.state = .closed
        if record.role == .inlineContent { record.inlineState = .removed }
        records[placeholderID] = record
    }

    private func isValid(_ rect: CGRect) -> Bool {
        rect.isFiniteRect && rect.width > 0 && rect.height > 0 &&
            abs(rect.minX) <= RendererAttachmentHostPolicy.maximumCoordinateMagnitude &&
            abs(rect.minY) <= RendererAttachmentHostPolicy.maximumCoordinateMagnitude &&
            abs(rect.maxX) <= RendererAttachmentHostPolicy.maximumCoordinateMagnitude &&
            abs(rect.maxY) <= RendererAttachmentHostPolicy.maximumCoordinateMagnitude
    }
}

private extension CGRect {
    var isFiniteRect: Bool {
        origin.x.isFinite && origin.y.isFinite && size.width.isFinite && size.height.isFinite
    }
}
#endif
