#if os(macOS)
import AppKit
import SwiftUI
import WikiFSCore

// pattern: Mixed (unavoidable)
// Reason: This native surface binds SwiftUI gesture state to the functional
// JSON Canvas document and viewport projection types.

struct JSONCanvasInteractionSnapshot: Equatable {
    let selectedNodeID: JSONCanvasNodeID?
    let scale: Double
    let translation: JSONCanvasPoint

    init(viewport: JSONCanvasViewportState) {
        selectedNodeID = viewport.selectedNodeID
        scale = viewport.scale
        translation = viewport.translation
    }
}

enum JSONCanvasNavigationTarget: Equatable, Sendable {
    case namedContent(title: String, anchor: String?)
    case page(PageID)
    case source(SourceID)
    case external(URL)
}

@MainActor
enum JSONCanvasHostActionRouter {
    nonisolated static func target(for action: JSONCanvasHostAction) -> JSONCanvasNavigationTarget {
        switch action {
        case .openFile(let reference):
            let filename = reference.path.rawValue.split(separator: "/").last.map(String.init)
                ?? reference.path.rawValue
            let title = (filename as NSString).deletingPathExtension
            return .namedContent(
                title: title,
                anchor: reference.subpath.map { String($0.rawValue.dropFirst()) })
        case .openWiki(.page(let pageID)):
            return .page(pageID)
        case .openWiki(.source(let sourceID)):
            return .source(sourceID)
        case .openExternal(let url):
            return .external(url)
        }
    }

    static func handler(
        for store: WikiStoreModel
    ) -> @MainActor @Sendable (JSONCanvasHostAction) -> Void {
        { action in route(action, store: store) }
    }

    static func route(
        _ action: JSONCanvasHostAction,
        store: WikiStoreModel,
        openExternal: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        switch target(for: action) {
        case .namedContent(let title, let anchor):
            if store.selectPage(byTitle: title, anchor: anchor) == false {
                _ = store.selectSource(byDisplayName: title, anchor: anchor)
            }
        case .page(let pageID):
            _ = store.selectPage(byID: pageID)
        case .source(let sourceID):
            _ = store.selectSource(byID: sourceID)
        case .external(let url):
            if openExternal(url) == false {
                DebugLog.reader("JSON Canvas could not open external URL: \(url.absoluteString)")
            }
        }
    }
}

/// Distinguishes the compact inline attachment from the full renderer surface.
enum JSONCanvasRendererPresentation: Equatable, Sendable {
    case fullRenderer
    case inlineAttachment
}

struct JSONCanvasRendererView: View {
    let document: JSONCanvasDocument
    let presentation: JSONCanvasRendererPresentation
    private let hostActionDispatcher: JSONCanvasHostActionDispatcher
    private let interactionObserver: (JSONCanvasInteractionSnapshot) -> Void

    @State private var viewport = JSONCanvasViewportState()
    @State private var dragStart: JSONCanvasPoint?
    @State private var dragInitialTranslation = JSONCanvasPoint.zero
    @State private var magnificationBaseline = 1.0
    @State private var fittedSurface = false
    @FocusState private var focusedSurface: FocusSurface?

    init(
        document: JSONCanvasDocument,
        presentation: JSONCanvasRendererPresentation = .fullRenderer,
        onHostAction: @escaping (JSONCanvasHostAction) -> Void = { _ in },
        onInteractionChange: @escaping (JSONCanvasInteractionSnapshot) -> Void = { _ in }
    ) {
        self.document = document
        self.presentation = presentation
        hostActionDispatcher = .init(onHostAction)
        interactionObserver = onInteractionChange
    }

    var body: some View {
        HStack(spacing: 0) {
            if presentation == .fullRenderer {
                outline
                Divider()
            }
            canvas
        }
        // Pan, zoom, focus, and selection are direct manipulation. This renderer
        // does not add visual motion and also blocks inherited implicit animation.
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    private var outline: some View {
        List(document.outline) { entry in
            Button(entry.label) {
                selectOutlineEntry(entry)
            }
            .buttonStyle(.plain)
            .font(.body)
            .lineLimit(1)
            .listRowBackground(viewport.selectedNodeID == entry.nodeID ? Color.accentColor.opacity(0.16) : .clear)
            .accessibilityLabel("Outline node: \(entry.label)")
            .accessibilityValue(viewport.selectedNodeID == entry.nodeID ? "Selected" : "Not selected")
            .accessibilityHint("Press Return to select this read-only canvas node.")
            .accessibilityAction(named: Text("Select")) {
                selectOutlineEntry(entry)
            }
            .onMoveCommand { handleMoveCommand($0, from: .outline) }
            .contextMenu {
                if document.hostAction(for: entry.nodeID) != nil {
                    Button("Open Internal Link") {
                        requestHostAction(for: entry.nodeID)
                    }
                }
            }
        }
        .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
        .focusable()
        .focused($focusedSurface, equals: .outline)
        .onMoveCommand { handleMoveCommand($0, from: .outline) }
        .accessibilityLabel("JSON Canvas outline")
        .accessibilityHint("Use the Up and Down Arrow keys to select an outline node.")
    }

    private var canvas: some View {
        GeometryReader { geometry in
                ZStack {
                    Canvas { context, _ in
                        context.concatenate(CGAffineTransform(
                            translationX: viewport.translation.x,
                            y: viewport.translation.y))
                        context.concatenate(CGAffineTransform(scaleX: viewport.scale, y: viewport.scale))

                        for edge in document.renderProjection.edges {
                            let geometry = JSONCanvasEdgeGeometry(
                                source: edge.sourceFrame,
                                destination: edge.destinationFrame)
                            let edgeColor = rendererColor(for: edge.color) ?? .secondary
                            var path = Path()
                            path.move(to: CGPoint(x: geometry.start.x, y: geometry.start.y))
                            path.addLine(to: CGPoint(x: geometry.end.x, y: geometry.end.y))
                            context.stroke(path, with: .color(edgeColor), lineWidth: 1)

                            var arrowhead = Path()
                            arrowhead.move(to: CGPoint(x: geometry.end.x, y: geometry.end.y))
                            arrowhead.addLine(to: CGPoint(x: geometry.arrowBaseLeft.x, y: geometry.arrowBaseLeft.y))
                            arrowhead.addLine(to: CGPoint(x: geometry.arrowBaseRight.x, y: geometry.arrowBaseRight.y))
                            arrowhead.closeSubpath()
                            context.fill(arrowhead, with: .color(edgeColor))

                            if let label = edge.label, label.isEmpty == false {
                                let text = context.resolve(
                                    Text(label).font(.caption).foregroundStyle(edgeColor))
                                context.draw(text, at: CGPoint(
                                    x: (geometry.start.x + geometry.end.x) / 2,
                                    y: (geometry.start.y + geometry.end.y) / 2))
                            }
                        }

                        for node in document.renderProjection.nodes {
                            let rect = CGRect(
                                x: node.frame.origin.x,
                                y: node.frame.origin.y,
                                width: node.frame.width,
                                height: node.frame.height)
                            let path = Path(roundedRect: rect, cornerRadius: 8)
                            let nodeColor = rendererColor(for: node.color)
                            context.fill(path, with: .color(nodeColor?.opacity(0.16) ?? .secondary.opacity(0.08)))
                            context.stroke(
                                path,
                                with: .color(viewport.selectedNodeID == node.id ? .accentColor : nodeColor ?? .secondary),
                                lineWidth: viewport.selectedNodeID == node.id ? 2 : 1)
                            let text = context.resolve(Text(node.text).font(.body).foregroundStyle(.primary))
                            context.draw(text, in: rect.insetBy(dx: 10, dy: 8))
                            if let background = node.background,
                               let style = node.backgroundStyle {
                                let caption = context.resolve(
                                    Text("\(background.displayLabel) · \(style.rawValue)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary))
                                context.draw(
                                    caption,
                                    at: CGPoint(x: rect.minX + 10, y: rect.maxY - 10),
                                    anchor: .bottomLeading)
                            }
                        }
                    }

                    ForEach(document.renderProjection.nodes) { node in
                        nodeOverlay(node)
                    }
                }
                .background(.background)
                .contentShape(.rect)
                .focusable()
                .focused($focusedSurface, equals: .canvas)
                .onMoveCommand { handleMoveCommand($0, from: .canvas) }
                .simultaneousGesture(dragGesture)
                .simultaneousGesture(magnifyGesture)
                .diagramScrollZoom { steps in
                    applyScrollZoom(steps, anchoredAt: .init(
                        x: geometry.size.width / 2,
                        y: geometry.size.height / 2))
                }
                .accessibilityLabel("JSON Canvas nodes")
                .accessibilityHint("Use the Up and Down Arrow keys to select a canvas node.")
                .onAppear {
                    fitCanvasOnce(to: geometry.size)
                }
            }
    }

    private enum FocusSurface: Hashable {
        case outline
        case canvas
    }

    private func nodeOverlay(_ node: JSONCanvasRenderProjection.Node) -> some View {
        Button {
            selectCanvasNode(node.id)
        } label: {
            Color.clear.contentShape(.rect)
        }
        .buttonStyle(.plain)
        .frame(
            width: node.frame.width * viewport.scale,
            height: node.frame.height * viewport.scale)
        .position(nodePosition(for: node))
        .accessibilityIdentifier("json-canvas-node-\(node.id.rawValue)")
        .accessibilityLabel("Canvas node: \(accessibilityLabel(for: node))")
        .accessibilityValue(viewport.selectedNodeID == node.id ? "Selected" : "Not selected")
        .accessibilityHint(document.hostAction(for: node.id) == nil
            ? "Press Return to select this read-only canvas node."
            : "Press Return to select, or use Open to follow this canvas node.")
        .accessibilityAction(named: Text("Select")) {
            selectCanvasNode(node.id)
        }
        .accessibilityAction(named: Text("Open")) {
            requestHostAction(for: node.id)
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            requestHostAction(for: node.id)
        })
        .onMoveCommand { handleMoveCommand($0, from: .canvas) }
        .contextMenu {
            if document.hostAction(for: node.id) != nil {
                Button("Open") {
                    requestHostAction(for: node.id)
                }
            }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let location = JSONCanvasPoint(x: value.location.x, y: value.location.y)
                guard let dragStart else {
                    dragStart = location
                    dragInitialTranslation = viewport.translation
                    return
                }
                let delta = JSONCanvasPoint(x: location.x - dragStart.x, y: location.y - dragStart.y)
                if Self.dragDistance(delta) >= 4 {
                    viewport.setTranslation(dragInitialTranslation + delta)
                    reportInteraction()
                }
            }
            .onEnded { value in
                defer { dragStart = nil }
                guard let dragStart else { return }
                let location = JSONCanvasPoint(x: value.location.x, y: value.location.y)
                let delta = JSONCanvasPoint(x: location.x - dragStart.x, y: location.y - dragStart.y)
                guard Self.dragDistance(delta) < 4 else { return }
                let point = viewport.documentPoint(screenX: location.x, screenY: location.y)
                viewport.selectNode(at: point, in: document)
                focusedSurface = .canvas
                reportInteraction()
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                viewport.setScale(magnificationBaseline * value.magnification)
                reportInteraction()
            }
            .onEnded { _ in
                magnificationBaseline = viewport.scale
            }
    }

    private static func dragDistance(_ point: JSONCanvasPoint) -> Double {
        (point.x * point.x + point.y * point.y).squareRoot()
    }

    private func applyScrollZoom(_ steps: Int, anchoredAt point: JSONCanvasPoint) {
        guard steps != 0 else { return }
        let factor = pow(ZoomScale.stepFactor, Double(steps))
        viewport.zoom(by: factor, anchoredAt: point)
        magnificationBaseline = viewport.scale
        reportInteraction()
    }

    private func selectOutlineEntry(_ entry: JSONCanvasOutlineEntry) {
        viewport.selectOutlineEntry(entry)
        focusedSurface = .outline
        reportInteraction()
    }

    private func selectCanvasNode(_ nodeID: JSONCanvasNodeID) {
        viewport.select(nodeID: nodeID)
        focusedSurface = .canvas
        reportInteraction()
    }

    private func requestHostAction(for nodeID: JSONCanvasNodeID) {
        guard let action = document.hostAction(for: nodeID) else { return }
        hostActionDispatcher.dispatch(action)
    }

    private func handleMoveCommand(_ direction: MoveCommandDirection, from surface: FocusSurface) {
        switch direction {
        case .up:
            viewport.traverseOutline(.previous, in: document)
        case .down:
            viewport.traverseOutline(.next, in: document)
        case .left, .right:
            guard presentation == .fullRenderer else { return }
            focusedSurface = surface == .outline ? .canvas : .outline
        default:
            break
        }
        reportInteraction()
    }

    private func reportInteraction() {
        interactionObserver(.init(viewport: viewport))
    }

    private func fitCanvasOnce(to size: CGSize) {
        guard fittedSurface == false else { return }
        viewport.fit(
            document: document,
            surfaceWidth: size.width,
            surfaceHeight: size.height,
            padding: 20)
        magnificationBaseline = viewport.scale
        fittedSurface = true
        reportInteraction()
    }

    private func nodePosition(for node: JSONCanvasRenderProjection.Node) -> CGPoint {
        CGPoint(
            x: node.frame.origin.x * viewport.scale + viewport.translation.x + node.frame.width * viewport.scale / 2,
            y: node.frame.origin.y * viewport.scale + viewport.translation.y + node.frame.height * viewport.scale / 2)
    }

    private func accessibilityLabel(for node: JSONCanvasRenderProjection.Node) -> String {
        let label = node.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return label.isEmpty ? "Text node" : label
    }

    private func rendererColor(for color: JSONCanvasColor?) -> Color? {
        switch color {
        case .none:
            nil
        case .preset(.red):
            .red
        case .preset(.orange):
            .orange
        case .preset(.yellow):
            .yellow
        case .preset(.green):
            .green
        case .preset(.cyan):
            .cyan
        case .preset(.purple):
            .purple
        case .hex(let red, let green, let blue):
            Color(
                .sRGB,
                red: Double(red) / 255,
                green: Double(green) / 255,
                blue: Double(blue) / 255,
                opacity: 1)
        }
    }
}
#endif
