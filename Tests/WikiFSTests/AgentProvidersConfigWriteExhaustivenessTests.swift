import Foundation
import Testing

struct AgentProvidersConfigWriteExhaustivenessTests {
    @Test func productionWritersUseLockedMutationAPI() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = repositoryRoot.appendingPathComponent("Sources", isDirectory: true)
        let allowedFile = "Sources/WikiFSCore/Core/AgentProvidersConfig.swift"
        let enumerator = FileManager.default.enumerator(
            at: sources,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var violations: [String] = []
        while let file = enumerator?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let relative = file.path.replacingOccurrences(of: repositoryRoot.path + "/", with: "")
            guard relative != allowedFile else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let value = String(line)
                if value.contains("AgentProvidersConfig") && value.contains(".save(to:") {
                    violations.append("\(relative):\(index + 1): \(value)")
                }
                if value.contains(".writeAtomically(to:") &&
                    (text.contains("AgentProvidersConfig") || relative.contains("AgentProvider")) {
                    violations.append("\(relative):\(index + 1): \(value)")
                }
            }
        }
        #expect(
            violations.isEmpty,
            "Production provider-config writes must use AgentProvidersConfigStore:\n\(violations.joined(separator: "\n"))")
    }
}
