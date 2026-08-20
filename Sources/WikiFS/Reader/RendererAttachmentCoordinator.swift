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
    static let maximumActiveAttachments = 1
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
    let cssRect: CGRect
    let visible: Bool
    let revision: Int

    init(generation: Int, placeholderID: RendererAttachmentPlaceholderID, cssRect: CGRect, visible: Bool, revision: Int) {
        self.generation = generation
        self.placeholderID = placeholderID
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
              let revision = body["revision"] as? Int
        else { return nil }
        let cssRect = CGRect(x: x, y: y, width: width, height: height)
        guard cssRect.isFiniteRect else { return nil }
        self.generation = generation
        self.placeholderID = placeholderID
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

enum RendererAttachmentActivationResult: Equatable {
    case activate
    case showInFullRenderer
    case rejected
}

@MainActor
final class RendererAttachmentCoordinator {
    private struct Record {
        var state: RendererAttachmentState = .unresolved
        var latestRevision = -1
        var updateCount = 0
        var reservedHeight = RendererAttachmentHostPolicy.minimumReservedHeight
        var latestGeometry: RendererAttachmentGeometryMessage?
    }

    let generation: Int
    private let activeLimit: Int
    private var records: [RendererAttachmentPlaceholderID: Record] = [:]

    init(generation: Int, activeLimit: Int = RendererAttachmentHostPolicy.maximumActiveAttachments) {
        self.generation = generation
        self.activeLimit = max(0, activeLimit)
    }

    func state(for placeholderID: RendererAttachmentPlaceholderID) -> RendererAttachmentState {
        records[placeholderID]?.state ?? .unresolved
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
              message.revision > record.latestRevision,
              record.updateCount < RendererAttachmentHostPolicy.maximumUpdatesPerPlaceholder
        else { return false }
        record.latestRevision = message.revision
        record.updateCount += 1
        record.latestGeometry = message
        if record.state == .unresolved { record.state = .card }
        records[message.placeholderID] = record
        return true
    }

    func geometry(for placeholderID: RendererAttachmentPlaceholderID) -> RendererAttachmentGeometryMessage? {
        records[placeholderID]?.latestGeometry
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
        let activeCount = records.values.filter { $0.state == .active }.count
        guard activeCount < activeLimit else { return .showInFullRenderer }
        record.state = .active
        records[placeholderID] = record
        return .activate
    }

    func collapse(_ placeholderID: RendererAttachmentPlaceholderID) {
        guard var record = records[placeholderID], record.state == .active else { return }
        record.state = .card
        records[placeholderID] = record
    }

    func fail(_ placeholderID: RendererAttachmentPlaceholderID) {
        guard var record = records[placeholderID], record.state != .closed else { return }
        record.state = .failed
        records[placeholderID] = record
    }

    func closeAll() {
        for key in records.keys {
            records[key]?.state = .closed
        }
    }

    func close(_ placeholderID: RendererAttachmentPlaceholderID) {
        guard var record = records[placeholderID] else { return }
        record.state = .closed
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
