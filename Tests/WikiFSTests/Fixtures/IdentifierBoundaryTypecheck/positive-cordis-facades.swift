import WikiFSEngine

func useWikiFacade(_ services: AppServices) async throws {
    _ = services.store
    _ = services.extractionBackends
    _ = services.launcherFactory
    // P5: `readService` / `searchProviders` / `searchFactory` are gone from
    // the facade — the read-only pool left app composition and the daemon
    // builds its search runtime from the admitted store.
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
