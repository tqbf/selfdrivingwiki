import Cordis

public enum AgentLoopPlugin {
    public static let id = PluginID("wiki.agent-loop")

    public static let definition = PluginDefinition(
        id: id,
        label: "Wiki agent loop",
        dependencies: [ServiceDependency(SessionServiceKeys.sessions)],
        provisions: [ServiceDependency(AgentLoopServiceKeys.agentLoop)]
    ) {
        try ComponentDefinition(
            label: "wiki.agent-loop",
            dependencies: [ServiceDependency(SessionServiceKeys.sessions)],
            provisions: [ServiceDependency(AgentLoopServiceKeys.agentLoop)]
        ) { activation in
            let sessions = try await activation.require(SessionServiceKeys.sessions)
            _ = try await activation.on(AgentLoopEventKeys.turnStarted) { event in
                guard event.request.projectsToSessionLog else { return }
                await sessions.append(chatID: event.request.chatID, events: event.sessionEvents)
            }
            _ = try await activation.on(AgentLoopEventKeys.stepCompleted) { event in
                guard event.projectsToSessionLog else { return }
                await sessions.append(chatID: event.chatID, events: event.events)
            }
            _ = try await activation.on(AgentLoopEventKeys.turnCompleted) { event in
                guard event.projectsToSessionLog else { return }
                await sessions.append(chatID: event.chatID, events: event.sessionEvents)
            }
            let service = AgentLoopService(
                emitTurnStarted: { key, payload in
                    await activation.emit(key, payload)
                },
                emitStepCompleted: { key, payload in
                    await activation.emit(key, payload)
                },
                emitTurnCompleted: { key, payload in
                    await activation.emit(key, payload)
                },
                waterfall: { key, payload in
                    try await activation.waterfall(key, payload)
                })
            _ = try await activation.supply(AgentLoopServiceKeys.agentLoop, value: service)
        }
    }
}
