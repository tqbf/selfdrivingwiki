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

    /// Temporary architecture guard for the Apple TTML follow-up. Production
    /// code must not construct `RSSPodcastTranscriptService` outside the three
    /// known `.applePodcast` fallback sites. Public behavior tests cover RSS
    /// queue routing. This source scan only prevents a new legacy-service site.
    @Test("no production RSS podcast subprocess path outside the Apple fallback sites")
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

        // The exact allow-list: each construction site must appear in one of
        // these files, inside its `.applePodcast` arm, and each file may
        // carry at most the pinned count of constructions.
        let allowList: [String: Int] = [
            "AppQueueExtractionProvider.swift": 1,
            "DaemonQueueExtractionProvider.swift": 1,
            "WikiStoreModel.swift": 1,
        ]

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

            guard occurrences.isEmpty == false else { continue }
            let fileName = file.lastPathComponent
            let allowedCount = allowList[fileName] ?? 0
            #expect(
                occurrences.count <= allowedCount,
                "\(fileName) constructs RSSPodcastTranscriptService \(occurrences.count) time(s); only the allow-listed .applePodcast fallback sites are permitted")

            // Every allowed site must sit inside an `.applePodcast` context:
            // either the nearest preceding provider `case .applePodcast:`
            // marker is closer than any other provider case marker, or (for
            // WikiStoreModel) the site sits inside the `transcribePodcast`
            // helper, which only the `.applePodcast` dispatch arm reaches.
            for range in occurrences {
                let prefix = contents[..<range.lowerBound]
                let appleMarker = prefix.range(of: "case .applePodcast:", options: .backwards)
                let otherMarkers = ["case .youtube:", "case .podcast:", "case .website:",
                                    "case .localFile:", "case .vimeo:"].compactMap {
                    prefix.range(of: $0, options: .backwards)
                }
                let nearestOther = otherMarkers.max { $0.lowerBound < $1.lowerBound }
                let insideAppleSwitch = appleMarker.map { apple in
                    nearestOther.map { $0.lowerBound < apple.lowerBound } ?? true
                } ?? false
                var insideTranscribePodcastHelper = false
                if fileName == "WikiStoreModel.swift" {
                    let helper = prefix.range(of: "func transcribePodcast(", options: .backwards)
                    let nextHelper = prefix.range(of: "private func transcribeYouTube(", options: .backwards)
                    if let helper {
                        insideTranscribePodcastHelper = nextHelper.map { helper.lowerBound < $0.lowerBound } ?? true
                    }
                }
                if !insideAppleSwitch && !insideTranscribePodcastHelper {
                    Issue.record(
                        "\(fileName) constructs RSSPodcastTranscriptService outside its .applePodcast arm")
                }
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
