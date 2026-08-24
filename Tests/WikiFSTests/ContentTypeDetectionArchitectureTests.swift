import Foundation
import Testing

struct ContentTypeDetectionArchitectureTests {
    @Test func noIndependentMIMEPolicyOutsideDetector() throws {
        let root = try #require(locateRepoRoot())
        let sourceRoot = root.appendingPathComponent("Sources")
        let enumerator = try #require(FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: nil))
        let allowedUTIFiles: Set<String> = [
            "Sources/WikiFSCore/Integrations/WebsiteSnapshotExtractor.swift",
            "Sources/WikiFSCore/Sources/SourceMaterializer.swift",
            "Sources/WikiFSCore/Store/GRDBWikiStore.swift",
            "Sources/WikiFSCore/Store/WikiStoreModel.swift",
        ]
        var findings: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let source = try String(contentsOf: url, encoding: .utf8)
            if source.contains("ContentSniff.mimeType") { findings.append("\(relative): ContentSniff") }
            if source.contains("shouldSniff(") { findings.append("\(relative): shouldSniff") }
            if source.contains("FormatMaterializer.normalizedMIME") { findings.append("\(relative): private normalizer") }
            let hasUTIPolicy = source.split(separator: "\n").contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && trimmed.contains("preferredMIMEType")
            }
            if hasUTIPolicy, !allowedUTIFiles.contains(relative) {
                findings.append("\(relative): unapproved UTI MIME policy")
            }
            if source.contains("ContentSniff") && relative != "Sources/WikiFSTypes/MimeType.swift" {
                findings.append("\(relative): stale ContentSniff reference")
            }
        }
        #expect(findings.isEmpty, "Independent MIME policy found:\n\(findings.joined(separator: "\n"))")
    }

    @Test func allByteBearingWritersUseDetectionHintsOrDetectedResult() throws {
        let root = try #require(locateRepoRoot())
        struct WriterManifestEntry {
            let path: String
            let declarations: [(anchor: String, count: Int)]
            let testFunctions: [String]
        }
        let inventory: [WriterManifestEntry] = [
            .init(
                path: "Sources/WikiFSCore/Store/GRDBWikiStore.swift",
                declarations: [
                    ("public func addSource(", 3),
                    ("public func appendContentVersion(", 2),
                    ("public func addSnapshotImage(", 2),
                ],
                testFunctions: [
                    "GRDBAddAppendAndSnapshotImageRedetectAtFinalBoundary",
                    "typedAddSourceUsesFilenameUTIFallback",
                ]),
            .init(
                path: "Sources/WikiFSCore/Store/WikiStoreModel.swift",
                declarations: [
                    ("func storeMaterialized(", 1),
                    ("private func storeSnapshot(", 1),
                    ("private func performRefresh(", 1),
                    ("public func addSource(filename: String, data: Data)", 1),
                ],
                testFunctions: [
                    "localWebsiteZoteroAndMarkdownFolderShareDetectorPolicy",
                    "snapshotStoresPageAndImagesWithSharedActivity",
                    "websiteRefreshPreservesDeclaredMIMEHints",
                ]),
            .init(
                path: "Sources/WikiCtlCore/SourceCommand.swift",
                declarations: [
                    ("public static func runAddURL(", 1),
                    ("static func persistRefreshMaterial(", 1),
                ],
                testFunctions: ["sourceCommandAddAndRefreshPreserveDetectionPolicy"]),
            .init(
                path: "Sources/WikiFSCore/Sources/SourceMaterializer.swift",
                declarations: [
                    ("public struct LocalFileMaterializer", 1),
                    ("public struct WebsiteMaterializer", 1),
                    ("public struct ZoteroMaterializer", 1),
                    ("public struct MarkdownFolderMaterializer", 1),
                ],
                testFunctions: ["localWebsiteZoteroAndMarkdownFolderShareDetectorPolicy"]),
            .init(
                path: "Sources/WikiFSCore/Integrations/WebsiteSnapshotExtractor.swift",
                declarations: [("public static func detection(", 1)],
                testFunctions: [
                    "convertedMarkdownCarriesRelativeSrcs",
                    "snapshotStoresPageAndImagesWithSharedActivity",
                ]),
        ]

        var findings: [String] = []
        for entry in inventory {
            let source = try String(
                contentsOf: root.appendingPathComponent(entry.path),
                encoding: .utf8)
            for declaration in entry.declarations {
                let actual = source.components(separatedBy: declaration.anchor).count - 1
                if actual != declaration.count {
                    findings.append(
                        "\(entry.path): expected \(declaration.count) occurrences of " +
                        "\(declaration.anchor), found \(actual)")
                }
            }
            for functionName in entry.testFunctions where try !testFunctionExists(named: functionName, under: root) {
                findings.append("\(entry.path): missing behavioral test function \(functionName)")
            }
        }
        #expect(findings.isEmpty, "Byte-bearing writer inventory changed:\n\(findings.joined(separator: "\n"))")
    }

    @Test func detectorRemainsPureAndCordisFree() throws {
        let root = try #require(locateRepoRoot())
        let detectorPath = "Sources/WikiFSCore/Sources/ContentSniff.swift"
        let detector = try String(
            contentsOf: root.appendingPathComponent(detectorPath),
            encoding: .utf8)
        #expect(!detector.contains("import Cordis"))
        #expect(!detector.contains("ServiceKey"))
        #expect(!detector.contains("ComponentDefinition"))

        let sourceRoot = root.appendingPathComponent("Sources")
        let enumerator = try #require(FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: nil))
        var findings: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let source = try String(contentsOf: url, encoding: .utf8)
            let compact = source.lowercased()
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "-", with: "")
            let detectorReferences = [
                "contenttypedetector",
                "contenttypedetectionresult",
                "contenttypedetectionhints",
                "contentdetectionservice",
                "mimedetectionservice",
                "mimepolicyservice",
            ]
            let cordisConstructs = ["ServiceKey", "ComponentDefinition", "CordisContext"]
            if relative != detectorPath,
               detectorReferences.contains(where: compact.contains),
               cordisConstructs.contains(where: source.contains) {
                findings.append("\(relative): content detection coupled to Cordis")
            }
        }
        #expect(findings.isEmpty, "Content detection must remain pure policy:\n\(findings.joined(separator: "\n"))")
    }

    @Test func canonicalStoreBoundaryUsesTypedHintsAndNeutralMetadata() throws {
        let root = try #require(locateRepoRoot())
        let storeProtocol = try String(
            contentsOf: root.appendingPathComponent("Sources/WikiFSCore/Store/WikiStore.swift"),
            encoding: .utf8)
        let sourceMaterializer = try String(
            contentsOf: root.appendingPathComponent("Sources/WikiFSCore/Sources/SourceMaterializer.swift"),
            encoding: .utf8)
        let model = try String(
            contentsOf: root.appendingPathComponent("Sources/WikiFSCore/Store/WikiStoreModel.swift"),
            encoding: .utf8)
        let command = try String(
            contentsOf: root.appendingPathComponent("Sources/WikiCtlCore/SourceCommand.swift"),
            encoding: .utf8)

        #expect(!storeProtocol.contains("zoteroItemKey:"))
        #expect(!storeProtocol.contains("zoteroItemTitle:"))
        #expect(!storeProtocol.contains("data: Data, mimeType: String?"))
        #expect(storeProtocol.contains("detectionHints: ContentTypeDetectionHints"))
        #expect(storeProtocol.contains("ingestMetadata: SourceIngestMetadata?"))
        #expect(!model.contains("zoteroItemKey: nil, zoteroItemTitle:"))
        #expect(!command.contains("zoteroItemKey: nil, zoteroItemTitle:"))
        #expect(sourceMaterializer.contains("externalItemID: String?"))
        #expect(sourceMaterializer.contains("externalItemTitle: String?"))
    }

    private func testFunctionExists(named functionName: String, under root: URL) throws -> Bool {
        let testRoot = root.appendingPathComponent("Tests")
        let enumerator = try #require(FileManager.default.enumerator(
            at: testRoot,
            includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            if source.contains("@Test func \(functionName)(") { return true }
        }
        return false
    }

    private func locateRepoRoot() -> URL? {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return nil
    }
}
