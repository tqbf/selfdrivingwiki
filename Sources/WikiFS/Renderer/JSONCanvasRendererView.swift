#if os(macOS)
import SwiftUI

// pattern: Mixed (unavoidable)
// Reason: This native surface binds SwiftUI gesture state to the functional
// JSON Canvas document and viewport projection types.

struct JSONCanvasRendererView: View {
    let document: JSONCanvasDocument

    @State private var viewport = JSONCanvasViewportState()
    @State private var dragStart: JSONCanvasPoint?
    @State private var dragInitialTranslation = JSONCanvasPoint.zero
    @State private var magnificationBaseline = 1.0

    var body: some View {
        HStack(spacing: 0) {
            List(document.outline) { entry in
                Button(entry.label) {
                    viewport.selectOutlineEntry(entry)
                }
                .buttonStyle(.plain)
                .font(.body)
                .lineLimit(1)
                .listRowBackground(viewport.selectedNodeID == entry.nodeID ? Color.accentColor.opacity(0.16) : .clear)
            }
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)

            Divider()

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
            .background(.background)
            .contentShape(.rect)
            .gesture(dragGesture)
            .simultaneousGesture(magnifyGesture)
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
}
#endif
