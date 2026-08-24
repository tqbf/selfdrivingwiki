import Cordis

public enum RenderersPlugin {
    public static let id = PluginID("wiki.renderers")

    public static let definition = PluginDefinition(
        id: id,
        label: "Wiki renderer providers",
        provisions: [ServiceDependency(RendererServiceKeys.renderers)]
    ) {
        try ComponentDefinition(
            label: "wiki.renderers",
            provisions: [ServiceDependency(RendererServiceKeys.renderers)]
        ) { activation in
            _ = try await activation.supply(
                RendererServiceKeys.renderers,
                value: RendererProviderRegistry())
        }
    }
}

public enum RendererServicesPlugin {
    public static let id = PluginID("wiki.renderer.services")
    public static let providerID = RendererProviderID("renderer-services")

    public static let definition = PluginDefinition(
        id: id,
        label: "Renderer services adapter",
        dependencies: [
            ServiceDependency(RendererServiceKeys.renderers),
            ServiceDependency(ProcessServiceKeys.renderer),
        ]
    ) {
        try ComponentDefinition(
            label: "wiki.renderer.services",
            dependencies: [
                ServiceDependency(RendererServiceKeys.renderers),
                ServiceDependency(ProcessServiceKeys.renderer),
            ]
        ) { activation in
            let registry = try await activation.require(RendererServiceKeys.renderers)
            let services = try await activation.require(ProcessServiceKeys.renderer)
            let registration = try await registry.register(RegisteredRendererProvider(
                id: providerID,
                services: services))
            _ = try await activation.effect { _ in
                await registration.dispose()
            }
        }
    }
}
