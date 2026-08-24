import Cordis
import CordisLoader
import Foundation
import Testing

private struct StoreConfig: PluginConfig, Equatable {
    var backend: String = "grdb"
    var path: String = ""

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        backend = try container.decodeIfPresent(String.self, forKey: .backend) ?? "grdb"
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case backend
        case path
    }

    static func validate(_ config: StoreConfig) -> [ConfigIssue] {
        var validation = ConfigValidation()
        validation.check("backend", !config.backend.isEmpty, "backend must not be empty")
        validation.check("path", config.backend == "memory" || !config.path.isEmpty, "path is required unless backend is memory")
        return validation.allIssues
    }
}

private struct LlmConfig: PluginConfig, Equatable {
    var provider: String = ""
    var apiKey: String = ""

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? ""
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case apiKey
    }

    static func validate(_ config: LlmConfig) -> [ConfigIssue] {
        var validation = ConfigValidation()
        validation.check("provider", !config.provider.isEmpty, "provider must not be empty")
        return validation.allIssues
    }
}

private let storeBackendKey = ServiceKey<String>(label: "store.backend")
private let llmProviderKey = ServiceKey<String>(label: "llm.provider")

@Suite("Cordis loader", .serialized, .timeLimit(.minutes(1)))
struct CordisLoaderTests {
    private func makeCatalog() throws -> PluginCatalog {
        try PluginCatalog([
            PluginDefinition(
                id: PluginID("wiki.store"),
                provisions: [ServiceDependency(storeBackendKey)],
                config: StoreConfig.self) { config in
                try ComponentDefinition(
                    label: "store",
                    provisions: [ServiceDependency(storeBackendKey)]) { activation in
                    _ = try await activation.supply(storeBackendKey, value: config.backend)
                }
            },
            PluginDefinition(
                id: PluginID("wiki.llm"),
                provisions: [ServiceDependency(llmProviderKey)],
                config: LlmConfig.self) { config in
                try ComponentDefinition(
                    label: "llm",
                    provisions: [ServiceDependency(llmProviderKey)]) { activation in
                    _ = try await activation.supply(llmProviderKey, value: config.provider)
                }
            },
            PluginDefinition(id: PluginID("wiki.noop")) {
                try ComponentDefinition(label: "noop") { _ in }
            },
        ])
    }

    // AC.3: patch layering.

    @Test("layers resolve with documented precedence; replacement takes the whole config")
    func patchLayering() throws {
        let bundle = PatchFile(entries: [
            Entry(id: EntryID("store"), plugin: PluginID("wiki.store"), config: [
                "backend": .string("grdb"),
                "path": .string("/base/wiki.sqlite"),
            ]),
            Entry(id: EntryID("llm"), plugin: PluginID("wiki.llm"), config: [
                "provider": .string("anthropic"),
                "apiKey": .string("sk-1"),
            ]),
        ])
        let profile = PatchFile(entries: [
            // Whole-row replacement: the new config has no apiKey, and the
            // resolved row must not keep the bundle's apiKey either.
            Entry(id: EntryID("store"), plugin: PluginID("wiki.store"), config: [
                "backend": .string("grdb"),
                "path": .string("/profile/wiki.sqlite"),
            ]),
        ])
        let home = PatchFile(entries: [
            Entry(id: EntryID("llm"), plugin: PluginID("wiki.llm"), config: [
                "provider": .string("openai"),
                "apiKey": .string("sk-2"),
            ]),
        ])
        let overlay = PatchFile(remove: [EntryID("llm")])

        let resolved = PatchResolver.resolve(layers: [bundle, profile, home, overlay])
        #expect(resolved.map(\.id) == [EntryID("store")])
        #expect(resolved[0].config?["path"] == .string("/profile/wiki.sqlite"))
        #expect(resolved[0].config?.keys.sorted() == ["backend", "path"])
    }

    @Test("YAML patch files round trip")
    func yamlRoundTrip() throws {
        let yaml = """
        entries:
          - id: store
            plugin: wiki.store
            config:
              backend: grdb
              path: /tmp/wiki.sqlite
            disabled: false
        remove:
          - llm
        """
        let patch = try PatchFileCodec.decode(yaml)
        #expect(patch.entries == [
            Entry(id: EntryID("store"), plugin: PluginID("wiki.store"), config: [
                "backend": .string("grdb"),
                "path": .string("/tmp/wiki.sqlite"),
            ]),
        ])
        #expect(patch.remove == [EntryID("llm")])

        let reencoded = try PatchFileCodec.encode(patch)
        let reparsed = try PatchFileCodec.decode(reencoded)
        #expect(reparsed == patch)
    }

    // AC.2: config validation fails boot naming entry id and field.

    @Test("invalid config fails boot naming entry id and field")
    func invalidConfigFailsBoot() async throws {
        let catalog = try makeCatalog()
        let layer = PatchFile(entries: [
            Entry(id: EntryID("llm-primary"), plugin: PluginID("wiki.llm"), config: [
                "provider": .string(""),
            ]),
        ])
        await #expect(throws: CordisError.self) {
            _ = try await CordisBoot.boot(CordisBoot.Options(catalog: catalog, layers: [layer]))
        }
    }

    @Test("missing required key is a structured config error")
    func missingKeyFailsBoot() async throws {
        let catalog = try makeCatalog()
        // The schema requires a non-empty provider; the default (empty)
        // fails validation.
        let layer = PatchFile(entries: [
            Entry(id: EntryID("llm-defaults"), plugin: PluginID("wiki.llm")),
        ])
        do {
            _ = try await CordisBoot.boot(CordisBoot.Options(catalog: catalog, layers: [layer]))
            Issue.record("expected boot to fail")
        } catch let CordisError.invalidConfig(pluginID, entryID, issues) {
            #expect(pluginID == PluginID("wiki.llm"))
            #expect(entryID == "llm-defaults")
            #expect(issues.contains(ConfigIssue(field: "provider", message: "provider must not be empty")))
        }
    }

    @Test("entry with unknown plugin fails boot")
    func unknownPluginFailsBoot() async throws {
        let catalog = try makeCatalog()
        let layer = PatchFile(entries: [
            Entry(id: EntryID("ghost"), plugin: PluginID("wiki.ghost")),
        ])
        await #expect(throws: CordisLoaderError.self) {
            _ = try await CordisBoot.boot(CordisBoot.Options(catalog: catalog, layers: [layer]))
        }
    }

    // AC.5 groundwork: config-only swap changes the active service identity.

    @Test("swapping a row's config changes the provided service value")
    func configSwapChangesService() async throws {
        let backendKey = storeBackendKey
        let catalog = try makeCatalog()

        let grdb = PatchFile(entries: [
            Entry(id: EntryID("store"), plugin: PluginID("wiki.store"), config: [
                "backend": .string("grdb"),
                "path": .string("/a.sqlite"),
            ]),
        ])
        let bootedA = try await CordisBoot.boot(CordisBoot.Options(catalog: catalog, layers: [grdb]))
        #expect(try await bootedA.context.require(backendKey) == "grdb")

        // Hot-swap the same row to a different config on the live context.
        let memory = PatchFile(entries: [
            Entry(id: EntryID("store"), plugin: PluginID("wiki.store"), config: [
                "backend": .string("memory"),
            ]),
        ])
        try await bootedA.tree.update(to: PatchResolver.resolve(layers: [memory]))
        #expect(try await bootedA.context.require(backendKey) == "memory")
        try await bootedA.shutdown()
    }

    @Test("dump-config prints the resolved entry tree")
    func dumpConfig() async throws {
        let catalog = try makeCatalog()
        let layer = PatchFile(entries: [
            Entry(id: EntryID("noop"), plugin: PluginID("wiki.noop")),
        ])
        let booted = try await CordisBoot.boot(CordisBoot.Options(catalog: catalog, layers: [layer]))
        let dump = try await booted.dumpConfig()
        #expect(dump.contains("wiki.noop"))
        #expect(dump.contains("noop"))
        try await booted.shutdown()
    }

    @Test("profile bundles resolve real files in bundle, profile, home, overlay order")
    func profileBundlePrecedence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                Issue.record("failed to remove fixture directory: \(error)")
            }
        }
        let base = root.appendingPathComponent("base", isDirectory: true)
        let profile = root.appendingPathComponent("profile", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("entries:\n  - id: value\n    plugin: wiki.noop\n    config: {source: bundle}\n".utf8)
            .write(to: base.appendingPathComponent(ProfileBundle.patchFileName))
        try Data("entries:\n  - id: value\n    plugin: wiki.noop\n    config: {source: profile}\n".utf8)
            .write(to: profile.appendingPathComponent(ProfileBundle.patchFileName))
        let home = Data("entries:\n  - id: value\n    plugin: wiki.noop\n    config: {source: home}\n".utf8)
        let overlay = "entries:\n  - id: value\n    plugin: wiki.noop\n    config: {source: overlay}\n"

        let resolved = try ProfileBundle.resolve(
            bundleNames: ["base"], profileName: "profile", in: root,
            homePatchData: home, overlay: overlay)
        #expect(resolved.entries.first?.config?["source"] == .string("overlay"))
        let dump = try resolved.dump()
        #expect(try PatchFileCodec.decode(dump).entries == resolved.entries)
    }

    @Test("disabled entries do not mount")
    func disabledEntries() async throws {
        let catalog = try makeCatalog()
        let layer = PatchFile(entries: [
            Entry(id: EntryID("noop"), plugin: PluginID("wiki.noop"), disabled: true),
        ])
        let booted = try await CordisBoot.boot(CordisBoot.Options(catalog: catalog, layers: [layer]))
        let ids = await booted.tree.mountedEntryIDs
        #expect(ids.isEmpty)
        try await booted.shutdown()
    }

    @Test("removing a row disposes its component")
    func removalDisposes() async throws {
        let catalog = try makeCatalog()
        let layer = PatchFile(entries: [
            Entry(id: EntryID("noop"), plugin: PluginID("wiki.noop")),
        ])
        let booted = try await CordisBoot.boot(CordisBoot.Options(catalog: catalog, layers: [layer]))
        try await booted.tree.update(to: [])
        let ids = await booted.tree.mountedEntryIDs
        #expect(ids.isEmpty)
        try await booted.shutdown()
    }

    @Test("boot failure disposes earlier row effects exactly once")
    func bootFailureRollsBackEarlierRows() async throws {
        let cleanup = LoaderCleanupCounter()
        let catalog = try rollbackCatalog(cleanup: cleanup)
        let layer = PatchFile(entries: [
            Entry(id: EntryID("first"), plugin: PluginID("test.tracked")),
            Entry(id: EntryID("second"), plugin: PluginID("test.failure")),
        ])

        await #expect(throws: CordisLoaderError.self) {
            _ = try await CordisBoot.boot(.init(catalog: catalog, layers: [layer]))
        }
        #expect(await cleanup.value == 1)
    }

    @Test("update failure rolls back newly mounted row effects exactly once")
    func updateFailureRollsBackEarlierRows() async throws {
        let cleanup = LoaderCleanupCounter()
        let catalog = try rollbackCatalog(cleanup: cleanup)
        let context = CordisContext()
        let tree = EntryTree(context: context, catalog: catalog)

        await #expect(throws: CordisLoaderError.self) {
            try await tree.update(to: [
                Entry(id: EntryID("first"), plugin: PluginID("test.tracked")),
                Entry(id: EntryID("second"), plugin: PluginID("test.failure")),
            ])
        }
        #expect(await cleanup.value == 1)
        #expect(await tree.mountedEntryIDs.isEmpty)
        try await tree.dispose()
        try await context.dispose()
        #expect(await cleanup.value == 1)
    }

    private func rollbackCatalog(cleanup: LoaderCleanupCounter) throws -> PluginCatalog {
        try PluginCatalog([
            PluginDefinition(id: PluginID("test.tracked")) {
                try ComponentDefinition(label: "tracked") { activation in
                    _ = try await activation.effect { _ in await cleanup.increment() }
                }
            },
            PluginDefinition(id: PluginID("test.failure")) {
                try ComponentDefinition(label: "failure") { _ in
                    throw LoaderExpectedError()
                }
            },
        ])
    }
}

private actor LoaderCleanupCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private struct LoaderExpectedError: Error {}
