import Cordis

public enum ToolsPlugin {
    public static let id = PluginID("wiki.tools")

    public static let definition = PluginDefinition(
        id: id,
        label: "Wiki tools",
        provisions: [ServiceDependency(ToolServiceKeys.tools)]
    ) {
        try ComponentDefinition(
            label: "wiki.tools",
            provisions: [ServiceDependency(ToolServiceKeys.tools)]
        ) { activation in
            let registry = ToolRegistry()
            _ = try await activation.on(ToolEventKeys.execute) { context, next in
                var context = try await next()
                guard context.result == nil else { return context }
                guard let tool = await registry.resolve(context.name) else {
                    throw ToolRuntimeError.unknownTool(context.name)
                }
                context.result = try await tool.execute(payload: context.payload)
                return context
            }
            let runtime = ToolRuntime(registry: registry) { key, context in
                try await activation.waterfall(key, context)
            }
            _ = try await activation.supply(ToolServiceKeys.tools, value: runtime)
        }
    }
}

/// Fixture-safe adapter demonstrating component-owned reversible tool
/// registration without changing the existing provider-owned agent path.
public enum NoOpToolPlugin {
    public static let id = PluginID("wiki.tool.no-op")
    public static let toolName = ToolName("no-op")

    public static let definition = PluginDefinition(
        id: id,
        label: "Wiki no-op tool",
        dependencies: [ServiceDependency(ToolServiceKeys.tools)]
    ) {
        try ComponentDefinition(
            label: "wiki.tool.no-op",
            dependencies: [ServiceDependency(ToolServiceKeys.tools)]
        ) { activation in
            let runtime = try await activation.require(ToolServiceKeys.tools)
            let registration = try await runtime.registry.register(RegisteredTool(
                descriptor: ToolDescriptor(
                    name: toolName,
                    description: "Returns its JSON payload unchanged.",
                    inputSchema: #"{"type":"object"}"#),
                execute: { payload in payload }))
            _ = try await activation.effect { _ in
                await registration.dispose()
            }
        }
    }
}
