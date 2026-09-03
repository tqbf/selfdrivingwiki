#if os(macOS)
import Foundation
import WikiFSCore

// pattern: Functional Core — typed, serializable presentation decisions.

/// The typed DOM presentation for one admitted renderer embed. The reader
/// converts a plan into DOM mutation through one named JavaScript function;
/// nothing here carries input bytes, capabilities, or secrets.
///
/// Plans are produced only after `RendererEmbedActivationContext` /
/// `RendererEmbedActivationAdmission` authorization succeeds, so a plan's
/// existence is the authority to mutate the DOM for that placeholder.
@MainActor
enum RendererDOMEmbedPlan: Equatable {
    /// A sandboxed `renderer-package:` iframe for one validated package.
    /// `frameToken` selects the frame route admitted in the reader router;
    /// `entryURL` is the frame-scoped entry URL (token host + package path).
    case packageFrame(RendererPackageFramePlan)
    /// A pinned PDF iframe served from the exact-version blob route.
    case pdfFrame(RendererBlobFramePlan)
    /// An inert pinned HTML iframe: `sandbox` omits `allow-scripts`, so the
    /// content cannot execute scripts, inline handlers, or `javascript:` URLs.
    case inertHTMLFrame(RendererBlobFramePlan)
    /// A byte-backed `<audio>` element pinned to its exact-version blob URL.
    case audioElement(RendererMediaElementPlan)
    /// A byte-backed `<video>` element pinned to its exact-version blob URL.
    case videoElement(RendererMediaElementPlan)
    /// Provider-hosted/byteless media: no inline iframe. The reader renders a
    /// readable fallback with an explicit open action routed to the existing
    /// Source Detail media presentation (operator decision of 2026-09-03).
    case readableFallback(RendererReadableFallbackPlan)

    var accessibleTitle: String {
        switch self {
        case .packageFrame(let plan): return plan.accessibleTitle
        case .pdfFrame(let plan): return plan.accessibleTitle
        case .inertHTMLFrame(let plan): return plan.accessibleTitle
        case .audioElement(let plan): return plan.accessibleTitle
        case .videoElement(let plan): return plan.accessibleTitle
        case .readableFallback(let plan): return plan.accessibleTitle
        }
    }

    /// The expansion region's bounded height in CSS points. Width is 100%.
    var boundedHeight: CGFloat {
        switch self {
        case .packageFrame(let plan): return plan.boundedHeight
        case .pdfFrame(let plan): return plan.boundedHeight
        case .inertHTMLFrame(let plan): return plan.boundedHeight
        case .audioElement, .videoElement: return 0 // intrinsic element height
        case .readableFallback: return 0 // fallback is text-height
        }
    }
}

/// A validated package iframe plan. The token is the frame's security-origin
/// host; the entry URL is fully frame-scoped (`renderer-package://<token>/…`).
@MainActor
struct RendererPackageFramePlan: Equatable {
    let rendererReference: RendererReference
    let frameToken: RendererFrameOriginToken
    let entryURL: URL
    let accessibleTitle: String
    /// Near-square expansion target for the reader column (720pt against 760).
    var boundedHeight: CGFloat = RendererDOMEmbedMetrics.nearSquareHeight

    /// The minimum sandbox flags the package document needs. Everything not
    /// listed stays denied (popups, forms, top navigation, downloads, and
    /// nested frames are never granted).
    static let packageSandboxFlags = "allow-scripts"
}

/// A pinned built-in iframe plan served from the exact-version blob route.
@MainActor
struct RendererBlobFramePlan: Equatable {
    let sourceVersionID: String
    let blobURL: URL
    let accessibleTitle: String
    /// Raw HTML frames are inert: the sandbox string omits `allow-scripts`.
    var sandboxFlags: String? = nil
    /// Near-square expansion target for PDF/HTML surfaces.
    var boundedHeight: CGFloat = RendererDOMEmbedMetrics.nearSquareHeight
}

/// A byte-backed media element plan pinned to its exact-version blob URL.
@MainActor
struct RendererMediaElementPlan: Equatable {
    enum ElementKind: Equatable {
        case audio
        case video
    }

    let kind: ElementKind
    let blobURL: URL
    let accessibleTitle: String
    /// Metadata preload only: no byte fetch before user interaction.
    static let preloadPolicy = "metadata"
}

/// A readable fallback for content the reader does not render inline.
@MainActor
struct RendererReadableFallbackPlan: Equatable {
    let accessibleTitle: String
    /// Human-readable one-line explanation of why the content is not inline.
    let explanation: String
    /// The action's accessibility label, e.g. "Open video in Source Detail".
    let openActionLabel: String
}

/// Named presentation metrics for DOM renderer surfaces. Width is always 100%
/// of the readable column; the near-square height approximates the 760pt
/// readable column so expanded renderers are not short strips.
enum RendererDOMEmbedMetrics {
    /// Near-square expansion target for the reader column (720pt against the
    /// 760pt readable width). Replaces the overlay reservation policy.
    static let nearSquareHeight: CGFloat = 720.0
}
#endif
