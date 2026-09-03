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

/// Builds a DOM embed plan from an authorized activation context. The exact
/// authorization boundary stays upstream (`RendererEmbedActivationContext` /
/// `RendererEmbedActivationAdmission`); this builder only chooses the
/// presentation kind from typed facts the admission already validated.
@MainActor
enum RendererDOMEmbedPlanner {
    /// Builds the package-iframe plan for an admitted installed renderer, or
    /// nil when the reader webview has no admitted frame token for the
    /// reference (the row then keeps its fallback / Open in Window action).
    static func packagePlan(
        context: RendererEmbedActivationContext,
        frameToken: RendererFrameOriginToken?,
        entryPath: String?
    ) -> RendererDOMEmbedPlan? {
        guard let frameToken,
              let entryPath,
              let entry = RendererRelativePath(rawValue: entryPath)
        else { return nil }
        let entryURL = RendererFramePackageURL.frameURL(
            token: frameToken,
            packageID: context.rendererReference.packageID,
            version: context.rendererReference.version,
            path: entry)
        return .packageFrame(RendererPackageFramePlan(
            rendererReference: context.rendererReference,
            frameToken: frameToken,
            entryURL: entryURL,
            accessibleTitle: context.displayTitle
                ?? "\(context.rendererReference.registrationID.rawValue) renderer"))
    }

    /// Builds the built-in DOM plan for a source-backed embed from the typed
    /// source facts the admission already validated. The MIME decides the
    /// presentation:
    /// - `application/pdf` → pinned PDF iframe (exact-version blob URL).
    /// - `text/html` → inert pinned HTML iframe (sandbox omits `allow-scripts`).
    /// - `audio/*` / `video/*` with bytes → DOM media elements.
    /// - byteless provider-hosted media (no bytes) → readable fallback with an
    ///   explicit open action (operator decision of 2026-09-03: no inline
    ///   external iframe in the reader).
    ///
    /// Returns nil when the input has no blob route (a markdown-version pin)
    /// or the MIME has no built-in presentation; the caller keeps its
    /// fallback / Open in Window behavior.
    static func builtInPlan(
        context: RendererEmbedActivationContext
    ) -> RendererDOMEmbedPlan? {
        // Only source identities carry built-in presentation facts.
        guard case .source(let source) = context.identity else { return nil }
        let title = context.displayTitle ?? source.sourceID.rawValue
        let mime = source.mimeType.rawValue

        // Byteless source: no bytes to authorize. Render the readable fallback.
        if source.bytes.isEmpty {
            return .readableFallback(RendererReadableFallbackPlan(
                accessibleTitle: title,
                explanation: "This media is hosted by its provider and is not embedded in the reader.",
                openActionLabel: "Open \(title) in Source Detail"))
        }

        // A source-content version is the only blob-routable pin; a
        // markdown-version input has no blob route.
        guard let blobURL = exactVersionBlobURL(source: source) else { return nil }
        let versionID = source.sourceVersionID?.rawValue ?? ""

        if mime == "application/pdf" {
            return .pdfFrame(RendererBlobFramePlan(
                sourceVersionID: versionID,
                blobURL: blobURL,
                accessibleTitle: title))
        }
        if mime == "text/html" {
            var plan = RendererBlobFramePlan(
                sourceVersionID: versionID,
                blobURL: blobURL,
                accessibleTitle: title)
            // Inert: scripts, inline handlers, and javascript: URLs cannot
            // run (the HTMLSourceWebView guarantee). allow-same-origin keeps
            // the frame's blob resources resolvable; allow-scripts is
            // deliberately absent.
            plan.sandboxFlags = "allow-same-origin"
            return .inertHTMLFrame(plan)
        }
        if mime.hasPrefix("audio/") {
            return .audioElement(RendererMediaElementPlan(
                kind: .audio,
                blobURL: blobURL,
                accessibleTitle: title))
        }
        if mime.hasPrefix("video/") {
            return .videoElement(RendererMediaElementPlan(
                kind: .video,
                blobURL: blobURL,
                accessibleTitle: title))
        }
        return nil
    }

    /// The exact-version blob URL for an admitted source. Only a
    /// source-content version is a valid pin; a markdown-version input has no
    /// blob route and yields no plan (the caller falls back).
    static func exactVersionBlobURL(source: RendererEmbeddedContent.Source) -> URL? {
        guard let versionID = source.sourceVersionID else { return nil }
        var components = URLComponents()
        components.scheme = "wiki-blob"
        components.host = BlobSchemeHandler.sourceVersionHost
        components.path = "/\(versionID.rawValue)"
        return components.url
    }
}

/// Evaluates the reader's named DOM-injection function for a plan, following
/// the `sdwInjectEmbed` parameter-passing discipline: values as parameters,
/// never concatenated HTML/JavaScript.
@MainActor
enum RendererDOMEmbedInjection {
    /// The JavaScript that creates the embed element with DOM APIs. Returns
    /// the acknowledgement string ('injected' / 'no-card' / …).
    static func injectionScript(
        plan: RendererDOMEmbedPlan,
        placeholderID: RendererAttachmentPlaceholderID,
        expansionID: String
    ) -> String? {
        let id = WikiReaderRep.jsString(placeholderID.rawValue)
        let expansion = WikiReaderRep.jsString(expansionID)
        switch plan {
        case .packageFrame(let framePlan):
            return inject(
                id: id, expansion: expansion, kind: "iframe",
                src: framePlan.entryURL.absoluteString,
                title: framePlan.accessibleTitle,
                height: Int(framePlan.boundedHeight),
                sandbox: framePlan.sandboxJSON)
        case .pdfFrame(let framePlan):
            return inject(
                id: id, expansion: expansion, kind: "iframe",
                src: framePlan.blobURL.absoluteString,
                title: framePlan.accessibleTitle,
                height: Int(framePlan.boundedHeight),
                sandbox: nil)
        case .inertHTMLFrame(let framePlan):
            return inject(
                id: id, expansion: expansion, kind: "iframe",
                src: framePlan.blobURL.absoluteString,
                title: framePlan.accessibleTitle,
                height: Int(framePlan.boundedHeight),
                sandbox: Self.sandboxJSONString(flags: ["allow-same-origin"]))
        case .audioElement(let mediaPlan):
            return inject(
                id: id, expansion: expansion, kind: "audio",
                src: mediaPlan.blobURL.absoluteString,
                title: mediaPlan.accessibleTitle,
                height: 0, sandbox: nil)
        case .videoElement(let mediaPlan):
            return inject(
                id: id, expansion: expansion, kind: "video",
                src: mediaPlan.blobURL.absoluteString,
                title: mediaPlan.accessibleTitle,
                height: 0, sandbox: nil)
        case .readableFallback:
            // Fallback plans render status text, not an embed surface.
            return nil
        }
    }

    static func removalScript(for placeholderID: RendererAttachmentPlaceholderID) -> String {
        "window.sdwRemoveRendererEmbed && window.sdwRemoveRendererEmbed(\"\(WikiReaderRep.jsString(placeholderID.rawValue))\");"
    }

    private static func inject(
        id: String, expansion: String, kind: String, src: String,
        title: String, height: Int, sandbox: String?
    ) -> String {
        let titleLiteral = WikiReaderRep.jsString(title)
        // The sandbox parameter is a JSON *string* the function JSON.parses.
        // jsString escapes it into a valid double-quoted JS literal; null
        // means no sandbox attribute.
        let sandboxLiteral = sandbox.map { "\"\(WikiReaderRep.jsString($0))\"" } ?? "null"
        return """
        window.sdwInjectRendererEmbed && window.sdwInjectRendererEmbed(
            "\(id)", "\(expansion)", "\(kind)",
            "\(WikiReaderRep.jsString(src))", "\(titleLiteral)",
            \(height), \(sandboxLiteral));
        """
    }

    /// Sandbox attribute JSON for inert frames. Raw HTML omits
    /// `allow-scripts` (the HTMLSourceWebView guarantee) and everything not
    /// listed stays denied (popups, forms, top navigation, downloads).
    static func sandboxJSONString(flags: [String]) -> String {
        let escaped = flags.map { flag in
            "\"\(flag.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return "[\(escaped.joined(separator: ","))]"
    }
}

extension RendererPackageFramePlan {
    /// The plan's sandbox flags as a JSON array literal for the injection
    /// function. Package documents get exactly `allow-scripts` — minimum
    /// permission to run their declared scripts; popups, forms, top
    /// navigation, downloads, and nested frames stay denied.
    var sandboxJSON: String? {
        RendererDOMEmbedInjection.sandboxJSONString(flags: Self.packageSandboxFlags.split(separator: " ").map(String.init))
    }
}
#endif
