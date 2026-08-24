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
    public static let id = PluginID("wiki.integration.zotero")
    public static let capabilityID = IntegrationCapabilityID("zotero")

    public static let definition = PluginDefinition(
        id: id,
        label: "Zotero integration adapter",
        dependencies: [
            ServiceDependency(IntegrationServiceKeys.capabilities),
            ServiceDependency(ProcessServiceKeys.zoteroClientProvider),
        ],
        config: ZoteroIntegrationConfig.self
    ) { config in
        try ComponentDefinition(
            label: "wiki.integration.zotero",
            dependencies: [
                ServiceDependency(IntegrationServiceKeys.capabilities),
                ServiceDependency(ProcessServiceKeys.zoteroClientProvider),
            ]
        ) { activation in
            let registry = try await activation.require(IntegrationServiceKeys.capabilities)
            let clientProvider = try await activation.require(ProcessServiceKeys.zoteroClientProvider)
            // Config validation guarantees this conversion before activation.
            guard let baseURL = URL(string: config.apiBaseURL) else {
                throw CordisFailure("validated Zotero API base URL became invalid")
            }
            let registration = try await registry.register(RegisteredIntegrationCapability(
                id: capabilityID,
                makeEntryPoint: { .zotero(try clientProvider.client(apiBaseURL: baseURL)) }))
            _ = try await activation.effect { _ in
                await registration.dispose()
            }
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
