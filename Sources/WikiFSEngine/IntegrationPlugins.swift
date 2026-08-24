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

/// Non-secret Zotero plugin configuration. The API key remains in an injected
/// credential source; this schema records only whether that source is expected
/// to provide a key when the lazy factory is invoked.
public struct ZoteroIntegrationConfig: PluginConfig, Equatable {
    public static let defaultAPIBaseURL = "https://api.zotero.org"

    public let apiBaseURL: String
    public let hasAPIKey: Bool

    public init(apiBaseURL: String = defaultAPIBaseURL, hasAPIKey: Bool) {
        self.apiBaseURL = apiBaseURL
        self.hasAPIKey = hasAPIKey
    }

    private enum CodingKeys: String, CodingKey {
        case apiBaseURL
        case hasAPIKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apiBaseURL = try container.decodeIfPresent(String.self, forKey: .apiBaseURL)
            ?? Self.defaultAPIBaseURL
        hasAPIKey = try container.decode(Bool.self, forKey: .hasAPIKey)
    }

    public static func validate(_ config: Self) -> [ConfigIssue] {
        var validation = ConfigValidation()
        let url = URL(string: config.apiBaseURL)
        validation.check(
            "apiBaseURL",
            url?.scheme == "https" && url?.host?.isEmpty == false,
            "apiBaseURL must be an absolute HTTPS URL")
        validation.check(
            "hasAPIKey",
            config.hasAPIKey,
            "an API key must be available from the injected credential source")
        return validation.allIssues
    }
}

public enum ZoteroIntegrationPlugin {
    public typealias Factory = @Sendable (_ apiBaseURL: URL) async throws -> any Sendable

    public static let id = PluginID("wiki.integration.zotero")
    public static let capabilityID = IntegrationCapabilityID("zotero")

    public static func definition(makeClient: @escaping Factory) -> PluginDefinition {
        PluginDefinition(
            id: id,
            label: "Zotero integration adapter",
            dependencies: [ServiceDependency(IntegrationServiceKeys.capabilities)],
            config: ZoteroIntegrationConfig.self
        ) { config in
            try ComponentDefinition(
                label: "wiki.integration.zotero",
                dependencies: [ServiceDependency(IntegrationServiceKeys.capabilities)]
            ) { activation in
                let registry = try await activation.require(IntegrationServiceKeys.capabilities)
                // Config validation guarantees this conversion before activation.
                guard let baseURL = URL(string: config.apiBaseURL) else {
                    throw CordisFailure("validated Zotero API base URL became invalid")
                }
                let registration = try await registry.register(RegisteredIntegrationCapability(
                    id: capabilityID,
                    makeEntryPoint: { try await makeClient(baseURL) }))
                _ = try await activation.effect { _ in
                    await registration.dispose()
                }
            }
        }
    }
}

public enum PodcastIntegrationPlugin {
    public static let id = PluginID("wiki.integration.podcast")
    public static let capabilityID = IntegrationCapabilityID("podcast")

    public static func definition(
        makeIngestion: @escaping RegisteredIntegrationCapability.Factory
    ) -> PluginDefinition {
        capabilityDefinition(
            pluginID: id,
            label: "Podcast ingestion adapter",
            componentLabel: "wiki.integration.podcast",
            capabilityID: capabilityID,
            factory: makeIngestion)
    }
}

public enum URLFetchIntegrationPlugin {
    public static let id = PluginID("wiki.integration.url-fetch")
    public static let capabilityID = IntegrationCapabilityID("url-fetch")

    public static func definition(
        makeFetcher: @escaping RegisteredIntegrationCapability.Factory
    ) -> PluginDefinition {
        capabilityDefinition(
            pluginID: id,
            label: "URL fetch integration adapter",
            componentLabel: "wiki.integration.url-fetch",
            capabilityID: capabilityID,
            factory: makeFetcher)
    }
}

private func capabilityDefinition(
    pluginID: PluginID,
    label: String,
    componentLabel: String,
    capabilityID: IntegrationCapabilityID,
    factory: @escaping RegisteredIntegrationCapability.Factory
) -> PluginDefinition {
    PluginDefinition(
        id: pluginID,
        label: label,
        dependencies: [ServiceDependency(IntegrationServiceKeys.capabilities)]
    ) {
        try ComponentDefinition(
            label: componentLabel,
            dependencies: [ServiceDependency(IntegrationServiceKeys.capabilities)]
        ) { activation in
            let registry = try await activation.require(IntegrationServiceKeys.capabilities)
            let registration = try await registry.register(RegisteredIntegrationCapability(
                id: capabilityID,
                makeEntryPoint: factory))
            _ = try await activation.effect { _ in
                await registration.dispose()
            }
        }
    }
}
