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

    /// Architecture guard, now permanent: production code constructs NO
    /// `RSSPodcastTranscriptService` anywhere. The temporary Apple
    /// `.applePodcast` fallback sites were removed when Apple transcripts
    /// moved to the reviewed apple-podcast-transcript package; both podcast
    /// source classes run through their package routes in the queue
    /// providers. This scan prevents any new legacy-service site.
    @Test("no production RSS podcast subprocess path remains")
    func noProductionRSSPodcastSubprocessPath() throws {
        let root = repositoryRoot()
        let productionRoot = root.appendingPathComponent("Sources", isDirectory: true)
        var files: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: productionRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) {
            while let candidate = enumerator.nextObject() as? URL {
                if candidate.pathExtension == "swift" { files.append(candidate) }
            }
        }
        #expect(files.isEmpty == false, "no production sources found to scan")

        for file in files {
            var contents = try String(contentsOf: file, encoding: .utf8)
            // Strip comments so prose cannot trip the scan.
            contents = contents.replacingOccurrences(
                of: #"//.*"#, with: "", options: .regularExpression)

            let pattern = "RSSPodcastTranscriptService("
            var searchStart = contents.startIndex
            var occurrences: [Range<String.Index>] = []
            while let range = contents.range(of: pattern, range: searchStart..<contents.endIndex) {
                occurrences.append(range)
                searchStart = range.upperBound
            }

            #expect(
                occurrences.isEmpty,
                "\(file.lastPathComponent) constructs RSSPodcastTranscriptService; podcast transcripts run through the package routes only")
        }
    }

    /// The reviewed Apple package's identity appears in exactly TWO host
    /// seams: the compiled reviewed-registration data (ReviewedExtractorPackages
    /// + the default-route record) and the exact-revision support grant. No
    /// general host policy may branch on the Apple package ID or the
    /// `apple-podcast-transcript` kind — routing, selection, and persistence
    /// treat it like every other package.
    @Test("no Apple kind or package policy branch outside the reviewed seams")
    func noApplePolicyBranch() throws {
        let root = repositoryRoot()
        let scanned = [
            "Sources/WikiFS",
            "Sources/wikid",
            "Sources/WikiFSCore/Store",
            "Sources/WikiFSCore/Sources",
        ]
        // Host files allowed to NAME the Apple lineage: the compiled reviewed
        // identity, the engine's exact-revision support grant, the route
        // presentation table (display data), the process service lineage
        // constants, and the neutrality test fixture itself.
        let allowedFiles: Set<String> = [
            "ReviewedExtractorPackages.swift",
            "ReviewedApplePodcastSupport.swift",
            "ExtractorPackagePluginDefinitionFactory.swift",
            "ExtractorRoutePresentation.swift",
            "ProcessExtractionServices.swift",
        ]

        var files: [URL] = []
        for directory in scanned {
            let directoryURL = root.appendingPathComponent(directory, isDirectory: true)
            guard FileManager.default.fileExists(atPath: directoryURL.path) else { continue }
            if let enumerator = FileManager.default.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]) {
                while let candidate = enumerator.nextObject() as? URL {
                    if candidate.pathExtension == "swift" { files.append(candidate) }
                }
            }
        }
        #expect(files.isEmpty == false, "no production sources found to scan")

        for file in files {
            guard allowedFiles.contains(file.lastPathComponent) == false else { continue }
            var contents = try String(contentsOf: file, encoding: .utf8)
            contents = contents.replacingOccurrences(
                of: #"//.*"#, with: "", options: .regularExpression)
            let forbidden = [
                "org.selfdrivingwiki.apple-podcast-transcript",
                ".applePodcastTranscript",
                "ReviewedApplePodcast",
            ]
            for needle in forbidden {
                #expect(
                    !contents.contains(needle),
                    "\(file.lastPathComponent) references \(needle); Apple identity is allowed only in the reviewed registration and exact-revision support seams")
            }
        }
    }
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
#endif
