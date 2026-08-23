import Cordis
import Foundation

public struct ACPModelAdapterConfig: PluginConfig, Equatable {
    public let route: String
    public let adapterID: String

    public init(route: String, adapterID: String) {
        self.route = route
        self.adapterID = adapterID
    }

    public static func validate(_ config: ACPModelAdapterConfig) -> [ConfigIssue] {
        var validation = ConfigValidation()
        validation.check(
            "route",
            !config.route.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "route must not be empty")
        validation.check(
            "adapterID",
            !config.adapterID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "adapter id must not be empty")
        return validation.allIssues
    }
}

public enum LlmRuntimePlugin {
    public static let id = PluginID("wiki.llm-runtime")

    public static let definition = PluginDefinition(
        id: id,
        label: "Wiki LLM runtime",
        provisions: [ServiceDependency(LlmServiceKeys.llm)]
    ) {
        try ComponentDefinition(
            label: "wiki.llm-runtime",
            provisions: [ServiceDependency(LlmServiceKeys.llm)]
        ) { activation in
            _ = try await activation.supply(LlmServiceKeys.llm, value: LlmRuntime())
        }
    }
}

public enum ACPModelAdapterPlugin {
    public static let id = PluginID("wiki.llm-acp-adapter")

    /// Creates an ACP adapter plugin backed by the existing provider facade.
    /// The facade is an assembly input, not serializable plugin configuration:
    /// credentials, command resolution, and backend factories stay behind it.
    public static func definition(
        services: any AgentProviderServices
    ) -> PluginDefinition {
        PluginDefinition(
            id: id,
            label: "Wiki ACP model adapter",
            dependencies: [ServiceDependency(LlmServiceKeys.llm)],
            config: ACPModelAdapterConfig.self
        ) { config in
            try ComponentDefinition(
                label: "wiki.llm-acp-adapter",
                dependencies: [ServiceDependency(LlmServiceKeys.llm)]
            ) { activation in
                let runtime = try await activation.require(LlmServiceKeys.llm)
                let registration = try await runtime.register(
                    route: LlmRoute(config.route),
                    adapter: LlmAdapter(id: LlmAdapterID(config.adapterID), services: services))
                _ = try await activation.effect { _ in
                    await registration.dispose()
                }
            }
        }
    }
}
