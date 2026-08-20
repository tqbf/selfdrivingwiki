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
