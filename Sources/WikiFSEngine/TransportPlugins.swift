#if os(macOS)
import Cordis

public enum TransportPlugin {
    public static let id = PluginID("wiki.transport")

    public static let definition = PluginDefinition(
        id: id,
        label: "Wiki transport providers",
        provisions: [ServiceDependency(TransportServiceKeys.transport)]
    ) {
        try ComponentDefinition(
            label: "wiki.transport",
            provisions: [ServiceDependency(TransportServiceKeys.transport)]
        ) { activation in
            _ = try await activation.supply(
                TransportServiceKeys.transport,
                value: TransportProviderRegistry())
        }
    }
}

public enum DaemonTransportPlugin {
    public static let id = PluginID("wiki.transport.daemon")
    public static let providerID = TransportProviderID("daemon")

    public static func definition(
        makeServices: @escaping RegisteredTransportProvider.Factory
    ) -> PluginDefinition {
        PluginDefinition(
            id: id,
            label: "Daemon transport adapter",
            dependencies: [ServiceDependency(TransportServiceKeys.transport)]
        ) {
            try ComponentDefinition(
                label: "wiki.transport.daemon",
                dependencies: [ServiceDependency(TransportServiceKeys.transport)]
            ) { activation in
                let registry = try await activation.require(TransportServiceKeys.transport)
                let registration = try await registry.register(RegisteredTransportProvider(
                    id: providerID,
                    makeServices: makeServices))
                _ = try await activation.effect { _ in
                    await registration.dispose()
                }
            }
        }
    }
}
#endif
