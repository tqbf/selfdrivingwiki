#if os(macOS)
import Foundation
import SwiftUI
import WikiFSCore
import WikiFSTypes

// pattern: Functional Core

/// Host-owned renderer registrations for the presentations SourceDetailView
/// already supports. These descriptors characterize existing behavior only; the
/// Source presentation remains a host fallback and is not registered here.
enum BuiltInRendererDescriptors {
    static let all: [RendererDescriptor] = BuiltInRendererID.allCases.map { descriptor(for: $0) }

    static func descriptor(for id: BuiltInRendererID) -> RendererDescriptor {
        switch id {
        case .pdf:
            return make(
                id: .pdf,
                displayName: "PDF",
                matchers: [
                    .normalizedMIME(mime(MimeType.pdf)),
                    .extensionFallback(fileExtension("pdf")),
                    .boundedSignature(signature("%PDF")),
                ],
                maximumInputByteCount: BuiltInRendererLimits.bytefulMaximumInputByteCount,
                priority: BuiltInRendererPriority.bytefulDocument)
        case .html:
            return make(
                id: .html,
                displayName: "HTML",
                matchers: [
                    .normalizedMIME(mime(MimeType.html)),
                    .normalizedMIME(mime(MimeType.xhtml)),
                    .extensionFallback(fileExtension("html")),
                    .extensionFallback(fileExtension("htm")),
                    .extensionFallback(fileExtension("xhtml")),
                ],
                maximumInputByteCount: BuiltInRendererLimits.bytefulMaximumInputByteCount,
                priority: BuiltInRendererPriority.bytefulDocument)
        case .svg:
            return make(
                id: .svg,
                displayName: "SVG",
                matchers: [
                    .normalizedMIME(mime(BuiltInRendererMIME.svg)),
                    .extensionFallback(fileExtension("svg")),
                ],
                maximumInputByteCount: BuiltInRendererLimits.svgMaximumInputByteCount,
                priority: BuiltInRendererPriority.bytefulDocument)
        case .mermaid:
            return make(
                id: .mermaid,
                displayName: "Mermaid",
                matchers: [
                    .normalizedMIME(mime(BuiltInRendererMIME.mermaid)),
                    .extensionFallback(fileExtension("mmd")),
                    .artifactKind(.markdown),
                ],
                maximumInputByteCount: BuiltInRendererLimits.markdownMaximumInputByteCount,
                embeddingRoles: [.inlineContent, .disclosureRow],
                fenceClaims: [
                    RendererFenceClaim(alias: fenceAlias("mermaid"), inlineMIMEType: mime(BuiltInRendererMIME.mermaid)),
                ],
                priority: BuiltInRendererPriority.markdownDocument)
        case .media:
            return make(
                id: .media,
                displayName: "Media",
                matchers: BuiltInRendererMIME.mediaMIMEs.map { .normalizedMIME(mime($0)) },
                maximumInputByteCount: BuiltInRendererLimits.bytelessMaximumInputByteCount,
                priority: BuiltInRendererPriority.media)
        case .jsonCanvas:
            return make(
                id: .jsonCanvas,
                displayName: "JSON Canvas",
                matchers: [
                    .normalizedMIME(mime(BuiltInRendererMIME.json)),
                    .extensionFallback(fileExtension("canvas")),
                    .boundedJSONArtifact(.jsonCanvas),
                ],
                maximumInputByteCount: JSONCanvasLimits.maximumInputByteCount,
                embeddingRoles: [.inlineContent, .disclosureRow],
                fenceClaims: [
                    RendererFenceClaim(alias: fenceAlias("jsoncanvas"), inlineMIMEType: mime(BuiltInRendererMIME.json)),
                ],
                accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true),
                priority: BuiltInRendererPriority.jsonCanvas)
        }
    }

    private static func make(
        id: BuiltInRendererID,
        displayName: String,
        matchers: [RendererMatcher],
        maximumInputByteCount: Int,
        embeddingRoles: Set<RendererEmbeddingRole> = [.inlineContent],
        fenceClaims: [RendererFenceClaim] = [],
        accessibility: RendererAccessibility = .init(supportsVoiceOver: true, supportsKeyboardNavigation: true),
        priority: Int
    ) -> RendererDescriptor {
        do {
            return try RendererDescriptor(
                reference: BuiltInRendererReference.reference(for: id),
                displayName: displayName,
                implementation: .builtIn(id),
                matchers: matchers,
                presentations: [.native],
                supportedEmbeddingRoles: embeddingRoles,
                hasExplicitEmbeddingRoles: true,
                fenceClaims: fenceClaims,
                approvedAssets: [],
                capabilities: [.inputRead],
                sizeLimits: try .init(
                    maximumInputByteCount: maximumInputByteCount,
                    maximumDecodedByteCount: maximumInputByteCount),
                linkPolicy: .none,
                accessibility: accessibility,
                compatibility: try .init(
                    minimumProtocolRevision: RendererRegistrySnapshotDefaults.hostProtocolRevision,
                    maximumProtocolRevision: RendererRegistrySnapshotDefaults.hostProtocolRevision),
                priority: priority)
        } catch {
            preconditionFailure("Invalid built-in renderer descriptor for \\(id.rawValue): \\(error)")
        }
    }

    private static func mime(_ rawValue: String) -> RendererMIMEType {
        do { return try RendererMIMEType(validating: rawValue) }
        catch { preconditionFailure("Invalid built-in renderer MIME \\(rawValue): \\(error)") }
    }

    private static func fileExtension(_ rawValue: String) -> RendererFileExtension {
        do { return try RendererFileExtension(validating: rawValue) }
        catch { preconditionFailure("Invalid built-in renderer extension \\(rawValue): \\(error)") }
    }

    private static func fenceAlias(_ rawValue: String) -> RendererFenceAlias {
        do { return try RendererFenceAlias(validating: rawValue) }
        catch { preconditionFailure("Invalid built-in renderer fence alias \\(rawValue): \\(error)") }
    }

    /// Aliases the trusted built-in table claims for Markdown rich fences. This
    /// is the single definition of built-in fence authority: the runtime wiring
    /// injects it into package validation and activation, and host components
    /// (e.g. the JSON Canvas attachment factory) derive their checks from it.
    static var reservedFenceAliases: Set<RendererFenceAlias> {
        Set(all.flatMap(\.fenceClaims).map(\.alias))
    }

    /// The aliases one built-in renderer claims, for host components that need
    /// a data-derived answer instead of a format comparison.
    static func fenceAliases(for id: BuiltInRendererID) -> Set<RendererFenceAlias> {
        Set(descriptor(for: id).fenceClaims.map(\.alias))
    }

    private static func signature(_ value: String) -> RendererSignature {
        do { return try RendererSignature(offset: 0, bytes: Array(value.utf8)) }
        catch { preconditionFailure("Invalid built-in renderer signature \\(value): \\(error)") }
    }
}

enum BuiltInRendererReference {
    static let packageID: RendererPackageID = {
        do { return try RendererPackageID(validating: "org.selfdrivingwiki.builtin") }
        catch { preconditionFailure("Invalid built-in renderer package ID: \\(error)") }
    }()

    static let version: RendererPackageVersion = {
        do { return try RendererPackageVersion(validating: "1.0.0") }
        catch { preconditionFailure("Invalid built-in renderer version: \\(error)") }
    }()

    static func reference(for id: BuiltInRendererID) -> RendererReference {
        RendererReference(
            packageID: packageID,
            version: version,
            registrationID: registrationID(for: id))
    }

    static func registrationID(for id: BuiltInRendererID) -> RendererRegistrationID {
        do { return try RendererRegistrationID(validating: id.rawValue) }
        catch { preconditionFailure("Invalid built-in renderer registration ID \\(id.rawValue): \\(error)") }
    }
}

enum BuiltInRendererPriority {
    static let jsonCanvas = 110
    static let bytefulDocument = 100
    static let markdownDocument = 90
    static let media = 80
}

enum BuiltInRendererLimits {
    static let bytefulMaximumInputByteCount = 512 * 1_024 * 1_024
    static let svgMaximumInputByteCount = 16 * 1_024 * 1_024
    static let markdownMaximumInputByteCount = 64 * 1_024 * 1_024
    static let bytelessMaximumInputByteCount = 1
}

enum BuiltInRendererMIME {
    static let json = "application/json"
    static let svg = "image/svg+xml"
    static let mermaid = "text/mermaid"
    static let youtube = "video/youtube"
    static let vimeo = "video/vimeo"
    static let applePodcast = "audio/apple-podcast"
    static let spotify = "audio/spotify"
    static let soundCloud = "audio/soundcloud"

    static let mediaMIMEs: [String] = [
        youtube,
        vimeo,
        applePodcast,
        spotify,
        soundCloud,
        "audio/mpeg",
        "audio/mp4",
        "audio/aac",
        "audio/wav",
        "audio/x-wav",
        "audio/flac",
        "audio/ogg",
        "video/mp4",
        "video/quicktime",
        "video/x-m4v",
        "application/vnd.apple.mpegurl",
        "application/x-mpegurl",
    ]
}
#endif
