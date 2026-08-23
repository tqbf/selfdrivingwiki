#if os(macOS)
import Cordis
import CordisLoader
import Testing
import WikiFSCore
@testable import WikiFSEngine

@Suite("System prompt plugin boot", .serialized, .timeLimit(.minutes(1)))
struct PromptPluginBootTests {
    @Test("base prompt and reversible contribution assemble in order")
    func basePromptAndReversibleContributionAssembleInOrder() async throws {
        let contributorID = PluginID("test.prompt-contributor")
        let contributedSectionID = PromptSectionID("test.prompt-section")
        let contributedContent = "# Test prompt contribution"
        let contributor = PluginDefinition(
            id: contributorID,
            dependencies: [ServiceDependency(PromptServiceKeys.systemPrompt)]
        ) {
            try ComponentDefinition(
                label: "test.prompt-contributor",
                dependencies: [ServiceDependency(PromptServiceKeys.systemPrompt)]
            ) { activation in
                let service = try await activation.require(PromptServiceKeys.systemPrompt)
                let registration = try await service.register(PromptSection(
                    id: contributedSectionID,
                    order: 100,
                    content: contributedContent))
                _ = try await activation.effect { _ in
                    await registration.dispose()
                }
            }
        }
        let promptEntry = Entry(id: EntryID("system-prompt"), plugin: SystemPromptPlugin.id)
        let contributorEntry = Entry(id: EntryID("prompt-contributor"), plugin: contributorID)
        let booted = try await CordisBoot.boot(CordisBoot.Options(
            catalog: try PluginCatalog([
                SystemPromptPlugin.definition,
                contributor,
            ]),
            layers: [PatchFile(entries: [promptEntry])]))

        let service = try #require(try await booted.context.find(PromptServiceKeys.systemPrompt))
        let basePrompt = await service.assemble()
        #expect(basePrompt == SystemPrompt.defaultBody)
        #expect(await service.sections().map(\.id) == [SystemPromptPlugin.baseSectionID])

        try await booted.tree.update(to: [promptEntry, contributorEntry])
        let contributedPrompt = await service.assemble()
        let baseRange = try #require(contributedPrompt.range(of: SystemPrompt.defaultBody))
        let contributionRange = try #require(contributedPrompt.range(of: contributedContent))
        #expect(baseRange.lowerBound < contributionRange.lowerBound)

        try await booted.tree.update(to: [promptEntry])
        #expect(await service.assemble() == SystemPrompt.defaultBody)

        try await booted.shutdown()
    }
}
#endif
