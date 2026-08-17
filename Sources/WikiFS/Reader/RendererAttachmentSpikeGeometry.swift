#if os(macOS)
import CoreGraphics
import Foundation

// pattern: Functional Core — this value type contains only pure geometry transforms.
/// Pure geometry contract for the PR 3 feasibility spike. `cssRect` is a DOM
/// client rectangle in CSS pixels. `overlayRect` is in AppKit points in an
/// unflipped overlay superview whose origin coincides with the WebView bounds
/// origin. The mapping therefore flips Y within the shared bounds and assumes
/// no additional WebView frame offset. `physicalOverlayRect` is in backing
/// pixels. Phase 4 owns any non-coincident or transformed container contract.
struct RendererAttachmentSpikeGeometry: Sendable, Equatable {
    let generation: Int
    let revision: Int
    let placeholderID: String
    let cssRect: CGRect
    let pageZoom: CGFloat
    let domCenterHit: Bool
    let scrollY: CGFloat
    let backingScaleFactor: CGFloat
    let webViewBounds: CGRect

    var overlayRect: CGRect {
        let scale = max(pageZoom, .leastNonzeroMagnitude)
        let originX = cssRect.minX * scale
        let originY = webViewBounds.height - (cssRect.maxY * scale)
        let size = CGSize(
            width: cssRect.width * scale,
            height: cssRect.height * scale)
        return CGRect(origin: CGPoint(x: originX, y: originY), size: size)
    }

    var physicalOverlayRect: CGRect {
        overlayRect.applying(.init(scaleX: backingScaleFactor, y: backingScaleFactor))
    }

    var clipRect: CGRect {
        overlayRect.intersection(webViewBounds)
    }

    var localClipRect: CGRect {
        let clipped = clipRect
        guard clipped.isNull == false && clipped.isEmpty == false else { return .zero }
        return clipped.offsetBy(dx: -overlayRect.minX, dy: -overlayRect.minY)
    }
}

#endif
