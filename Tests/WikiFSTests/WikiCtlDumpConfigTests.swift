import Foundation
import Testing
import WikiCtlCore

@Suite("wikictl dump config")
struct WikiCtlDumpConfigTests {
    @Test("bundle-level dump succeeds without a user profile and applies overlay")
    func bundleFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                Issue.record("failed to remove fixture directory: \(error)")
            }
        }
        for name in ["wikifs-base", "wikictl"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data("entries:\n  - id: store\n    plugin: wiki.store\n".utf8).write(
            to: root.appendingPathComponent("wikifs-base/cordis.patch.yml"))
        try Data("entries: []\n".utf8).write(
            to: root.appendingPathComponent("wikictl/cordis.patch.yml"))

        let result = try DumpConfigCommand.run(
            bundlesDirectory: root,
            homeDirectory: nil,
            overlay: "entries:\n  - id: store\n    plugin: wiki.store\n    disabled: true\n")
        #expect(result.note != nil)
        #expect(result.output.contains("disabled: true"))
    }

    @Test("parser accepts dump config without a wiki")
    func parsesFlag() throws {
        let invocation = try ArgumentParser.parse(["--dump-config", "--patch", "entries: []"]) { _ in nil }
        #expect(invocation == .init(wikiSelector: "", command: .dumpConfig(overlay: "entries: []")))
    }
}
