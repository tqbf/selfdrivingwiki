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

    static func profileBackedForTesting(containerDirectory: URL) async throws -> WikiDaemon {
        let owner = try DaemonProcessProfileOwner.production(
            containerDirectory: containerDirectory,
            makeLocalExtractor: { await MainActor.run { UnavailablePdf2MarkdownExtractor() } })
        let daemon = WikiDaemon(
            containerDirectory: containerDirectory,
            profileOwner: owner,
            storeBootstrap: StoreBootstrap())
        try await daemon.start()
        return daemon
    }
}
#endif
