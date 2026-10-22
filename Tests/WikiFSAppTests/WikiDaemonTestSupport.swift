#if os(macOS)
import Foundation
@testable import WikiFSCore
@testable import WikiFSEngine
@testable import wikid

@MainActor
func makeTestLauncherPair(
    extractionCoordinator: ExtractionCoordinator,
    generationGate: GenerationGate,
    providerServices: any AgentProviderServices = UnavailableAgentProviderServices()
) -> LauncherPair {
    LauncherPair(
        gate: generationGate,
        launcher: AgentLauncher(
            generationGate: generationGate,
            extractionCoordinator: extractionCoordinator,
            providerServices: providerServices
        )
    )
}

extension WikiDaemon {
    convenience init(containerDirectory: URL) {
        self.init(
            containerDirectory: containerDirectory,
            testFixtureMakeStore: { try GRDBWikiStore(databaseURL: $0) })
    }

    /// Fixture daemon with an injected extractor catalog (Phase 4): the
    /// `extractor sync/fetch` handler reads THIS catalog instead of the
    /// daemon's durable machine catalog, so a socket round trip can drive a
    /// real sync→enqueue without an installed package.
    convenience init(
        containerDirectory: URL,
        testExtractorCatalog: any ExtractorPackageCatalogReading
    ) {
        self.init(
            containerDirectory: containerDirectory,
            testFixtureMakeStore: { try GRDBWikiStore(databaseURL: $0) },
            testExtractorCatalog: testExtractorCatalog)
    }

    static func profileBackedForTesting(
        containerDirectory: URL,
        registryPersistence: DaemonRegistryPersistence = DaemonRegistryPersistence()
    ) async throws -> WikiDaemon {
        let owner = try DaemonProcessProfileOwner.production(
            containerDirectory: containerDirectory)
        let daemon = WikiDaemon(
            containerDirectory: containerDirectory,
            profileOwner: owner,
            storeBootstrap: StoreBootstrap(),
            registryPersistence: registryPersistence)
        try await daemon.start()
        return daemon
    }
}
#endif
