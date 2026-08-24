import Foundation
import Testing

@Suite("Scope compatibility manifest")
struct ScopeCompatibilityManifestTests {
    @Test("diagnostics do not enter schemas or wire encodings")
    func diagnosticsDoNotEnterSchemasOrWireEncodings() throws {
        let root = scopeCompatibilityRepositoryRoot()
        let cordis = try swiftSources(in: root.appendingPathComponent("Sources/Cordis"))
        let store = try String(
            contentsOf: root.appendingPathComponent("Sources/WikiFSCore/Store/GRDBWikiStore.swift"),
            encoding: .utf8)

        #expect(!cordis.contains("ScopeDescriptor: Codable"))
        #expect(!cordis.contains("InvariantViolation: Codable"))
        #expect(!store.contains("scope_descriptor"))
        #expect(!store.contains("invariant_violation"))
    }

    private func swiftSources(in directory: URL) throws -> String {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        return try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }
}

private func scopeCompatibilityRepositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
