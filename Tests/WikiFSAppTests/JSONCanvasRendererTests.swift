#if os(macOS)
import Foundation
import Testing
@testable import WikiFS
import WikiFSCore
import WikiFSTypes

@Suite("JSON Canvas native renderer", .serialized, .timeLimit(.minutes(1)))
struct JSONCanvasRendererTests {
    @Test("native attachment factory resolves the exact source pin and matches equivalent fenced bytes")
    func nativeAttachmentFactoryResolvesPinnedSourceAndMatchesFence() throws {
        let source = try Self.sourceInput(bytes: Self.validCanvas)
        let sourcePin = try NativeJSONCanvasAttachmentInput.SourcePin(validating: source)
        let fencedInput = try Self.fencedInput(bytes: Self.validCanvas)
        var resolvedPins: [NativeJSONCanvasAttachmentInput.SourcePin] = []
        let factory = NativeJSONCanvasAttachmentFactory { pin in
            resolvedPins.append(pin)
            return Self.validCanvas
        }

        let sourceDocument = try factory.document(for: .source(sourcePin))
        let fencedDocument = try factory.document(for: .fenced(fencedInput))

        #expect(sourceDocument == fencedDocument)
        #expect(resolvedPins == [sourcePin])
        #expect(NativeJSONCanvasAttachmentInput.source(sourcePin) != .fenced(fencedInput))
    }

    @Test("default inline resolver accepts exact content and Markdown source identities", arguments: [false, true])
    @MainActor
    func defaultInlineResolverAcceptsExactSourceIdentities(useMarkdownVersion: Bool) throws {
        let source = try Self.sourceInput(bytes: Self.validCanvas, useMarkdownVersion: useMarkdownVersion)
        let input: RendererBridgeInput = if let versionID = source.sourceVersionID {
            .source(versionID: versionID)
        } else {
            .markdown(versionID: try #require(source.sourceMarkdownVersionID))
        }
        let context = RendererEmbedActivationContext(
            pageID: PageID(rawValue: "01J00000000000000000000021"),
            pageVersionID: PageVersionID(rawValue: "01J00000000000000000000022"),
            identity: .source(source),
            rendererReference: BuiltInRendererReference.reference(for: .jsonCanvas),
            input: input,
            capability: .init(rawValue: "capability"),
            generation: 1)
        let placeholder = try RendererAttachmentPlaceholderID(validating: "source-canvas")

        let result = RendererInlineAttachmentResolverFactory.defaultResolver(
            context: context,
            placeholderID: placeholder,
            onSessionFailure: { _ in })

        guard case .content = result else {
            Issue.record("expected an exact admitted source to resolve native JSON Canvas content")
            return
        }
    }

    @Test("default inline resolver rejects a mismatched source bridge identity")
    @MainActor
    func defaultInlineResolverRejectsMismatchedSourceIdentity() throws {
        let source = try Self.sourceInput(bytes: Self.validCanvas)
        let context = RendererEmbedActivationContext(
            pageID: PageID(rawValue: "01J00000000000000000000021"),
            pageVersionID: PageVersionID(rawValue: "01J00000000000000000000022"),
            identity: .source(source),
            rendererReference: BuiltInRendererReference.reference(for: .jsonCanvas),
            input: .source(versionID: SourceVersionID(rawValue: "01J00000000000000000000999")),
            capability: .init(rawValue: "capability"),
            generation: 1)
        let placeholder = try RendererAttachmentPlaceholderID(validating: "source-canvas")

        let result = RendererInlineAttachmentResolverFactory.defaultResolver(
            context: context,
            placeholderID: placeholder,
            onSessionFailure: { _ in })

        guard case .unsupported = result else {
            Issue.record("expected a mismatched source version to stay unsupported")
            return
        }
    }

    @Test("native attachment factory never resolves fenced inline artifact bytes")
    func nativeAttachmentFactoryDoesNotLookUpFencedArtifact() throws {
        let fencedInput = try Self.fencedInput(bytes: Self.validCanvas)
        let factory = NativeJSONCanvasAttachmentFactory.fencedOnly()

        let document = try factory.document(for: .fenced(fencedInput))
        let expectedDocument = try JSONCanvasDocument.decode(Self.validCanvas)

        #expect(document == expectedDocument)
    }

    @Test("native attachment factory retains the authorized input form in failures")
    func nativeAttachmentFactoryRetainsInputFormInFailures() throws {
        let source = try Self.sourceInput(bytes: Self.validCanvas)
        let sourcePin = try NativeJSONCanvasAttachmentInput.SourcePin(validating: source)
        let sourceFactory = NativeJSONCanvasAttachmentFactory { _ in Data("mismatched".utf8) }

        do {
            _ = try sourceFactory.document(for: .source(sourcePin))
            Issue.record("expected the mismatched source response to fail")
        } catch let failure as NativeJSONCanvasAttachmentFailure {
            #expect(failure == .source(input: sourcePin, reason: .digestMismatch))
        }

        let oversizedFence = try Self.fencedInput(
            bytes: Data(repeating: 0, count: JSONCanvasLimits.maximumInputByteCount + 1))
        let fencedFactory = NativeJSONCanvasAttachmentFactory { _ in
            Issue.record("fenced input must not perform source lookup")
            return Data()
        }

        do {
            _ = try fencedFactory.document(for: .fenced(oversizedFence))
            Issue.record("expected the oversized fenced artifact to fail")
        } catch let failure as NativeJSONCanvasAttachmentFailure {
            #expect(failure == .fenced(input: oversizedFence, reason: .oversizedInput))
        }
    }

    @Test("decoder accepts a bounded text-node Canvas and creates a deterministic projection")
    func decoderCreatesDeterministicProjection() throws {
        let document = try JSONCanvasDocument.decode(Self.validCanvas)

        #expect(document.nodes.map(\.id.rawValue) == ["second", "first"])
        #expect(document.outline.map(\.label) == ["First note", "Second note"])
        #expect(document.renderProjection.edges.map(\.id) == ["edge-1"])
        #expect(document.renderProjection.nodes.map(\.id.rawValue) == ["second", "first"])
    }

    @Test("decoder accepts standard colors on text nodes")
    func decoderAcceptsTextNodeColors() throws {
        let document = try JSONCanvasDocument.decode(Self.coloredTextCanvas)

        #expect(document.nodes.map(\.color) == [
            .preset(.red),
            .hex(red: 0x25, green: 0x63, blue: 0xeb),
        ])
        #expect(document.renderProjection.nodes.map(\.color) == document.nodes.map(\.color))
    }

    @Test("decoder accepts and preserves standard edge colors and labels")
    func decoderAcceptsEdgeColorsAndLabels() throws {
        let document = try JSONCanvasDocument.decode(Self.coloredEdgeCanvas)
        let edge = try #require(document.edges.first)
        let renderEdge = try #require(document.renderProjection.edges.first)

        #expect(edge.color == .hex(red: 0x11, green: 0x18, blue: 0x27))
        #expect(edge.label == "layering")
        #expect(renderEdge.color == edge.color)
        #expect(renderEdge.label == edge.label)
    }

    @Test("rendering and hit testing preserve Canvas array z-order")
    func renderingPreservesCanvasZOrder() throws {
        let document = try JSONCanvasDocument.decode(Self.layeredCanvas)
        let overlap = JSONCanvasPoint(x: 40, y: 40)

        #expect(document.renderProjection.nodes.map(\.id.rawValue) == ["behind", "front"])
        #expect(document.outline.map(\.nodeID.rawValue) == ["front", "behind"])
        #expect(document.nodeID(containing: overlap)?.rawValue == "front")
    }

    @Test("decoder accepts group backgrounds and all standard background styles")
    func decoderAcceptsGroupBackgrounds() throws {
        let document = try JSONCanvasDocument.decode(Self.groupBackgroundCanvas)

        #expect(document.nodes.map(\.backgroundStyle) == [.cover, .ratio, .repeat])
        #expect(document.nodes.map { $0.background?.rawValue } == ["SVG", "SVG", "SVG"])
        #expect(document.renderProjection.nodes.map(\.backgroundStyle) == [.cover, .ratio, .repeat])
    }

    @Test("decoder rejects invalid node colors")
    func decoderRejectsInvalidNodeColors() {
        let invalidCanvas = Data("""
        {"nodes":[{"id":"bad","type":"text","x":0,"y":0,"width":120,"height":60,"color":"7","text":"Bad"}],"edges":[]}
        """.utf8)

        #expect(throws: JSONCanvasDecodingError.invalidColor("bad")) {
            try JSONCanvasDocument.decode(invalidCanvas)
        }
    }

    @Test("edge geometry clips to node boundaries and points its arrow at the destination")
    func edgeGeometryClipsToNodeBoundaries() throws {
        let geometry = JSONCanvasEdgeGeometry(
            source: .init(origin: .init(x: 20, y: 10), width: 180, height: 80),
            destination: .init(origin: .init(x: 240, y: 10), width: 180, height: 80))

        #expect(geometry.start == .init(x: 200, y: 50))
        #expect(geometry.end == .init(x: 240, y: 50))
        #expect(geometry.arrowBaseLeft.x < geometry.end.x)
        #expect(geometry.arrowBaseRight.x < geometry.end.x)
    }

    @Test("decoder models only typed internal file and wiki links")
    func decoderModelsTypedInternalLinks() throws {
        let document = try JSONCanvasDocument.decode(Self.internalLinkCanvas)
        let fileReference = try #require(JSONCanvasInternalFileReference(rawValue: "notes/Readme.md"))
        let pageID = PageID(rawValue: "01J00000000000000000000000")
        let sourceID = SourceID(rawValue: "01J00000000000000000000001")

        #expect(document.renderProjection.nodes.map(\.text) == [
            "Readme.md",
            "Page 01J00000000000000000000000",
            "Source 01J00000000000000000000001",
        ])
        #expect(document.hostAction(for: try JSONCanvasNodeID(validating: "file")) == .openFile(fileReference))
        #expect(document.hostAction(for: try JSONCanvasNodeID(validating: "page")) == .openWiki(.page(pageID)))
        #expect(document.hostAction(for: try JSONCanvasNodeID(validating: "source")) == .openWiki(.source(sourceID)))
    }

    @Test("decoder accepts a file subpath with external link nodes")
    func decoderAcceptsFileSubpathAndExternalLinks() throws {
        let document = try JSONCanvasDocument.decode(Self.fileSubpathAndExternalLinkCanvas)
        let fileNode = try #require(document.nodes.first)
        guard case .file(let reference) = fileNode.internalLink else {
            Issue.record("expected a typed file reference")
            return
        }

        #expect(reference.rawValue == "JSON Canvas")
        #expect(reference.subpath?.rawValue == "#JSON Canvas Testbed")
        #expect(document.renderProjection.nodes.map(\.text) == [
            "JSON Canvas",
            "https://jsoncanvas.org/spec/1.0/",
        ])
        #expect(document.hostAction(for: try JSONCanvasNodeID(validating: "link")) == .openExternal(
            try #require(URL(string: "https://jsoncanvas.org/spec/1.0/"))))
    }

    @Test("host actions resolve files, wiki references, and external URLs")
    func hostActionsResolveEverySupportedTarget() throws {
        let fileReference = try #require(JSONCanvasInternalFileReference(
            path: "JSON Canvas.md",
            subpath: "#JSON Canvas Testbed"))
        let pageID = PageID(rawValue: "01J00000000000000000000000")
        let externalURL = try #require(URL(string: "https://jsoncanvas.org/"))

        #expect(JSONCanvasHostActionRouter.target(for: .openFile(fileReference)) == .namedContent(
            title: "JSON Canvas",
            anchor: "JSON Canvas Testbed"))
        #expect(JSONCanvasHostActionRouter.target(for: .openWiki(.page(pageID))) == .page(pageID))
        #expect(JSONCanvasHostActionRouter.target(for: .openExternal(externalURL)) == .external(externalURL))
    }

    @Test("internal host actions dispatch only the typed request")
    func internalHostActionsDispatchTypedRequest() throws {
        let document = try JSONCanvasDocument.decode(Self.internalLinkCanvas)
        let action = try #require(document.hostAction(for: try JSONCanvasNodeID(validating: "page")))
        var receivedActions: [JSONCanvasHostAction] = []
        let dispatcher = JSONCanvasHostActionDispatcher { receivedActions.append($0) }

        dispatcher.dispatch(action)

        #expect(receivedActions == [action])
    }

    @Test("decoder rejects unavailable malformed oversized and unsupported Canvas input")
    func decoderRejectsInvalidInput() throws {
        #expect(throws: JSONCanvasDecodingError.unavailableInput) {
            try JSONCanvasDocument.decode(nil)
        }
        #expect(throws: JSONCanvasDecodingError.malformedDocument) {
            try JSONCanvasDocument.decode(Data("{\"nodes\":[]".utf8))
        }
        #expect(throws: JSONCanvasDecodingError.oversizedInput) {
            try JSONCanvasDocument.decode(Data(repeating: 0, count: JSONCanvasLimits.maximumInputByteCount + 1))
        }
        let groupedDocument = try #require(try? JSONCanvasDocument.decode(Self.unsupportedGroupCanvas))
        #expect(groupedDocument.outline.contains { $0.label == "Group" })
        #expect(throws: JSONCanvasDecodingError.malformedDocument) {
            try JSONCanvasDocument.decode(Self.textNodeWithURLCanvas)
        }
        #expect(throws: JSONCanvasDecodingError.unknownEdgeEndpoint("missing")) {
            try JSONCanvasDocument.decode(Self.unknownEndpointCanvas)
        }
    }

    @Test("decoder rejects unsafe, external, and ambiguous internal links")
    func decoderRejectsUnsafeInternalLinks() {
        for data in Self.unsafeInternalLinkCanvases {
            #expect(throws: JSONCanvasDecodingError.invalidInternalLink("link")) {
                try JSONCanvasDocument.decode(data)
            }
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

    @Test("decoder rejects excessive edges and duplicate identifiers")
    func decoderRejectsEdgeAndIdentifierBounds() throws {
        let nodes = [Self.textNode(id: "first"), Self.textNode(id: "second")]
        let excessiveEdges = (0...JSONCanvasLimits.maximumEdgeCount).map { index in
            ["id": "edge-\(index)", "fromNode": "first", "toNode": "second"] as [String: Any]
        }

        #expect(throws: JSONCanvasDecodingError.tooManyEdges) {
            try JSONCanvasDocument.decode(Self.canvasData(nodes: nodes, edges: excessiveEdges))
        }
        #expect(throws: JSONCanvasDecodingError.duplicateNodeID("first")) {
            try JSONCanvasDocument.decode(Self.canvasData(nodes: [Self.textNode(id: "first"), Self.textNode(id: "first")]))
        }
        #expect(throws: JSONCanvasDecodingError.duplicateEdgeID("edge")) {
            try JSONCanvasDocument.decode(Self.canvasData(
                nodes: nodes,
                edges: [
                    ["id": "edge", "fromNode": "first", "toNode": "second"],
                    ["id": "edge", "fromNode": "first", "toNode": "second"],
                ]))
        }
    }

    @Test("decoder rejects invalid geometry and oversized text")
    func decoderRejectsGeometryAndTextBounds() throws {
        #expect(throws: JSONCanvasDecodingError.invalidGeometry("first")) {
            try JSONCanvasDocument.decode(Self.canvasData(nodes: [
                Self.textNode(id: "first", width: 0),
            ]))
        }
        #expect(throws: JSONCanvasDecodingError.malformedDocument) {
            try JSONCanvasDocument.decode(Self.nonFiniteGeometryCanvas)
        }
        #expect(throws: JSONCanvasDecodingError.textTooLarge("first")) {
            try JSONCanvasDocument.decode(Self.canvasData(nodes: [
                Self.textNode(id: "first", text: String(repeating: "x", count: JSONCanvasLimits.maximumTextLength + 1)),
            ]))
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

    @Test("viewport clamps translation and ignores non-finite zoom factors")
    func viewportClampsTranslationAndNonFiniteZoom() {
        var viewport = JSONCanvasViewportState(scale: 2)

        viewport.setTranslation(.init(
            x: JSONCanvasLimits.maximumTranslationMagnitude + 1,
            y: -JSONCanvasLimits.maximumTranslationMagnitude - 1))

        #expect(viewport.translation == .init(
            x: JSONCanvasLimits.maximumTranslationMagnitude,
            y: -JSONCanvasLimits.maximumTranslationMagnitude))

        viewport.setTranslation(.init(x: .infinity, y: .nan))
        viewport.zoom(by: .infinity)
        viewport.zoom(by: .nan)

        #expect(viewport.translation == .zero)
        #expect(viewport.scale == 2)
    }

    @Test("viewport fits the complete canvas inside the available surface")
    func viewportFitsDocumentBounds() throws {
        let document = try JSONCanvasDocument.decode(Self.fileSubpathAndExternalLinkCanvas)
        var viewport = JSONCanvasViewportState()

        viewport.fit(document: document, surfaceWidth: 700, surfaceHeight: 420, padding: 20)

        for node in document.renderProjection.nodes {
            let left = node.frame.origin.x * viewport.scale + viewport.translation.x
            let top = node.frame.origin.y * viewport.scale + viewport.translation.y
            let right = left + node.frame.width * viewport.scale
            let bottom = top + node.frame.height * viewport.scale
            #expect(left >= 20)
            #expect(top >= 20)
            #expect(right <= 680)
            #expect(bottom <= 400)
        }
    }

    @Test("viewport traversal follows the deterministic document outline")
    func viewportTraversalFollowsDocumentOutline() throws {
        let document = try JSONCanvasDocument.decode(Self.validCanvas)
        var viewport = JSONCanvasViewportState()

        #expect(viewport.traverseOutline(.next, in: document)?.rawValue == "first")
        #expect(viewport.traverseOutline(.next, in: document)?.rawValue == "second")
        #expect(viewport.traverseOutline(.next, in: document)?.rawValue == "second")
        #expect(viewport.traverseOutline(.previous, in: document)?.rawValue == "first")
        #expect(viewport.traverseOutline(.previous, in: document)?.rawValue == "first")
        #expect(viewport.selectedNodeID?.rawValue == "first")
    }

    @Test("renderer view uses semantic appearance styles and disables visual motion")
    func rendererViewUsesSemanticAppearanceAndDisablesVisualMotion() throws {
        let source = try Self.rendererViewSource()

        for semanticStyle in [
            "nodeColor?.opacity(0.16) ?? .secondary.opacity(0.08)",
            ".color(edgeColor)",
            "rendererColor(for: node.color)",
            ".background(.background)",
            "Text(node.text).font(.body).foregroundStyle(.primary)",
        ] {
            #expect(source.contains(semanticStyle))
        }
        #expect(source.contains(".transaction { transaction in"))
        #expect(source.contains("transaction.animation = nil"))
        #expect(source.contains("transaction.disablesAnimations = true"))
        #expect(source.contains("case fullRenderer"))
        #expect(source.contains("case inlineAttachment"))
        #expect(source.contains("if presentation == .fullRenderer"))
        #expect(source.contains("List(document.outline)"))
        #expect(source.contains("Divider()"))
        #expect(source.contains("lineWidth: viewport.selectedNodeID == node.id ? 2 : 1"))
        #expect(source.contains("withAnimation") == false)
        #expect(source.contains(".animation(") == false)
        #expect(source.contains(".transition(") == false)
        #expect(source.contains("Color(nsColor:") == false)
    }

    private static func rendererViewSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/WikiFS/Renderer/JSONCanvasRendererView.swift"),
            encoding: .utf8)
    }

    private static func sourceInput(
        bytes: Data,
        useMarkdownVersion: Bool = false
    ) throws -> RendererEmbeddedContent.Source {
        try .init(
            sourceID: SourceID(rawValue: "01J00000000000000000000011"),
            sourceVersionID: useMarkdownVersion ? nil : SourceVersionID(rawValue: "01J00000000000000000000012"),
            sourceMarkdownVersionID: useMarkdownVersion ? SourceMarkdownVersionID(rawValue: "01J00000000000000000000013") : nil,
            mimeType: try RendererMIMEType(validating: "application/json"),
            bytes: bytes)
    }

    private static func fencedInput(bytes: Data) throws -> RendererEmbeddedContent.InlineArtifact {
        let pageID = PageID(rawValue: "01J00000000000000000000021")
        let pageVersionID = PageVersionID(rawValue: "01J00000000000000000000022")
        let fence = try MarkdownFencedBlock(
            documentIdentity: .init(pageID: pageID, pageVersionID: pageVersionID),
            parserOrdinal: 0,
            rawInfoString: "jsoncanvas",
            bytes: bytes)
        return try .init(
            pageID: pageID,
            pageVersionID: pageVersionID,
            blockID: try #require(fence.blockID),
            fenceKind: .jsoncanvas,
            mimeType: try RendererMIMEType(validating: "application/json"),
            bytes: bytes)
    }

    private static func canvasData(
        nodes: [[String: Any]],
        edges: [[String: Any]] = []
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["nodes": nodes, "edges": edges])
    }

    private static func textNode(
        id: String,
        x: Int = 0,
        y: Int = 0,
        width: Int = 120,
        height: Int = 60,
        text: String = "Text"
    ) -> [String: Any] {
        [
            "id": id,
            "type": "text",
            "x": x,
            "y": y,
            "width": width,
            "height": height,
            "text": text,
        ]
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

    private static let coloredTextCanvas = Data("""
    {
      "nodes": [
        {"id":"preset","type":"text","x":0,"y":0,"width":120,"height":60,"color":"1","text":"Preset"},
        {"id":"hex","type":"text","x":140,"y":0,"width":120,"height":60,"color":"#2563eb","text":"Hex"}
      ],
      "edges": []
    }
    """.utf8)

    private static let coloredEdgeCanvas = Data("""
    {
      "nodes": [
        {"id":"first","type":"text","x":0,"y":0,"width":120,"height":60,"text":"First"},
        {"id":"second","type":"text","x":240,"y":0,"width":120,"height":60,"text":"Second"}
      ],
      "edges": [
        {"id":"edge","fromNode":"first","toNode":"second","color":"#111827","label":"layering"}
      ]
    }
    """.utf8)

    private static let layeredCanvas = Data("""
    {
      "nodes": [
        {"id":"behind","type":"text","x":20,"y":20,"width":120,"height":80,"color":"1","text":"Behind"},
        {"id":"front","type":"text","x":0,"y":0,"width":120,"height":80,"color":"6","text":"Front"}
      ],
      "edges": []
    }
    """.utf8)

    private static let internalLinkCanvas = Data("""
    {
      "nodes": [
        {"id":"file","type":"file","x":0,"y":0,"width":120,"height":60,"file":"notes/Readme.md"},
        {"id":"page","type":"link","x":0,"y":80,"width":120,"height":60,"url":"[[page:01J00000000000000000000000]]"},
        {"id":"source","type":"link","x":0,"y":160,"width":120,"height":60,"url":"[[source:01J00000000000000000000001]]"}
      ],
      "edges": []
    }
    """.utf8)

    private static let fileSubpathAndExternalLinkCanvas = Data("""
    {
      "nodes": [
        {"id":"file","type":"file","x":0,"y":0,"width":360,"height":240,"file":"JSON Canvas","subpath":"#JSON Canvas Testbed","color":"5"},
        {"id":"link","type":"link","x":0,"y":320,"width":360,"height":160,"url":"https://jsoncanvas.org/spec/1.0/","color":"2"}
      ],
      "edges": []
    }
    """.utf8)

    private static let unsupportedGroupCanvas = Data("""
    {
      "nodes": [
        {"id":"group","type":"group","x":0,"y":0,"width":120,"height":60,"label":"Group"}
      ],
      "edges": []
    }
    """.utf8)

    private static let unsafeInternalLinkCanvases: [Data] = [
        fileLinkCanvas("/private/notes.md"),
        fileLinkCanvas("//host/notes.md"),
        fileLinkCanvas("../notes.md"),
        fileLinkCanvas("notes/../secret.md"),
        fileLinkCanvas("https://example.com/notes.md"),
        fileLinkCanvas("file:notes.md"),
        fileLinkCanvas("user@host/notes.md"),
        fileLinkCanvas("notes.md?query"),
        fileLinkCanvas("notes.md#fragment"),
        fileLinkCanvas("notes%2Fsecret.md"),
        wikiLinkCanvas("wiki://page?id=01J00000000000000000000000"),
        wikiLinkCanvas("[[page:not-a-ulid]]"),
        wikiLinkCanvas("[[page:01J00000000000000000000000|Alias]]"),
        wikiLinkCanvas("[[page:01J00000000000000000000000#Section]]"),
    ]

    private static func fileLinkCanvas(_ file: String) -> Data {
        Data("""
        {"nodes":[{"id":"link","type":"file","x":0,"y":0,"width":120,"height":60,"file":"\(file)"}],"edges":[]}
        """.utf8)
    }

    private static func wikiLinkCanvas(_ url: String) -> Data {
        Data("""
        {"nodes":[{"id":"link","type":"link","x":0,"y":0,"width":120,"height":60,"url":"\(url)"}],"edges":[]}
        """.utf8)
    }

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

    private static let nonFiniteGeometryCanvas = Data("""
    {
      "nodes": [
        {"id":"first","type":"text","x":1e999,"y":0,"width":120,"height":60,"text":"First"}
      ],
      "edges": []
    }
    """.utf8)

    private static let groupBackgroundCanvas = Data("""
    {
      "nodes": [
        {"id":"cover","type":"group","x":0,"y":0,"width":360,"height":300,"color":"4","label":"Cover background","background":"SVG","backgroundStyle":"cover"},
        {"id":"ratio","type":"group","x":440,"y":0,"width":360,"height":300,"color":"5","label":"Ratio background","background":"SVG","backgroundStyle":"ratio"},
        {"id":"repeat","type":"group","x":0,"y":380,"width":800,"height":260,"color":"6","label":"Repeat background","background":"SVG","backgroundStyle":"repeat"}
      ],
      "edges": []
    }
    """.utf8)
}
#endif
