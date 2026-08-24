import CordisLoader
import Foundation
import Testing
import WikiCtlCore
import WikiFSCore
import WikiFSEngine

@Suite("wikictl dump config", .serialized, .timeLimit(.minutes(1)))
struct WikiCtlDumpConfigTests {
    @Test("committed wikictl YAML honors home and command overlays")
    func committedCLIDump() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("dump-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: home) }
            catch { Issue.record("failed to remove dump fixture: \(error)") }
        }
        try Data("entries:\n  - id: tantivy\n    plugin: wiki.search.tantivy\n    disabled: true\n".utf8).write(
            to: home.appendingPathComponent(ProfileBundle.patchFileName))
        let result = try DumpConfigCommand.run(
            homeDirectory: home,
            overlay: "entries:\n  - id: transport\n    plugin: wiki.transport\n    disabled: false\n")
        #expect(result.note == nil)
        #expect(result.output.contains("id: tantivy"))
        #expect(result.output.contains("id: transport"))
        let transportSuffix = try #require(result.output.split(separator: "id: transport", maxSplits: 1).last)
        #expect(!transportSuffix.contains("disabled: true"))
    }

    @Test("app and daemon dumps pin committed production profiles")
    func appAndDaemonDumps() throws {
        let databaseURL = URL(fileURLWithPath: "/fixture/wiki.sqlite")
        let ambient = ProductionProfiles.ambient(
            databaseURL: databaseURL,
            wikiID: WikiID(rawValue: "fixture-wiki"))
        let app = try DumpConfigCommand.run(
            kind: .app, scope: .wiki, homeDirectory: nil, ambient: ambient)
        #expect(app.output.contains("id: renderer-services"))
        #expect(app.output.contains("id: tantivy"))
        #expect(app.output.contains("databasePath: /fixture/wiki.sqlite"))
        let daemon = try DumpConfigCommand.run(
            kind: .daemon, scope: .wiki, homeDirectory: nil, ambient: ambient)
        #expect(daemon.output.contains("id: embeddings"))
        #expect(!daemon.output.contains("id: renderer-services"))
        #expect(!daemon.output.contains("id: tantivy"))
    }

    @Test("parser accepts dump config without a wiki")
    func parsesFlag() throws {
        let invocation = try ArgumentParser.parse(["--dump-config", "--patch", "entries: []"]) { _ in nil }
        #expect(invocation == .init(wikiSelector: "", command: .dumpConfig(overlay: "entries: []")))
    }
}
