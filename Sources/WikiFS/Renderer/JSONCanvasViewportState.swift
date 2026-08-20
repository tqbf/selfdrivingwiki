#if os(macOS)
import Foundation

// pattern: Functional Core

enum JSONCanvasOutlineTraversalDirection: Sendable {
    case next
    case previous
}

struct JSONCanvasViewportState: Sendable, Equatable {
    private(set) var scale: Double
    private(set) var translation: JSONCanvasPoint
    private(set) var selectedNodeID: JSONCanvasNodeID?

    init(
        scale: Double = 1,
        translation: JSONCanvasPoint = .zero,
        selectedNodeID: JSONCanvasNodeID? = nil
    ) {
        self.scale = Self.clampedScale(scale)
        self.translation = Self.clampedTranslation(translation)
        self.selectedNodeID = selectedNodeID
    }

    mutating func pan(by delta: JSONCanvasPoint) {
        setTranslation(translation + delta)
    }

    mutating func setTranslation(_ translation: JSONCanvasPoint) {
        self.translation = Self.clampedTranslation(translation)
    }

    mutating func zoom(by factor: Double) {
        guard factor.isFinite else { return }
        setScale(scale * factor)
    }

    mutating func setScale(_ scale: Double) {
        self.scale = Self.clampedScale(scale)
    }

    mutating func fit(
        document: JSONCanvasDocument,
        surfaceWidth: Double,
        surfaceHeight: Double,
        padding: Double
    ) {
        guard let first = document.renderProjection.nodes.first,
              surfaceWidth.isFinite, surfaceHeight.isFinite, padding.isFinite,
              surfaceWidth > padding * 2, surfaceHeight > padding * 2
        else { return }
        let bounds = document.renderProjection.nodes.dropFirst().reduce(first.frame) { bounds, node in
            let minX = min(bounds.origin.x, node.frame.origin.x)
            let minY = min(bounds.origin.y, node.frame.origin.y)
            let maxX = max(bounds.origin.x + bounds.width, node.frame.origin.x + node.frame.width)
            let maxY = max(bounds.origin.y + bounds.height, node.frame.origin.y + node.frame.height)
            return JSONCanvasRect(origin: .init(x: minX, y: minY), width: maxX - minX, height: maxY - minY)
        }
        let fittedScale = min(
            (surfaceWidth - padding * 2) / bounds.width,
            (surfaceHeight - padding * 2) / bounds.height)
        setScale(min(1, fittedScale))
        setTranslation(.init(
            x: (surfaceWidth - bounds.width * scale) / 2 - bounds.origin.x * scale,
            y: (surfaceHeight - bounds.height * scale) / 2 - bounds.origin.y * scale))
    }

    mutating func select(nodeID: JSONCanvasNodeID?) {
        selectedNodeID = nodeID
    }

    mutating func selectOutlineEntry(_ entry: JSONCanvasOutlineEntry) {
        select(nodeID: entry.nodeID)
    }

    mutating func selectNode(at point: JSONCanvasPoint, in document: JSONCanvasDocument) {
        select(nodeID: document.nodeID(containing: point))
    }

    @discardableResult
    mutating func traverseOutline(
        _ direction: JSONCanvasOutlineTraversalDirection,
        in document: JSONCanvasDocument
    ) -> JSONCanvasNodeID? {
        let nodeIDs = document.outline.map(\.nodeID)
        guard nodeIDs.isEmpty == false else {
            select(nodeID: nil)
            return nil
        }

        let index: Int
        if let selectedNodeID, let selectedIndex = nodeIDs.firstIndex(of: selectedNodeID) {
            switch direction {
            case .next:
                index = min(selectedIndex + 1, nodeIDs.index(before: nodeIDs.endIndex))
            case .previous:
                index = max(selectedIndex - 1, nodeIDs.startIndex)
            }
        } else {
            switch direction {
            case .next:
                index = nodeIDs.startIndex
            case .previous:
                index = nodeIDs.index(before: nodeIDs.endIndex)
            }
        }

        let nodeID = nodeIDs[index]
        select(nodeID: nodeID)
        return nodeID
    }

    func documentPoint(screenX: Double, screenY: Double) -> JSONCanvasPoint {
        .init(
            x: (screenX - translation.x) / scale,
            y: (screenY - translation.y) / scale)
    }

    private static func clampedScale(_ value: Double) -> Double {
        guard value.isFinite else { return JSONCanvasLimits.minimumScale }
        return min(JSONCanvasLimits.maximumScale, max(JSONCanvasLimits.minimumScale, value))
    }

    private static func clampedTranslation(_ value: JSONCanvasPoint) -> JSONCanvasPoint {
        .init(
            x: clampedCoordinate(value.x),
            y: clampedCoordinate(value.y))
    }

    private static func clampedCoordinate(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(JSONCanvasLimits.maximumTranslationMagnitude, max(-JSONCanvasLimits.maximumTranslationMagnitude, value))
    }
}
#endif
