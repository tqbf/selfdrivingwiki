import Foundation
import Testing

/// Source-level boundary audit: the presentation layer may describe metadata,
/// but all reads and daemon interaction belong to detail owners.
struct MetadataAPISignatureManifestTests {
    @Test func inspectorTypesDoNotReferenceWikiStore() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in [
            "Sources/WikiFS/Detail/DetailInspectorView.swift",
            "Sources/WikiFS/Detail/MetadataPanelView.swift",
            "Sources/WikiFS/Detail/MetadataPresentation.swift",
            "Sources/WikiFS/Detail/MetadataValueRenderer.swift",
        ] {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            let executableLines = source.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            #expect(!executableLines.contains { $0.contains("WikiStore") || $0.contains("readPool") || $0.contains("remoteSession") }, "renderer I/O reference in \(path)")
        }
    }
}
