#if os(macOS)
import SwiftUI

// pattern: Mixed (unavoidable)
// Reason: This native surface binds SwiftUI gesture state to the functional
// JSON Canvas document and viewport projection types.

struct JSONCanvasRendererView: View {
    let document: JSONCanvasDocument
    private let hostActionDispatcher: JSONCanvasHostActionDispatcher

    @State private var viewport = JSONCanvasViewportState()
    @State private var dragStart: JSONCanvasPoint?
    @State private var dragInitialTranslation = JSONCanvasPoint.zero
    @State private var magnificationBaseline = 1.0
    @FocusState private var focusedSurface: FocusSurface?

    init(
        document: JSONCanvasDocument,
        onHostAction: @escaping (JSONCanvasHostAction) -> Void = { _ in }
    ) {
        self.document = document
        hostActionDispatcher = .init(onHostAction)
    }

    var body: some View {
        HStack(spacing: 0) {
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

            Divider()

            GeometryReader { _ in
                ZStack {
                    Canvas { context, _ in
                        context.concatenate(CGAffineTransform(
                            translationX: viewport.translation.x,
                            y: viewport.translation.y))
                        context.concatenate(CGAffineTransform(scaleX: viewport.scale, y: viewport.scale))

                        for edge in document.renderProjection.edges {
                            var path = Path()
                            path.move(to: CGPoint(x: edge.start.x, y: edge.start.y))
                            path.addLine(to: CGPoint(x: edge.end.x, y: edge.end.y))
                            context.stroke(path, with: .color(.secondary), lineWidth: 1)
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
        // Pan, zoom, focus, and selection are direct manipulation. This renderer
        // does not add visual motion and also blocks inherited implicit animation.
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
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
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                viewport.setScale(magnificationBaseline * value.magnification)
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
    }

    private func selectCanvasNode(_ nodeID: JSONCanvasNodeID) {
        viewport.select(nodeID: nodeID)
        focusedSurface = .canvas
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
            focusedSurface = surface == .outline ? .canvas : .outline
        default:
            break
        }
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
