#if os(macOS)
import SwiftUI
import WikiFSCore

// pattern: Imperative Shell

/// One renderer-owned inline surface that the reader can mount without knowing
/// the renderer implementation. The reader keeps ownership of geometry,
/// admission, focus, and teardown; a renderer owns the view it supplies.
enum RendererInlineAttachmentResolution {
    case unsupported
    case content(AnyView)
    case failed
}

/// Resolves one already-admitted, exact renderer input to an inline surface.
/// `nil` is deliberately not used for failures: an unsupported renderer can
/// still be opened in the full renderer, while a failed native renderer must
/// stay failed closed in the reader.
typealias RendererInlineAttachmentResolver = @MainActor (
    RendererEmbedActivationContext,
    RendererAttachmentPlaceholderID,
    @escaping @MainActor (RendererSessionFailure) -> Void
) -> RendererInlineAttachmentResolution

/// Per-descriptor validated package resources for in-page expansion iframes.
/// The reader host builds this from `InstalledRendererFactory.Inputs`; the
/// reader webview's frame router routes only these package identities, each
/// under its own unguessable frame origin.
@MainActor
struct RendererPackageEmbedInputs {
    struct Entry {
        let descriptor: RendererDescriptor
        var reference: RendererReference { descriptor.reference }
        /// The package entry document's path within the package manifest.
        let entryPath: String
        let configuration: InstalledRendererSessionConfiguration
        let hostNavigationRouting: RendererHostNavigationRouting
        var provider: any RendererPackageResourceProviding { configuration.resourceProvider }
    }

    let entries: [Entry]

    static let unavailable = Self(entries: [])

    /// Flattens the factory inputs' per-descriptor provider lookup.
    static func make(from inputs: InstalledRendererFactory.Inputs) -> Self {
        Self(entries: inputs.availableDescriptors.compactMap { descriptor in
            guard case let .webPackage(entryPoint) = descriptor.implementation,
                  let configuration = inputs.configuration(for: descriptor) else { return nil }
            return Entry(
                descriptor: descriptor,
                entryPath: entryPoint.path.rawValue,
                configuration: configuration,
                hostNavigationRouting: inputs.hostNavigationRouting)
        })
    }
}

/// The default reader composition. It is intentionally outside
/// `WikiReaderRep.Coordinator`: adding a renderer never requires a format
/// switch in reader lifecycle code.
enum RendererInlineAttachmentResolverFactory {
    @MainActor
    static func make(
        store: WikiStore,
        installedRendererFactory: InstalledRendererFactory,
        installedRendererFactoryInputs: InstalledRendererFactory.Inputs
    ) -> RendererInlineAttachmentResolver {
        { context, placeholderID, onSessionFailure in
            resolve(
                context: context,
                placeholderID: placeholderID,
                onSessionFailure: onSessionFailure,
                store: store,
                installedRendererFactory: installedRendererFactory,
                installedRendererFactoryInputs: installedRendererFactoryInputs)
        }
    }

    @MainActor
    static func defaultResolver(
        context: RendererEmbedActivationContext,
        placeholderID: RendererAttachmentPlaceholderID,
        onSessionFailure: @escaping @MainActor (RendererSessionFailure) -> Void
    ) -> RendererInlineAttachmentResolution {
        .unsupported
    }

    @MainActor
    private static func resolve(
        context: RendererEmbedActivationContext,
        placeholderID: RendererAttachmentPlaceholderID,
        onSessionFailure: @escaping @MainActor (RendererSessionFailure) -> Void,
        store: WikiStore,
        installedRendererFactory: InstalledRendererFactory,
        installedRendererFactoryInputs: InstalledRendererFactory.Inputs
    ) -> RendererInlineAttachmentResolution {
        guard let descriptor = installedRendererFactoryInputs.availableDescriptors.first(where: {
            $0.reference == context.rendererReference
        }), descriptor.supportedEmbeddingRoles.contains(context.embeddingRole) else {
            DebugLog.reader("inline installed renderer role mismatch for \(placeholderID.rawValue)")
            return .unsupported
        }

        // Package-backed inline rendering is mounted as a DOM frame by the
        // reader. It requires asynchronous session preparation and must never
        // create a parallel full-window session from this legacy resolver.
        _ = context
        _ = store
        _ = installedRendererFactory
        _ = onSessionFailure
        return .unsupported
    }
}
#endif
