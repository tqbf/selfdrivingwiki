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
        let reference: RendererReference
        /// The package entry document's path within the package manifest.
        let entryPath: String
        let provider: any RendererPackageResourceProviding
        /// Admitted asset reader for the package session (nil when the
        /// descriptor declares no assets).
        let assetReader: RendererAuthorizedAssetReader?
    }

    let entries: [Entry]

    static let unavailable = Self(entries: [])

    /// Flattens the factory inputs' per-descriptor provider lookup.
    static func make(from inputs: InstalledRendererFactory.Inputs) -> Self {
        Self(entries: inputs.enabledDescriptors.compactMap { descriptor in
            guard let resolved = inputs.resourceProvider(for: descriptor) else { return nil }
            return Entry(
                reference: descriptor.reference,
                entryPath: resolved.entryPath,
                provider: resolved.provider,
                assetReader: resolved.assetReader)
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
        guard let descriptor = installedRendererFactoryInputs.enabledDescriptors.first(where: {
            $0.reference == context.rendererReference
        }), descriptor.supportedEmbeddingRoles.contains(context.embeddingRole) else {
            DebugLog.reader("inline installed renderer role mismatch for \(placeholderID.rawValue)")
            return .unsupported
        }

        let inputReader: RendererAuthorizedInputReader
        do {
            if case .source(let source) = context.identity {
                inputReader = try RendererAuthorizedInputReader(
                    store: store,
                    authorizedInput: context.input,
                    admittedSource: source)
            } else {
                inputReader = RendererAuthorizedInputReader(
                    store: store,
                    authorizedInput: context.input)
            }
        } catch {
            DebugLog.reader("inline installed renderer input admission failed for \(placeholderID.rawValue)")
            return .failed
        }
        guard let view = installedRendererFactory.makeView(
            for: descriptor,
            inputs: installedRendererFactoryInputs,
            inputReader: inputReader,
            onFailure: onSessionFailure)
        else {
            DebugLog.reader("inline installed renderer could not be created for \(placeholderID.rawValue)")
            return .failed
        }
        return .content(view)
    }
}
#endif
