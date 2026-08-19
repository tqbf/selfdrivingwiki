#if os(macOS)
import Foundation
import Testing

@Suite("Extraction composition boundaries", .timeLimit(.minutes(1)))
struct ExtractionCompositionBoundaryTests {
    @Test("app creates one facade before queue and session composition")
    func appUsesOneExtractionFacade() throws {
        let source = try productionSource("Sources/WikiFS/Window/WikiFSApp.swift")

        #expect(source.occurrences(of: "let extractionOwner = ExtractionCompositionOwner") == 1)
        #expect(source.contains("let extractionServices = extractionOwner.services"))
        #expect(source.contains("ExtractionCoordinator(services: extractionServices)"))
        #expect(source.contains("extractionServices: extractionServices"))
        #expect(!source.contains("ExtractionCoordinator(\n            containerDirectory:"))
    }

    @Test("daemon creates one facade for queue, ingestion, and chat")
    func daemonUsesOneExtractionFacade() throws {
        let source = try productionSource("Sources/wikid/WikiDaemon.swift")

        #expect(source.occurrences(of: "ExtractionCompositionOwner(") == 1)
        #expect(source.contains("let extractionServices = extractionCompositionOwner.services"))
        #expect(source.contains("extractionServices: extractionServices"))
        #expect(source.contains("ExtractionCoordinator(services: extractionServices)"))
        #expect(!source.contains("ExtractionCoordinator(\n                containerDirectory:"))
    }

    @Test("old backend construction paths are absent")
    func oldBackendConstructionPathsAreAbsent() throws {
        let root = repositoryRoot()
        let paths = [
            "Sources/WikiFS/Sources/SourceDetailView.swift",
            "Sources/WikiFS/Queue/AppQueueExtractionProvider.swift",
            "Sources/wikid/DaemonQueueExtractionProvider.swift",
        ]
        let source = try paths.map { path in
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }.joined(separator: "\n")

        #expect(!source.contains("extractorFor("))
        #expect(!source.contains("extractionCoordinator.current()"))
        #expect(!source.contains("extractionCoordinator.config"))
        #expect(!source.contains("extractionCoordinator.credentialStore"))
        #expect(!source.contains("extractionCoordinator.fetcher"))
    }

    @Test("shutdown order stops queue before extraction disposal")
    func shutdownOrderIsExplicit() throws {
        let app = try productionSource("Sources/WikiFS/Window/WikiFSApp.swift")
        let daemon = try productionSource("Sources/wikid/WikiDaemon.swift")

        let appQueue = try #require(app.range(of: "await localQueueRuntimeController.dispose()"))
        let appExtraction = try #require(app.range(of: "await extractionCompositionOwner.shutdown()"))
        #expect(appQueue.lowerBound < appExtraction.lowerBound)

        let daemonQueue = try #require(daemon.range(of: "daemonQueueHost.relinquish"))
        let daemonExtraction = try #require(daemon.range(of: "extractionCompositionOwner.shutdown()"))
        #expect(daemonQueue.lowerBound < daemonExtraction.lowerBound)
    }
}

private extension String {
    func occurrences(of needle: String) -> Int {
        components(separatedBy: needle).count - 1
    }
}

private func productionSource(_ path: String) throws -> String {
    try String(contentsOf: repositoryRoot().appendingPathComponent(path), encoding: .utf8)
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
#endif
