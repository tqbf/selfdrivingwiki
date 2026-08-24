import WikiFSEngine

func useWikiFacade(_ services: AppServices) async throws {
    _ = services.store
    _ = services.readService
    _ = services.extractionBackends
    _ = services.searchProviders
    _ = services.launcherFactory
    _ = services.searchFactory
    try await services.shutdown()
}

func useProcessFacade(_ services: AppProcessServices) {
    _ = services.agentProvider
    _ = services.extraction
    _ = services.queue
    _ = services.transport
    _ = services.renderer
}

func useLifetime(_ lifetime: ProfileLifetime) async throws {
    try await lifetime.shutdown()
}
