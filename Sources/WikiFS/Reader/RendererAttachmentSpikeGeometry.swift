#if os(macOS)
import CoreGraphics
import Foundation

// pattern: Functional Core — this value type contains only pure geometry transforms.
/// Pure geometry contract for the PR 3 feasibility spike. The spike keeps the
/// reader routing unchanged and only tests how a DOM placeholder rect maps into
/// a sibling AppKit overlay under measured DOM CSS pixels, native page zoom,
/// and window backing scale.
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
        let originX = cssRect.minX / scale
        let originY = webViewBounds.height - (cssRect.maxY / scale)
        let size = CGSize(
            width: cssRect.width / scale,
            height: cssRect.height / scale)
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

enum RendererAttachmentSpikeMetrics {
    /// Returns a tolerance derived from the maximum observed residual in the
    /// hosted comparison set. The extra half-pixel margin absorbs AppKit
    /// quantization when converting the same rect between point and backing
    /// coordinates; if the live residual grows beyond that, the contract broke.
    static func derivedAlignmentTolerance(
        pointResiduals: [CGFloat],
        backingResiduals: [CGFloat],
        backingScaleFactor: CGFloat
    ) -> CGFloat {
        let pointResidual = pointResiduals.max() ?? 0
        let backingResidualPoints = (backingResiduals.max() ?? 0)
            / max(backingScaleFactor, .leastNonzeroMagnitude)
        let quantizationMargin = 0.5 / max(backingScaleFactor, .leastNonzeroMagnitude)
        return max(pointResidual, backingResidualPoints) + quantizationMargin
    }
}
#endif
