#if os(macOS)
import Foundation
import Testing

@Suite("Extraction composition boundaries", .timeLimit(.minutes(1)))
struct ExtractionCompositionBoundaryTests {
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
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
#endif
