import Foundation
import Synchronization
import Testing
import WikiFSCore
@testable import WikiFSEngine

/// The shared production provider-command resolution (issue #1279 AC.9):
/// login-shell PATH first, the validated `RuntimeCommandLocator` Bun lookup
/// as the ONLY bare-`bun` fallback, and no command when both miss.
@Suite("ProviderCommandResolver")
struct ProviderCommandResolverTests {

    /// Thread-safe call counter for the injected locator seam (the seam is
    /// `@Sendable`, so a captured local cannot be mutated directly).
    private final class CallCounter: Sendable {
        private let storage = Mutex(0)
        var value: Int { storage.withLock { $0 } }
        func bump() { storage.withLock { $0 += 1 } }
    }

    /// A real executable file under an isolated directory — the PATH-success
    /// cases resolve through the production `PathPreflight` file checks.
    private func makeExecutableDirectory(named name: String) throws -> (dir: URL, file: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: file)
        guard chmod(file.path, 0o755) == 0 else {
            throw POSIXError(.EPERM)
        }
        return (dir, file)
    }

    private func cleanup(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) }
        catch { Issue.record("resolver fixture cleanup failed: \(error)") }
    }

    @Test("A bare bun first token resolves on the provided PATH without the locator")
    func pathSuccessSkipsLocator() async throws {
        let fixture = try makeExecutableDirectory(named: "bun")
        defer { cleanup(fixture.dir) }
        let provider = AgentProvider(
            id: ProviderID(rawValue: "claude-acp"),
            label: "Claude",
            command: ["bun", "x", "@agentclientprotocol/claude-agent-acp"])
        let locator = CallCounter()
        let resolved = await ProviderCommandResolver.resolveCommand(
            for: provider,
            searchPath: fixture.dir.path,
            locateBun: {
                locator.bump()
                return "/locator/bun"
            })
        #expect(resolved == [fixture.file.path, "x", "@agentclientprotocol/claude-agent-acp"])
        #expect(locator.value == 0, "a PATH hit must not pay for the locator")
    }

    @Test("A PATH miss for bare bun falls back to the locator's absolute path")
    func locatorFallbackResolvesBareBun() async throws {
        let provider = AgentProvider(
            id: ProviderID(rawValue: "claude-acp"),
            label: "Claude",
            command: ["bun", "x", "@agentclientprotocol/claude-agent-acp"])
        let locator = CallCounter()
        let resolved = await ProviderCommandResolver.resolveCommand(
            for: provider,
            searchPath: "/nonexistent/bin:/also/missing",
            locateBun: {
                locator.bump()
                return "/Users/me/.local/share/mise/installs/bun/1.4.0/bin/bun"
            })
        #expect(resolved == [
            "/Users/me/.local/share/mise/installs/bun/1.4.0/bin/bun",
            "x", "@agentclientprotocol/claude-agent-acp",
        ])
        #expect(locator.value == 1)
    }

    @Test("When both lookups fail, the provider resolves to no command")
    func bothLookupsFailYieldsNoCommand() async throws {
        let provider = AgentProvider(
            id: ProviderID(rawValue: "claude-acp"),
            label: "Claude",
            command: ["bun", "x", "@agentclientprotocol/claude-agent-acp"])
        let locator = CallCounter()
        let resolved = await ProviderCommandResolver.resolveCommand(
            for: provider,
            searchPath: "/nonexistent/bin",
            locateBun: {
                locator.bump()
                return nil
            })
        #expect(resolved == nil)
        #expect(locator.value == 1)
        // Batch form: the provider is simply absent from the dictionary.
        let batch = await ProviderCommandResolver.resolveCommands(
            for: [provider],
            searchPath: "/nonexistent/bin",
            locateBun: { nil })
        #expect(batch.isEmpty)
    }

    @Test("Absolute and tilde-pinned bun commands never get the locator fallback")
    func absolutePathsAreNeverSubstituted() async throws {
        let locator = CallCounter()
        // An absolute path that does not exist must stay unresolved — the
        // user pinned a location and must see the failure, not a substitution.
        let absolute = AgentProvider(
            id: ProviderID(rawValue: "pinned"),
            label: "Pinned",
            command: ["/opt/pinned-bun/bin/bun", "x", "pkg"])
        #expect(await ProviderCommandResolver.resolveCommand(
            for: absolute,
            searchPath: "/nonexistent",
            locateBun: {
                locator.bump()
                return "/locator/bun"
            }) == nil)
        // A tilde path expands to absolute → same rule.
        let tilde = AgentProvider(
            id: ProviderID(rawValue: "tilde"),
            label: "Tilde",
            command: ["~/bin/bun", "x", "pkg"])
        #expect(await ProviderCommandResolver.resolveCommand(
            for: tilde,
            searchPath: "/nonexistent",
            locateBun: {
                locator.bump()
                return "/locator/bun"
            }) == nil)
        // A relative path is not bare either.
        let relative = AgentProvider(
            id: ProviderID(rawValue: "relative"),
            label: "Relative",
            command: ["./bun", "x", "pkg"])
        #expect(await ProviderCommandResolver.resolveCommand(
            for: relative,
            searchPath: "/nonexistent",
            locateBun: {
                locator.bump()
                return "/locator/bun"
            }) == nil)
        #expect(locator.value == 0, "non-bare tokens must never reach the locator")
    }

    @Test("Non-bun commands resolve only through PATH — no fallback")
    func nonBunCommandsHaveNoFallback() async throws {
        let node = try makeExecutableDirectory(named: "node")
        defer { cleanup(node.dir) }
        let missing = AgentProvider(
            id: ProviderID(rawValue: "hermes"),
            label: "Hermes",
            command: ["hermes", "acp"])
        let locator = CallCounter()
        let resolved = await ProviderCommandResolver.resolveCommand(
            for: missing,
            searchPath: "/nonexistent/bin",
            locateBun: {
                locator.bump()
                return "/locator/bun"
            })
        #expect(resolved == nil)
        #expect(locator.value == 0)

        // And a PATH hit for a non-bun command works unchanged.
        let nodeProvider = AgentProvider(
            id: ProviderID(rawValue: "node"),
            label: "Node",
            command: ["node", "server.js"])
        let nodeResolved = await ProviderCommandResolver.resolveCommand(
            for: nodeProvider,
            searchPath: node.dir.path,
            locateBun: {
                locator.bump()
                return nil
            })
        #expect(nodeResolved == [node.file.path, "server.js"])
        #expect(locator.value == 0)
    }

    @Test("Batch resolution runs the locator at most once")
    func batchRunsLocatorOnce() async throws {
        let bunProvider = AgentProvider(
            id: ProviderID(rawValue: "claude-acp"),
            label: "Claude",
            command: ["bun", "x", "@agentclientprotocol/claude-agent-acp"])
        let codexProvider = AgentProvider(
            id: ProviderID(rawValue: "codex-acp"),
            label: "Codex",
            command: ["npx", "@agentclientprotocol/codex-acp@1.1.7"])
        let locator = CallCounter()
        let batch = await ProviderCommandResolver.resolveCommands(
            for: [bunProvider, codexProvider],
            searchPath: "/nonexistent/bin",
            locateBun: {
                locator.bump()
                return "/resolved/bun"
            })
        // The bare-bun provider resolved through the locator…
        #expect(batch[ProviderID(rawValue: "claude-acp")] == [
            "/resolved/bun", "x", "@agentclientprotocol/claude-agent-acp",
        ])
        // …while the npx provider misses PATH and has NO fallback → absent.
        #expect(batch[ProviderID(rawValue: "codex-acp")] == nil)
        #expect(locator.value == 1, "the locator must run at most once per batch")
    }
}
