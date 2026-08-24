import Cordis
import WikiFSCore

public enum SystemPromptPlugin {
    public static let id = PluginID("wiki.system-prompt")
    public static let baseSectionID = PromptSectionID("wiki.base-system-prompt")

    public static let definition = PluginDefinition(
        id: id,
        label: "Wiki system prompt",
        provisions: [ServiceDependency(PromptServiceKeys.systemPrompt)]
    ) {
        try ComponentDefinition(
            label: "wiki.system-prompt",
            provisions: [ServiceDependency(PromptServiceKeys.systemPrompt)]
        ) { activation in
            let service = SystemPromptService()
            _ = try await service.register(PromptSection(
                id: baseSectionID,
                order: 0,
                content: SystemPrompt.defaultBody))
            _ = try await activation.supply(PromptServiceKeys.systemPrompt, value: service)
        }
    }
}
