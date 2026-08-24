#if os(macOS)
import Cordis
import CordisLoader
import Testing
@testable import WikiFSEngine

@Suite("Tools plugin boot", .serialized, .timeLimit(.minutes(1)))
struct ToolsPluginBootTests {
    @Test("registered tool executes through guarded waterfalls and unloads")
    func registeredToolExecutesAndUnloads() async throws {
        let recorder = ToolPipelineRecorder()
        let observerID = PluginID("test.tool-pipeline-observer")
        let observer = PluginDefinition(
            id: observerID,
            dependencies: [ServiceDependency(ToolServiceKeys.tools)]
        ) {
            try ComponentDefinition(
                label: "test.tool-pipeline-observer",
                dependencies: [ServiceDependency(ToolServiceKeys.tools)]
            ) { activation in
                _ = try await activation.require(ToolServiceKeys.tools)
                _ = try await activation.on(ToolEventKeys.preExecute) { _, next in
                    await recorder.record("pre")
                    return try await next()
                }
                _ = try await activation.on(ToolEventKeys.postExecute) { context, next in
                    let context = try await next()
                    await recorder.record("post")
                    return context
                }
            }
        }
        let toolsEntry = Entry(id: EntryID("tools"), plugin: ToolsPlugin.id)
        let noOpEntry = Entry(id: EntryID("no-op-tool"), plugin: NoOpToolPlugin.id)
        let observerEntry = Entry(id: EntryID("tool-observer"), plugin: observerID)
        let booted = try await CordisBoot.boot(CordisBoot.Options(
            catalog: try PluginCatalog([
                ToolsPlugin.definition,
                NoOpToolPlugin.definition,
                observer,
            ]),
            layers: [PatchFile(entries: [toolsEntry, noOpEntry, observerEntry])]))

        let runtime = try #require(try await booted.context.find(ToolServiceKeys.tools))
        let result = try await runtime.execute(
            name: NoOpToolPlugin.toolName,
            payload: #"{"observed":false}"#)
        #expect(result == #"{"observed":false}"#)
        #expect(await recorder.events == ["pre", "post"])

        try await booted.tree.update(to: [toolsEntry, observerEntry])
        #expect(await runtime.registry.resolve(NoOpToolPlugin.toolName) == nil)

        try await booted.shutdown()
    }
}

private actor ToolPipelineRecorder {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}
#endif
