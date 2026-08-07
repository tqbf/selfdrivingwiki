#if os(macOS)
import Foundation
import Testing
@testable import WikiFS

@Suite("JSON Canvas native renderer", .serialized, .timeLimit(.minutes(1)))
struct JSONCanvasRendererTests {
    @Test("decoder accepts a bounded text-node Canvas and creates a deterministic projection")
    func decoderCreatesDeterministicProjection() throws {
        let document = try JSONCanvasDocument.decode(Self.validCanvas)

        #expect(document.nodes.map(\.id.rawValue) == ["second", "first"])
        #expect(document.outline.map(\.label) == ["First note", "Second note"])
        #expect(document.renderProjection.edges.map(\.id) == ["edge-1"])
        #expect(document.renderProjection.nodes.map(\.id.rawValue) == ["first", "second"])
    }

    @Test("decoder rejects unavailable malformed oversized and unsupported Canvas input")
    func decoderRejectsInvalidInput() {
        #expect(throws: JSONCanvasDecodingError.unavailableInput) {
            try JSONCanvasDocument.decode(nil)
        }
        #expect(throws: JSONCanvasDecodingError.malformedDocument) {
            try JSONCanvasDocument.decode(Data("{\"nodes\":[]".utf8))
        }
        #expect(throws: JSONCanvasDecodingError.oversizedInput) {
            try JSONCanvasDocument.decode(Data(repeating: 0, count: JSONCanvasLimits.maximumInputByteCount + 1))
        }
        #expect(throws: JSONCanvasDecodingError.unsupportedNodeType("link")) {
            try JSONCanvasDocument.decode(Self.unsupportedLinkCanvas)
        }
        #expect(throws: JSONCanvasDecodingError.malformedDocument) {
            try JSONCanvasDocument.decode(Self.textNodeWithURLCanvas)
        }
        #expect(throws: JSONCanvasDecodingError.unknownEdgeEndpoint("missing")) {
            try JSONCanvasDocument.decode(Self.unknownEndpointCanvas)
        }
    }

    @Test("decoder rejects a document that exceeds the node collection bound")
    func decoderRejectsExcessiveNodeCount() throws {
        let nodes = (0...JSONCanvasLimits.maximumNodeCount).map { index in
            [
                "id": "node-\(index)",
                "type": "text",
                "x": index,
                "y": 0,
                "width": 100,
                "height": 40,
                "text": "Node",
            ] as [String: Any]
        }
        let data = try JSONSerialization.data(withJSONObject: ["nodes": nodes, "edges": []])

        #expect(throws: JSONCanvasDecodingError.tooManyNodes) {
            try JSONCanvasDocument.decode(data)
        }
    }

    @Test("viewport clamps pan zoom and selection state")
    func viewportMaintainsBoundedInteractionState() throws {
        let document = try JSONCanvasDocument.decode(Self.validCanvas)
        var viewport = JSONCanvasViewportState()

        viewport.pan(by: .init(x: 24, y: -12))
        viewport.zoom(by: 100)
        viewport.selectNode(at: .init(x: 30, y: 20), in: document)

        #expect(viewport.selectedNodeID?.rawValue == "first")

        viewport.selectOutlineEntry(document.outline[0])

        #expect(viewport.translation == .init(x: 24, y: -12))
        #expect(viewport.scale == JSONCanvasLimits.maximumScale)
        #expect(viewport.selectedNodeID == document.outline[0].nodeID)

        viewport.zoom(by: 0)
        viewport.select(nodeID: nil)

        #expect(viewport.scale == JSONCanvasLimits.minimumScale)
        #expect(viewport.selectedNodeID == nil)
    }

    private static let validCanvas = Data("""
    {
      "nodes": [
        {"id":"second","type":"text","x":240,"y":100,"width":180,"height":80,"text":"Second note"},
        {"id":"first","type":"text","x":20,"y":10,"width":180,"height":80,"text":"First note"}
      ],
      "edges": [
        {"id":"edge-1","fromNode":"first","toNode":"second"}
      ]
    }
    """.utf8)

    private static let unsupportedLinkCanvas = Data("""
    {
      "nodes": [
        {"id":"link","type":"link","x":0,"y":0,"width":120,"height":60,"url":"https://example.com"}
      ],
      "edges": []
    }
    """.utf8)

    private static let unknownEndpointCanvas = Data("""
    {
      "nodes": [
        {"id":"first","type":"text","x":0,"y":0,"width":120,"height":60,"text":"First"}
      ],
      "edges": [
        {"id":"edge-1","fromNode":"first","toNode":"missing"}
      ]
    }
    """.utf8)

    private static let textNodeWithURLCanvas = Data("""
    {
      "nodes": [
        {"id":"text","type":"text","x":0,"y":0,"width":120,"height":60,"text":"Text","url":"https://example.com"}
      ],
      "edges": []
    }
    """.utf8)
}
#endif
