#if os(macOS)
import SwiftUI

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
        GeometryReader { _ in
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
                            var path = Path()
                            path.move(to: CGPoint(x: geometry.start.x, y: geometry.start.y))
                            path.addLine(to: CGPoint(x: geometry.end.x, y: geometry.end.y))
                            context.stroke(path, with: .color(.secondary), lineWidth: 1)

                            var arrowhead = Path()
                            arrowhead.move(to: CGPoint(x: geometry.end.x, y: geometry.end.y))
                            arrowhead.addLine(to: CGPoint(x: geometry.arrowBaseLeft.x, y: geometry.arrowBaseLeft.y))
                            arrowhead.addLine(to: CGPoint(x: geometry.arrowBaseRight.x, y: geometry.arrowBaseRight.y))
                            arrowhead.closeSubpath()
                            context.fill(arrowhead, with: .color(.secondary))
                        }

                        for node in document.renderProjection.nodes {
                            let rect = CGRect(
                                x: node.frame.origin.x,
                                y: node.frame.origin.y,
                                width: node.frame.width,
                                height: node.frame.height)
                            let path = Path(roundedRect: rect, cornerRadius: 8)
                            context.fill(path, with: .color(.secondary.opacity(0.08)))
                            context.stroke(
                                path,
                                with: .color(viewport.selectedNodeID == node.id ? .accentColor : .secondary),
                                lineWidth: viewport.selectedNodeID == node.id ? 2 : 1)
                            let text = context.resolve(Text(node.text).font(.body).foregroundStyle(.primary))
                            context.draw(text, in: rect.insetBy(dx: 10, dy: 8))
                        }
                    }

                    ForEach(document.renderProjection.nodes) { node in
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
                        .accessibilityHint("Press Return to select this read-only canvas node.")
                        .accessibilityAction(named: Text("Select")) {
                            selectCanvasNode(node.id)
                        }
                        .onMoveCommand { handleMoveCommand($0, from: .canvas) }
                        .contextMenu {
                            if document.hostAction(for: node.id) != nil {
                                Button("Open Internal Link") {
                                    requestHostAction(for: node.id)
                                }
                            }
                        }
                    }
                }
                .background(.background)
                .contentShape(.rect)
                .focusable()
                .focused($focusedSurface, equals: .canvas)
                .onMoveCommand { handleMoveCommand($0, from: .canvas) }
                .simultaneousGesture(dragGesture)
                .simultaneousGesture(magnifyGesture)
                .accessibilityLabel("JSON Canvas nodes")
                .accessibilityHint("Use the Up and Down Arrow keys to select a canvas node.")
            }
    }

    private enum FocusSurface: Hashable {
        case outline
        case canvas
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

    private func nodePosition(for node: JSONCanvasRenderProjection.Node) -> CGPoint {
        CGPoint(
            x: node.frame.origin.x * viewport.scale + viewport.translation.x + node.frame.width * viewport.scale / 2,
            y: node.frame.origin.y * viewport.scale + viewport.translation.y + node.frame.height * viewport.scale / 2)
    }

    private func accessibilityLabel(for node: JSONCanvasRenderProjection.Node) -> String {
        let label = node.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return label.isEmpty ? "Text node" : label
    }
}
#endif
