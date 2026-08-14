#if os(macOS)
import CoreGraphics
import Foundation

// pattern: Functional Core — this value type contains only pure geometry transforms.
/// Pure geometry contract for the PR 3 feasibility spike. The spike keeps the
/// reader routing unchanged and only tests how a DOM placeholder rect maps into
/// a sibling AppKit overlay under page zoom and window backing scale.
struct RendererAttachmentSpikeGeometry: Sendable, Equatable {
    let generation: Int
    let revision: Int
    let placeholderID: String
    let cssRect: CGRect
    let pageZoom: CGFloat
    let domToViewScale: CGFloat
    let domCenterHit: Bool
    let scrollY: CGFloat
    let backingScaleFactor: CGFloat
    let webViewBounds: CGRect
    let tolerance: CGFloat

    var overlayRect: CGRect {
        let scale = max(domToViewScale, .leastNonzeroMagnitude)
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

    func isAligned(with actual: CGRect) -> Bool {
        [abs(actual.minX - overlayRect.minX),
         abs(actual.minY - overlayRect.minY),
         abs(actual.width - overlayRect.width),
         abs(actual.height - overlayRect.height)].allSatisfy { $0 <= tolerance }
    }
}

enum RendererAttachmentSpikeMetrics {
    /// The hosted probe uses a fixed 100 CSS-point reference. A 0.75-point
    /// residual is the measured tolerance for the AppKit-point round trip;
    /// larger drift means the transform or clipping contract is off.
    static let referenceCSSWidth: CGFloat = 100
    static let measuredAlignmentTolerance: CGFloat = 0.75
}
#endif
