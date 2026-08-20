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

/// The default reader composition. It is intentionally outside
/// `WikiReaderRep.Coordinator`: adding a renderer never requires a format
/// switch in reader lifecycle code.
enum RendererInlineAttachmentResolverFactory {
    @MainActor
    static func make(
        store: WikiStore,
        installedRendererFactory: InstalledRendererFactory,
        installedRendererFactoryInputs: InstalledRendererFactory.Inputs,
        onJSONCanvasHostAction: @escaping (JSONCanvasHostAction) -> Void
    ) -> RendererInlineAttachmentResolver {
        { context, placeholderID, onSessionFailure in
            resolve(
                context: context,
                placeholderID: placeholderID,
                onSessionFailure: onSessionFailure,
                store: store,
                installedRendererFactory: installedRendererFactory,
                installedRendererFactoryInputs: installedRendererFactoryInputs,
                onJSONCanvasHostAction: onJSONCanvasHostAction)
        }
    }

    @MainActor
    static func defaultResolver(
        context: RendererEmbedActivationContext,
        placeholderID: RendererAttachmentPlaceholderID,
        onSessionFailure: @escaping @MainActor (RendererSessionFailure) -> Void
    ) -> RendererInlineAttachmentResolution {
        resolveBuiltIn(context: context, placeholderID: placeholderID)
    }

    @MainActor
    private static func resolve(
        context: RendererEmbedActivationContext,
        placeholderID: RendererAttachmentPlaceholderID,
        onSessionFailure: @escaping @MainActor (RendererSessionFailure) -> Void,
        store: WikiStore,
        installedRendererFactory: InstalledRendererFactory,
        installedRendererFactoryInputs: InstalledRendererFactory.Inputs,
        onJSONCanvasHostAction: @escaping (JSONCanvasHostAction) -> Void
    ) -> RendererInlineAttachmentResolution {
        let builtIn = resolveBuiltIn(
            context: context,
            placeholderID: placeholderID,
            onJSONCanvasHostAction: onJSONCanvasHostAction)
        guard case .unsupported = builtIn else { return builtIn }

        guard let descriptor = installedRendererFactoryInputs.enabledDescriptors.first(where: {
            $0.reference == context.rendererReference
        }) else {
            return .unsupported
        }

        let inputReader = RendererAuthorizedInputReader(
            store: store,
            authorizedInput: context.input)
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

    @MainActor
    private static func resolveBuiltIn(
        context: RendererEmbedActivationContext,
        placeholderID: RendererAttachmentPlaceholderID,
        onJSONCanvasHostAction: @escaping (JSONCanvasHostAction) -> Void = { _ in }
    ) -> RendererInlineAttachmentResolution {
        guard context.rendererReference == BuiltInRendererReference.reference(for: .jsonCanvas),
              case .inlineArtifact(let artifact) = context.input
        else { return .unsupported }
        do {
            let factory = NativeJSONCanvasAttachmentFactory.fencedOnly()
            return .content(try factory.makeView(
                for: .fenced(artifact),
                onHostAction: onJSONCanvasHostAction))
        } catch {
            DebugLog.reader("native JSON Canvas attachment failed for \(placeholderID.rawValue): \(error)")
            return .failed
        }
    }
}
#endif
