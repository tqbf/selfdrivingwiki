#if os(macOS)
import Foundation
import WikiFSCore

// pattern: Functional Core

enum JSONCanvasLimits {
    static let maximumInputByteCount = 256 * 1_024
    static let maximumNodeCount = 512
    static let maximumEdgeCount = 1_024
    static let maximumIdentifierLength = 128
    static let maximumTextLength = 8 * 1_024
    static let maximumCoordinateMagnitude = 1_000_000.0
    static let minimumScale = 0.25
    static let maximumScale = 4.0
    static let maximumTranslationMagnitude = 1_000_000.0
}

enum JSONCanvasDecodingError: Error, Equatable {
    case unavailableInput
    case oversizedInput
    case malformedDocument
    case tooManyNodes
    case tooManyEdges
    case invalidNodeID(String)
    case duplicateNodeID(String)
    case duplicateEdgeID(String)
    case unsupportedNodeType(String)
    case invalidGeometry(String)
    case invalidColor(String)
    case textTooLarge(String)
    case unknownEdgeEndpoint(String)
    case invalidInternalLink(String)
}

enum JSONCanvasColor: Sendable, Equatable {
    enum Preset: String, Sendable {
        case red = "1"
        case orange = "2"
        case yellow = "3"
        case green = "4"
        case cyan = "5"
        case purple = "6"
    }

    case preset(Preset)
    case hex(red: UInt8, green: UInt8, blue: UInt8)

    init(validating rawValue: String) throws {
        if let preset = Preset(rawValue: rawValue) {
            self = .preset(preset)
            return
        }
        guard rawValue.hasPrefix("#") else {
            throw JSONCanvasDecodingError.invalidColor(rawValue)
        }
        let digits = String(rawValue.dropFirst())
        let expanded: String
        switch digits.count {
        case 3:
            expanded = digits.reduce(into: "") { result, digit in
                result.append(digit)
                result.append(digit)
            }
        case 6:
            expanded = digits
        default:
            throw JSONCanvasDecodingError.invalidColor(rawValue)
        }
        guard let value = UInt32(expanded, radix: 16) else {
            throw JSONCanvasDecodingError.invalidColor(rawValue)
        }
        self = .hex(
            red: UInt8((value >> 16) & 0xff),
            green: UInt8((value >> 8) & 0xff),
            blue: UInt8(value & 0xff))
    }
}

enum JSONCanvasBackgroundStyle: String, Sendable, Equatable {
    case cover
    case ratio
    case `repeat`
}

struct JSONCanvasNodeID: Hashable, Sendable, Comparable, Identifiable {
    let rawValue: String

    var id: String { rawValue }

    init(validating rawValue: String) throws {
        guard rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              rawValue.isEmpty == false,
              rawValue.count <= JSONCanvasLimits.maximumIdentifierLength
        else { throw JSONCanvasDecodingError.invalidNodeID(rawValue) }
        self.rawValue = rawValue
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct JSONCanvasPoint: Sendable, Equatable {
    static let zero = Self(x: 0, y: 0)

    let x: Double
    let y: Double

    static func + (lhs: Self, rhs: Self) -> Self {
        .init(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }
}

struct JSONCanvasRect: Sendable, Equatable {
    let origin: JSONCanvasPoint
    let width: Double
    let height: Double

    var center: JSONCanvasPoint {
        .init(x: origin.x + width / 2, y: origin.y + height / 2)
    }

    func contains(_ point: JSONCanvasPoint) -> Bool {
        point.x >= origin.x && point.x <= origin.x + width &&
            point.y >= origin.y && point.y <= origin.y + height
    }
}

struct JSONCanvasInternalFileReference: RawRepresentable, Hashable, Sendable {
    let path: RendererRelativePath
    let subpath: JSONCanvasSubpath?

    var rawValue: String { path.rawValue }

    init?(rawValue: String) {
        self.init(path: rawValue, subpath: nil)
    }

    init?(path rawPath: String, subpath rawSubpath: String?) {
        guard rawPath == rawPath.trimmingCharacters(in: .whitespacesAndNewlines),
              rawPath.count <= JSONCanvasLimits.maximumIdentifierLength,
              rawPath.unicodeScalars.allSatisfy({ scalar in
                  scalar.properties.generalCategory != .control
              }),
              rawPath.contains(":") == false,
              rawPath.contains("@") == false,
              rawPath.contains("?") == false,
              rawPath.contains("#") == false,
              rawPath.contains("%") == false,
              let path = RendererRelativePath(rawValue: rawPath)
        else { return nil }
        let subpath: JSONCanvasSubpath?
        if let rawSubpath {
            guard let validatedSubpath = JSONCanvasSubpath(rawValue: rawSubpath) else { return nil }
            subpath = validatedSubpath
        } else {
            subpath = nil
        }
        self.path = path
        self.subpath = subpath
    }

    var displayLabel: String {
        path.rawValue.split(separator: "/").last.map(String.init) ?? path.rawValue
    }
}

struct JSONCanvasSubpath: RawRepresentable, Hashable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        guard rawValue.hasPrefix("#"),
              rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              rawValue.count <= JSONCanvasLimits.maximumTextLength,
              rawValue.unicodeScalars.allSatisfy({ $0.properties.generalCategory != .control })
        else { return nil }
        self.rawValue = rawValue
    }
}

enum JSONCanvasWikiReference: Hashable, Sendable {
    case page(PageID)
    case source(SourceID)

    init?(rawValue: String) {
        guard rawValue.hasPrefix("[["), rawValue.hasSuffix("]]"),
              rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }

        let contents = String(rawValue.dropFirst(2).dropLast(2))
        let components = contents.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2,
              let kind = components.first,
              let rawID = components.last,
              WikiLinkParser.isCanonicalULID(String(rawID))
        else { return nil }

        switch kind {
        case "page":
            self = .page(PageID(rawValue: String(rawID)))
        case "source":
            self = .source(SourceID(rawValue: String(rawID)))
        default:
            return nil
        }
    }

    var displayLabel: String {
        switch self {
        case .page(let id): "Page \(id.rawValue)"
        case .source(let id): "Source \(id.rawValue)"
        }
    }
}

enum JSONCanvasInternalLink: Hashable, Sendable {
    case file(JSONCanvasInternalFileReference)
    case wiki(JSONCanvasWikiReference)

    var displayLabel: String {
        switch self {
        case .file(let reference): reference.displayLabel
        case .wiki(let reference): reference.displayLabel
        }
    }
}

enum JSONCanvasHostAction: Hashable, Sendable {
    case openFile(JSONCanvasInternalFileReference)
    case openWiki(JSONCanvasWikiReference)
    case openExternal(URL)

    init(internalLink: JSONCanvasInternalLink) {
        switch internalLink {
        case .file(let reference): self = .openFile(reference)
        case .wiki(let reference): self = .openWiki(reference)
        }
    }
}

struct JSONCanvasHostActionDispatcher {
    let handler: (JSONCanvasHostAction) -> Void

    init(_ handler: @escaping (JSONCanvasHostAction) -> Void) {
        self.handler = handler
    }

    func dispatch(_ action: JSONCanvasHostAction) {
        handler(action)
    }
}

struct JSONCanvasNode: Sendable, Equatable, Identifiable {
    let id: JSONCanvasNodeID
    let frame: JSONCanvasRect
    let text: String
    let color: JSONCanvasColor?
    let background: JSONCanvasInternalFileReference?
    let backgroundStyle: JSONCanvasBackgroundStyle?
    let internalLink: JSONCanvasInternalLink?
    let externalURL: URL?
}

struct JSONCanvasEdge: Sendable, Equatable, Identifiable {
    let id: String
    let fromNodeID: JSONCanvasNodeID
    let toNodeID: JSONCanvasNodeID
    let color: JSONCanvasColor?
    let label: String?
}

struct JSONCanvasOutlineEntry: Sendable, Equatable, Identifiable {
    let nodeID: JSONCanvasNodeID
    let label: String

    var id: JSONCanvasNodeID { nodeID }
}

struct JSONCanvasRenderProjection: Sendable, Equatable {
    struct Node: Sendable, Equatable, Identifiable {
        let id: JSONCanvasNodeID
        let frame: JSONCanvasRect
        let text: String
        let color: JSONCanvasColor?
        let background: JSONCanvasInternalFileReference?
        let backgroundStyle: JSONCanvasBackgroundStyle?
        let internalLink: JSONCanvasInternalLink?
        let externalURL: URL?
    }

    struct Edge: Sendable, Equatable, Identifiable {
        let id: String
        let start: JSONCanvasPoint
        let end: JSONCanvasPoint
        let sourceFrame: JSONCanvasRect
        let destinationFrame: JSONCanvasRect
        let color: JSONCanvasColor?
        let label: String?
    }

    let nodes: [Node]
    let edges: [Edge]
}

struct JSONCanvasEdgeGeometry: Sendable, Equatable {
    let start: JSONCanvasPoint
    let end: JSONCanvasPoint
    let arrowBaseLeft: JSONCanvasPoint
    let arrowBaseRight: JSONCanvasPoint

    static let arrowLength = 14.0
    static let arrowWidth = 10.0

    init(source: JSONCanvasRect, destination: JSONCanvasRect) {
        let sourceCenter = source.center
        let destinationCenter = destination.center
        let direction = Self.unitVector(from: sourceCenter, to: destinationCenter)
        let start = Self.intersection(from: sourceCenter, toward: destinationCenter, in: source)
        let end = Self.intersection(from: destinationCenter, toward: sourceCenter, in: destination)
        let baseCenter = end - direction * Self.arrowLength
        let perpendicular = JSONCanvasPoint(x: -direction.y, y: direction.x)

        self.start = start
        self.end = end
        arrowBaseLeft = baseCenter + perpendicular * (Self.arrowWidth / 2)
        arrowBaseRight = baseCenter - perpendicular * (Self.arrowWidth / 2)
    }

    private static func unitVector(from start: JSONCanvasPoint, to end: JSONCanvasPoint) -> JSONCanvasPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0, length.isFinite else { return .init(x: 1, y: 0) }
        return .init(x: dx / length, y: dy / length)
    }

    private static func intersection(
        from center: JSONCanvasPoint,
        toward target: JSONCanvasPoint,
        in rect: JSONCanvasRect
    ) -> JSONCanvasPoint {
        let dx = target.x - center.x
        let dy = target.y - center.y
        guard dx != 0 || dy != 0 else { return center }

        let halfWidth = rect.width / 2
        let halfHeight = rect.height / 2
        let horizontalScale = dx == 0 ? .infinity : halfWidth / abs(dx)
        let verticalScale = dy == 0 ? .infinity : halfHeight / abs(dy)
        let scale = min(horizontalScale, verticalScale)
        return .init(x: center.x + dx * scale, y: center.y + dy * scale)
    }
}

private extension JSONCanvasPoint {
    static func - (lhs: Self, rhs: Self) -> Self {
        .init(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    static func * (lhs: Self, rhs: Double) -> Self {
        .init(x: lhs.x * rhs, y: lhs.y * rhs)
    }
}

struct JSONCanvasDocument: Sendable, Equatable {
    let nodes: [JSONCanvasNode]
    let edges: [JSONCanvasEdge]
    let outline: [JSONCanvasOutlineEntry]
    let renderProjection: JSONCanvasRenderProjection

    static func decode(_ data: Data?) throws -> Self {
        guard let data else { throw JSONCanvasDecodingError.unavailableInput }
        guard data.count <= JSONCanvasLimits.maximumInputByteCount else {
            throw JSONCanvasDecodingError.oversizedInput
        }

        let wireDocument: JSONCanvasWireDocument
        do {
            wireDocument = try JSONDecoder().decode(JSONCanvasWireDocument.self, from: data)
        } catch {
            throw JSONCanvasDecodingError.malformedDocument
        }
        return try Self(wireDocument: wireDocument)
    }

    private init(wireDocument: JSONCanvasWireDocument) throws {
        guard wireDocument.nodes.count <= JSONCanvasLimits.maximumNodeCount else {
            throw JSONCanvasDecodingError.tooManyNodes
        }
        guard wireDocument.edges.count <= JSONCanvasLimits.maximumEdgeCount else {
            throw JSONCanvasDecodingError.tooManyEdges
        }

        var knownNodeIDs: Set<JSONCanvasNodeID> = []
        var decodedNodes: [JSONCanvasNode] = []
        decodedNodes.reserveCapacity(wireDocument.nodes.count)
        for wireNode in wireDocument.nodes {
            let nodeID = try JSONCanvasNodeID(validating: wireNode.id)
            guard knownNodeIDs.insert(nodeID).inserted else {
                throw JSONCanvasDecodingError.duplicateNodeID(nodeID.rawValue)
            }
            let content = try Self.validatedContent(for: wireNode, nodeID: nodeID)
            guard content.text.count <= JSONCanvasLimits.maximumTextLength else {
                throw JSONCanvasDecodingError.textTooLarge(nodeID.rawValue)
            }
            let frame = try Self.validatedFrame(for: wireNode, nodeID: nodeID)
            let color: JSONCanvasColor?
            if let rawColor = wireNode.color {
                do {
                    color = try JSONCanvasColor(validating: rawColor)
                } catch {
                    throw JSONCanvasDecodingError.invalidColor(nodeID.rawValue)
                }
            } else {
                color = nil
            }
            let background = try Self.validatedBackground(for: wireNode, nodeID: nodeID)
            decodedNodes.append(.init(
                id: nodeID,
                frame: frame,
                text: content.text,
                color: color,
                background: background.reference,
                backgroundStyle: background.style,
                internalLink: content.internalLink,
                externalURL: content.externalURL))
        }

        var knownEdgeIDs: Set<String> = []
        var decodedEdges: [JSONCanvasEdge] = []
        decodedEdges.reserveCapacity(wireDocument.edges.count)
        for wireEdge in wireDocument.edges {
            guard wireEdge.id.isEmpty == false, wireEdge.id.count <= JSONCanvasLimits.maximumIdentifierLength,
                  knownEdgeIDs.insert(wireEdge.id).inserted else {
                throw JSONCanvasDecodingError.duplicateEdgeID(wireEdge.id)
            }
            let fromNodeID = try JSONCanvasNodeID(validating: wireEdge.fromNode)
            let toNodeID = try JSONCanvasNodeID(validating: wireEdge.toNode)
            guard knownNodeIDs.contains(fromNodeID) else {
                throw JSONCanvasDecodingError.unknownEdgeEndpoint(fromNodeID.rawValue)
            }
            guard knownNodeIDs.contains(toNodeID) else {
                throw JSONCanvasDecodingError.unknownEdgeEndpoint(toNodeID.rawValue)
            }
            let color: JSONCanvasColor?
            if let rawColor = wireEdge.color {
                do {
                    color = try JSONCanvasColor(validating: rawColor)
                } catch {
                    throw JSONCanvasDecodingError.invalidColor(wireEdge.id)
                }
            } else {
                color = nil
            }
            if let label = wireEdge.label,
               label.count > JSONCanvasLimits.maximumTextLength {
                throw JSONCanvasDecodingError.textTooLarge(wireEdge.id)
            }
            decodedEdges.append(.init(
                id: wireEdge.id,
                fromNodeID: fromNodeID,
                toNodeID: toNodeID,
                color: color,
                label: wireEdge.label))
        }

        nodes = decodedNodes
        edges = decodedEdges
        let nodesByID = Dictionary(uniqueKeysWithValues: decodedNodes.map { ($0.id, $0) })
        let renderNodes = decodedNodes.map {
            JSONCanvasRenderProjection.Node(
                id: $0.id,
                frame: $0.frame,
                text: $0.text,
                color: $0.color,
                background: $0.background,
                backgroundStyle: $0.backgroundStyle,
                internalLink: $0.internalLink,
                externalURL: $0.externalURL)
        }
        var renderEdges: [JSONCanvasRenderProjection.Edge] = []
        renderEdges.reserveCapacity(decodedEdges.count)
        for edge in decodedEdges.sorted(by: { $0.id < $1.id }) {
            guard let source = nodesByID[edge.fromNodeID] else {
                throw JSONCanvasDecodingError.unknownEdgeEndpoint(edge.fromNodeID.rawValue)
            }
            guard let destination = nodesByID[edge.toNodeID] else {
                throw JSONCanvasDecodingError.unknownEdgeEndpoint(edge.toNodeID.rawValue)
            }
            renderEdges.append(.init(
                id: edge.id,
                start: source.frame.center,
                end: destination.frame.center,
                sourceFrame: source.frame,
                destinationFrame: destination.frame,
                color: edge.color,
                label: edge.label))
        }
        renderProjection = .init(nodes: renderNodes, edges: renderEdges)
        outline = decodedNodes.sorted(by: Self.outlineOrder).map { node in
            .init(nodeID: node.id, label: Self.outlineLabel(for: node.text))
        }
    }

    func nodeID(containing point: JSONCanvasPoint) -> JSONCanvasNodeID? {
        renderProjection.nodes.reversed().first { $0.frame.contains(point) }?.id
    }

    func hostAction(for nodeID: JSONCanvasNodeID) -> JSONCanvasHostAction? {
        guard let node = nodes.first(where: { $0.id == nodeID }) else { return nil }
        if let internalLink = node.internalLink { return .init(internalLink: internalLink) }
        guard let url = node.externalURL else { return nil }
        return .openExternal(url)
    }

    private static func validatedContent(
        for wireNode: JSONCanvasWireNode,
        nodeID: JSONCanvasNodeID
    ) throws -> (text: String, internalLink: JSONCanvasInternalLink?, externalURL: URL?) {
        switch wireNode.type {
        case "text":
            guard let text = wireNode.text else {
                throw JSONCanvasDecodingError.malformedDocument
            }
            return (text, nil, nil)
        case "file":
            guard let rawFile = wireNode.file,
                  let reference = JSONCanvasInternalFileReference(path: rawFile, subpath: wireNode.subpath)
            else { throw JSONCanvasDecodingError.invalidInternalLink(nodeID.rawValue) }
            let internalLink = JSONCanvasInternalLink.file(reference)
            return (internalLink.displayLabel, internalLink, nil)
        case "link":
            guard let rawURL = wireNode.url else {
                throw JSONCanvasDecodingError.invalidInternalLink(nodeID.rawValue)
            }
            if let reference = JSONCanvasWikiReference(rawValue: rawURL) {
                let internalLink = JSONCanvasInternalLink.wiki(reference)
                return (internalLink.displayLabel, internalLink, nil)
            }
            guard rawURL.hasPrefix("[[") == false,
                  rawURL.hasSuffix("]]") == false
            else { throw JSONCanvasDecodingError.invalidInternalLink(nodeID.rawValue) }
            guard let url = URL(string: rawURL),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http"
            else { throw JSONCanvasDecodingError.invalidInternalLink(nodeID.rawValue) }
            return (rawURL, nil, url)
        case "group":
            let label = wireNode.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (label?.isEmpty == false ? label ?? "Group" : "Group", nil, nil)
        default:
            throw JSONCanvasDecodingError.unsupportedNodeType(wireNode.type)
        }
    }

    private static func validatedFrame(
        for wireNode: JSONCanvasWireNode,
        nodeID: JSONCanvasNodeID
    ) throws -> JSONCanvasRect {
        let values = [wireNode.x, wireNode.y, wireNode.width, wireNode.height]
        guard values.allSatisfy(\.isFinite),
              abs(wireNode.x) <= JSONCanvasLimits.maximumCoordinateMagnitude,
              abs(wireNode.y) <= JSONCanvasLimits.maximumCoordinateMagnitude,
              wireNode.width > 0,
              wireNode.height > 0,
              wireNode.width <= JSONCanvasLimits.maximumCoordinateMagnitude,
              wireNode.height <= JSONCanvasLimits.maximumCoordinateMagnitude
        else { throw JSONCanvasDecodingError.invalidGeometry(nodeID.rawValue) }
        return .init(origin: .init(x: wireNode.x, y: wireNode.y), width: wireNode.width, height: wireNode.height)
    }

    private static func validatedBackground(
        for wireNode: JSONCanvasWireNode,
        nodeID: JSONCanvasNodeID
    ) throws -> (reference: JSONCanvasInternalFileReference?, style: JSONCanvasBackgroundStyle?) {
        guard wireNode.type == "group" else { return (nil, nil) }
        guard let rawBackground = wireNode.background else {
            guard wireNode.backgroundStyle == nil else {
                throw JSONCanvasDecodingError.invalidInternalLink(nodeID.rawValue)
            }
            return (nil, nil)
        }
        guard let reference = JSONCanvasInternalFileReference(rawValue: rawBackground) else {
            throw JSONCanvasDecodingError.invalidInternalLink(nodeID.rawValue)
        }
        guard let rawStyle = wireNode.backgroundStyle else {
            return (reference, .cover)
        }
        guard let style = JSONCanvasBackgroundStyle(rawValue: rawStyle) else {
            throw JSONCanvasDecodingError.malformedDocument
        }
        return (reference, style)
    }

    private static func outlineOrder(_ lhs: JSONCanvasNode, _ rhs: JSONCanvasNode) -> Bool {
        if lhs.frame.origin.y != rhs.frame.origin.y { return lhs.frame.origin.y < rhs.frame.origin.y }
        if lhs.frame.origin.x != rhs.frame.origin.x { return lhs.frame.origin.x < rhs.frame.origin.x }
        return lhs.id < rhs.id
    }

    private static func outlineLabel(for text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return firstLine.isEmpty ? "Text node" : firstLine
    }
}

private struct JSONCanvasWireDocument: Decodable {
    let nodes: [JSONCanvasWireNode]
    let edges: [JSONCanvasWireEdge]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: JSONCanvasWireKey.self)
        try JSONCanvasWireValidation.rejectUnknownKeys(
            container.allKeys,
            allowed: ["nodes", "edges"]
        )
        nodes = try container.decode([JSONCanvasWireNode].self, forKey: .nodes)
        edges = try container.decode([JSONCanvasWireEdge].self, forKey: .edges)
    }
}

private struct JSONCanvasWireNode: Decodable {
    let id: String
    let type: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let text: String?
    let file: String?
    let url: String?
    let label: String?
    let color: String?
    let subpath: String?
    let background: String?
    let backgroundStyle: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: JSONCanvasWireKey.self)
        let type = try container.decode(String.self, forKey: .type)
        let allowedKeys: [String]
        switch type {
        case "text":
            allowedKeys = ["id", "type", "x", "y", "width", "height", "text", "color"]
        case "file":
            allowedKeys = ["id", "type", "x", "y", "width", "height", "file", "subpath", "color"]
        case "group":
            allowedKeys = ["id", "type", "x", "y", "width", "height", "label", "color", "fontSize", "background", "backgroundStyle"]
        case "link":
            allowedKeys = ["id", "type", "x", "y", "width", "height", "url", "color", "fontSize"]
        default:
            allowedKeys = ["id", "type", "x", "y", "width", "height"]
        }
        try JSONCanvasWireValidation.rejectUnknownKeys(container.allKeys, allowed: allowedKeys)

        id = try container.decode(String.self, forKey: .id)
        self.type = type
        x = try container.decode(Double.self, forKey: .x)
        y = try container.decode(Double.self, forKey: .y)
        width = try container.decode(Double.self, forKey: .width)
        height = try container.decode(Double.self, forKey: .height)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        file = try container.decodeIfPresent(String.self, forKey: .file)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        color = try container.decodeIfPresent(String.self, forKey: .color)
        subpath = try container.decodeIfPresent(String.self, forKey: .subpath)
        background = try container.decodeIfPresent(String.self, forKey: .background)
        backgroundStyle = try container.decodeIfPresent(String.self, forKey: .backgroundStyle)
    }
}

private struct JSONCanvasWireEdge: Decodable {
    let id: String
    let fromNode: String
    let toNode: String
    let color: String?
    let label: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: JSONCanvasWireKey.self)
        try JSONCanvasWireValidation.rejectUnknownKeys(
            container.allKeys,
            allowed: ["id", "fromNode", "toNode", "label", "color", "fromSide", "toSide", "fromEnd", "toEnd"]
        )
        id = try container.decode(String.self, forKey: .id)
        fromNode = try container.decode(String.self, forKey: .fromNode)
        toNode = try container.decode(String.self, forKey: .toNode)
        color = try container.decodeIfPresent(String.self, forKey: .color)
        label = try container.decodeIfPresent(String.self, forKey: .label)
    }
}

private struct JSONCanvasWireKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?

    private init(_ stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) { nil }

    static let nodes = Self("nodes")
    static let edges = Self("edges")
    static let id = Self("id")
    static let type = Self("type")
    static let x = Self("x")
    static let y = Self("y")
    static let width = Self("width")
    static let height = Self("height")
    static let text = Self("text")
    static let file = Self("file")
    static let url = Self("url")
    static let label = Self("label")
    static let color = Self("color")
    static let subpath = Self("subpath")
    static let background = Self("background")
    static let backgroundStyle = Self("backgroundStyle")
    static let fromNode = Self("fromNode")
    static let toNode = Self("toNode")
}

private enum JSONCanvasWireValidation {
    static func rejectUnknownKeys(_ keys: [JSONCanvasWireKey], allowed: [String]) throws {
        let allowedKeys = Set(allowed)
        guard keys.allSatisfy({ allowedKeys.contains($0.stringValue) }) else {
            throw JSONCanvasDecodingError.malformedDocument
        }
    }
}
#endif
