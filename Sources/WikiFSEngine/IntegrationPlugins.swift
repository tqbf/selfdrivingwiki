import Cordis
import Foundation

public enum IntegrationsPlugin {
    public static let id = PluginID("wiki.integrations")

    public static let definition = PluginDefinition(
        id: id,
        label: "Wiki integration capabilities",
        provisions: [ServiceDependency(IntegrationServiceKeys.capabilities)]
    ) {
        try ComponentDefinition(
            label: "wiki.integrations",
            provisions: [ServiceDependency(IntegrationServiceKeys.capabilities)]
        ) { activation in
            _ = try await activation.supply(
                IntegrationServiceKeys.capabilities,
                value: IntegrationCapabilityRegistry())
        }
    }
}

public enum URLFetchIntegrationPlugin {
    public static let id = PluginID("wiki.integration.url-fetch")
    public static let capabilityID = IntegrationCapabilityID("url-fetch")

    public static let definition = PluginDefinition(
        id: id,
        label: "URL fetch integration adapter",
        dependencies: [
            ServiceDependency(IntegrationServiceKeys.capabilities),
            ServiceDependency(ProcessServiceKeys.urlFetchProvider),
        ]
    ) {
        try ComponentDefinition(
            label: "wiki.integration.url-fetch",
            dependencies: [
                ServiceDependency(IntegrationServiceKeys.capabilities),
                ServiceDependency(ProcessServiceKeys.urlFetchProvider),
            ]
        ) { activation in
            let registry = try await activation.require(IntegrationServiceKeys.capabilities)
            let fetchProvider = try await activation.require(ProcessServiceKeys.urlFetchProvider)
            let registration = try await registry.register(RegisteredIntegrationCapability(
                id: capabilityID,
                makeEntryPoint: { .urlFetch(try await fetchProvider.fetcher()) }))
            _ = try await activation.effect { _ in
                await registration.dispose()
            }
        }
    }
}
