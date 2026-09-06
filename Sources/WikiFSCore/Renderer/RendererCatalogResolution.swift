import Foundation

/// WebKit-free source-type catalog resolution for headless profiles.
///
/// The app composes the authoritative catalog from a fully revalidated
/// ``RendererPreparation`` (``RendererRuntime.prepare``). CLI and daemon
/// processes do not boot renderer resource providers, so they project claims
/// from the same authoritative machine index instead: only validator-produced
/// records in the validated state, with safe-mode suppression removed, ever
/// contribute. A read failure degrades to the empty catalog and never blocks
/// store opening.
public enum RendererCatalogResolution {
    /// Projects claims from one machine index snapshot.
    public static func sourceTypes(from index: RendererMachineIndex) -> RegisteredRendererSourceTypes {
        RegisteredRendererSourceTypes(descriptors: index.availableDescriptorProjection)
    }

    /// Best-effort projection from the machine store at `layout`. A read
    /// failure yields the empty catalog.
    public static func sourceTypes(
        layout: RendererPackageStoreLayout
    ) async -> RegisteredRendererSourceTypes {
        let store = RendererMachineIndexStore(layout: layout)
        do {
            return sourceTypes(from: try await store.read())
        } catch {
            DebugLog.store("Renderer catalog projection failed; keeping empty catalog. \(error)")
            return .none
        }
    }

    /// Best-effort projection from the production machine store layout.
    public static func productionSourceTypes() async -> RegisteredRendererSourceTypes {
        do {
            let layout = try RendererPackageStoreLayout.production()
            return await sourceTypes(layout: layout)
        } catch {
            DebugLog.store("Renderer catalog layout unavailable; keeping empty catalog. \(error)")
            return .none
        }
    }
}
