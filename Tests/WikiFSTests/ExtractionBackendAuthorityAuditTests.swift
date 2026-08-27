#if os(macOS)
import Foundation
import Testing

/// AC.12: `ExtractionBackendRegistry` is the sole adapter authority for
/// built-in and package PDF and HTML extraction.
///
/// These are source audits, not behavior tests. They fail when a second
/// extractor-construction path reappears in a shipping target, which is the
/// regression that unit tests cannot observe because the second path compiles
/// and passes its own tests in isolation.
@Suite("Extraction backend authority audit")
struct ExtractionBackendAuthorityAuditTests {
    /// The legacy assembly is retained only for its own compatibility tests.
    /// No app, daemon, or CLI target may construct it.
    private static let legacyFactoryDeclaration = "Sources/WikiFSEngine/ExtractionRuntimeFactory.swift"

    @Test func testNoSecondConstructionSwitch() throws {
        let sources = try Self.repositoryRoot().appendingPathComponent("Sources", isDirectory: true)
        var offenders: [String] = []

        for file in try Self.swiftFiles(in: sources) {
            let relative = Self.relativePath(of: file)
            guard relative != Self.legacyFactoryDeclaration else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            if source.contains("ExtractionRuntimeFactory(") {
                offenders.append(relative)
            }
        }

        #expect(
            offenders.isEmpty,
            """
            A shipping target constructs the legacy extraction assembly:
            \(offenders.map { "  - \($0)" }.joined(separator: "\n"))

            Every built-in and installed extractor must resolve through the one
            process `ExtractionBackendRegistry`. Build the process extraction
            graph instead of a second backend resolver.
            """)
    }

    /// The legacy coordinator initializer builds extractors directly from a
    /// configuration switch. It is a test-only compatibility seam.
    @Test func testNoProductionUseOfTheLegacyCoordinatorInitializer() throws {
        let sources = try Self.repositoryRoot().appendingPathComponent("Sources", isDirectory: true)
        // Matches the legacy call shape across line breaks, so reformatting
        // cannot hide a use. The declaration itself is excluded by path.
        let legacyCall = try NSRegularExpression(pattern: #"ExtractionCoordinator\(\s*containerDirectory"#)
        var offenders: [String] = []

        for file in try Self.swiftFiles(in: sources) {
            let relative = Self.relativePath(of: file)
            guard relative != "Sources/WikiFSEngine/ExtractionCoordinator.swift" else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            if legacyCall.firstMatch(in: source, range: range) != nil {
                offenders.append(relative)
            }
        }

        #expect(
            offenders.isEmpty,
            """
            A shipping target uses the legacy extraction coordinator initializer:
            \(offenders.map { "  - \($0)" }.joined(separator: "\n"))

            Production composition must inject the process extraction facade
            through `ExtractionCoordinator(services:)`.
            """)
    }

    // MARK: - Helpers

    private static func repositoryRoot() throws -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func swiftFiles(in directory: URL) throws -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" }
    }

    private static func relativePath(of file: URL) -> String {
        guard let root = try? repositoryRoot() else { return file.path }
        return file.path.replacingOccurrences(of: root.path + "/", with: "")
    }
}
#endif
