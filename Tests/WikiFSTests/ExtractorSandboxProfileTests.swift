#if os(macOS)
import Foundation
import Testing
@testable import WikiFSCore
import WikiFSTypes

/// Pure checks for the managed-extractor seatbelt profile: the skeleton,
/// per-capability allow/define presence and absence, the network fence,
/// canonicalization of emitted roots, and the wrapped argv assembly. No
/// process is spawned here — `ManagedExtractorProcessExecutorTests` covers
/// enforcement with the real `sandbox-exec`.
@Suite("Extractor sandbox profile")
struct ExtractorSandboxProfileTests {

    /// A minimal valid layout. All roots inside the operation root, matching
    /// what `ManagedExtractorProcessExecutor.validate` enforces before launch.
    private static func paths(
        sharedRuntimeCacheRoot: URL? = nil,
        sharedModelCacheRoot: URL? = nil
    ) -> ManagedExtractorProcessPaths {
        let operationRoot = URL(fileURLWithPath: "/op/\(UUID().uuidString)", isDirectory: true)
        return ManagedExtractorProcessPaths(
            operationRoot: operationRoot,
            packageRoot: operationRoot.appendingPathComponent("package", isDirectory: true),
            homeRoot: operationRoot.appendingPathComponent("home", isDirectory: true),
            temporaryRoot: operationRoot.appendingPathComponent("tmp", isDirectory: true),
            privateCacheRoot: operationRoot.appendingPathComponent("cache", isDirectory: true),
            sharedRuntimeCacheRoot: sharedRuntimeCacheRoot,
            sharedModelCacheRoot: sharedModelCacheRoot)
    }

    private func generate(
        _ paths: ManagedExtractorProcessPaths,
        capabilities: Set<ExtractorCapability> = [],
        durableTokenCacheRoot: URL? = nil
    ) -> String {
        ExtractorSandboxProfile.generate(
            paths: paths,
            capabilities: capabilities,
            durableTokenCacheRoot: durableTokenCacheRoot)
    }

    private func invocation(
        _ paths: ManagedExtractorProcessPaths,
        capabilities: Set<ExtractorCapability> = [],
        durableTokenCacheRoot: URL? = nil
    ) -> SandboxProfile.SandboxInvocation {
        ExtractorSandboxProfile.invocation(
            paths: paths,
            capabilities: capabilities,
            durableTokenCacheRoot: durableTokenCacheRoot)
    }

    // MARK: - Skeleton (AC.1)

    @Test func skeletonIsVersionAllowDefaultDenyWritesOperationRoot() {
        let lines = generate(Self.paths())
            .split(separator: "\n")
            .map(String.init)
        #expect(lines.prefix(3) == ["(version 1)", "(allow default)", "(deny file-write*)"])
        #expect(lines[3] == "(allow file-write* (subpath (param \"OPERATION_ROOT\")))")
    }

    /// The operation-root allow covers the whole per-operation layout: the
    /// executor's validation already confines package/home/temp/private-cache
    /// under it, so no per-root rules exist in the profile.
    @Test func noPerRootOperationAllowsExist() {
        let profile = generate(Self.paths())
        #expect(!profile.contains("PACKAGE"))
        #expect(!profile.contains("HOME_ROOT"))
        #expect(!profile.contains("TEMPORARY"))
        #expect(!profile.contains("PRIVATE_CACHE"))
    }

    // MARK: - Capability gating (AC.1)

    @Test func sharedRuntimeCacheAllowAppearsOnlyWithCapabilityAndRoot() {
        let capable = generate(
            Self.paths(sharedRuntimeCacheRoot: URL(fileURLWithPath: "/shared/runtime")),
            capabilities: [.sharedRuntimeCache])
        #expect(capable.contains("(allow file-write* (subpath (param \"SHARED_RUNTIME_CACHE\")))"))

        // Capability without a host-supplied root grants nothing.
        let capableWithoutRoot = generate(
            Self.paths(),
            capabilities: [.sharedRuntimeCache])
        #expect(!capableWithoutRoot.contains("SHARED_RUNTIME_CACHE"))

        // Root without the capability grants nothing — the manifest gates it.
        let rootedWithoutCapability = generate(
            Self.paths(sharedRuntimeCacheRoot: URL(fileURLWithPath: "/shared/runtime")))
        #expect(!rootedWithoutCapability.contains("SHARED_RUNTIME_CACHE"))
    }

    @Test func sharedModelCacheAllowAppearsOnlyWithCapabilityAndRoot() {
        let capable = generate(
            Self.paths(sharedModelCacheRoot: URL(fileURLWithPath: "/shared/models")),
            capabilities: [.modelDownload])
        #expect(capable.contains("(allow file-write* (subpath (param \"SHARED_MODEL_CACHE\")))"))
        let capableWithoutRoot = generate(Self.paths(), capabilities: [.modelDownload])
        #expect(!capableWithoutRoot.contains("SHARED_MODEL_CACHE"))
        let rootedWithoutCapability = generate(
            Self.paths(sharedModelCacheRoot: URL(fileURLWithPath: "/shared/models")))
        #expect(!rootedWithoutCapability.contains("SHARED_MODEL_CACHE"))
    }

    @Test func tokenCacheAllowFollowsTheHostSuppliedRootOnly() {
        let supplied = generate(
            Self.paths(),
            durableTokenCacheRoot: URL(fileURLWithPath: "/tokens/rev"))
        #expect(supplied.contains("(allow file-write* (subpath (param \"TOKEN_CACHE\")))"))
        #expect(!generate(Self.paths()).contains("TOKEN_CACHE"))
    }

    /// Defines are emitted only for rules the profile contains, in rule
    /// order: OPERATION_ROOT, then the gated caches, then the token cache.
    @Test func definesMatchEmittedRulesInOrder() {
        let paths = Self.paths(
            sharedRuntimeCacheRoot: URL(fileURLWithPath: "/shared/runtime"),
            sharedModelCacheRoot: URL(fileURLWithPath: "/shared/models"))
        let full = invocation(
            paths,
            capabilities: [.sharedRuntimeCache, .modelDownload],
            durableTokenCacheRoot: URL(fileURLWithPath: "/tokens/rev"))
        #expect(full.defines.map(\.0) == [
            "OPERATION_ROOT", "SHARED_RUNTIME_CACHE", "SHARED_MODEL_CACHE", "TOKEN_CACHE",
        ])
        #expect(full.defines[1].1 == "/shared/runtime")
        #expect(full.defines[2].1 == "/shared/models")
        #expect(full.defines[3].1 == "/tokens/rev")

        let minimal = invocation(Self.paths())
        #expect(minimal.defines.count == 1)
        #expect(minimal.defines[0].0 == "OPERATION_ROOT")
    }

    // MARK: - Network fence (AC.2)

    @Test func networkDenyPresentExactlyWhenCapabilityAbsent() {
        let denied = generate(Self.paths(), capabilities: [.sharedRuntimeCache])
        #expect(denied.contains("(deny network*)"))
        let allowed = generate(Self.paths(), capabilities: [.network])
        #expect(!allowed.contains("network"))
    }

    /// The network deny must be the LAST rule: the seatbelt resolves against
    /// the last matching rule, so a trailing deny cannot be shadowed.
    @Test func networkDenyIsTheLastRule() {
        let lines = generate(Self.paths())
            .split(separator: "\n")
            .map(String.init)
        #expect(lines.last == "(deny network*)")
    }

    // MARK: - Device writes

    /// Shell/interpreter basics: /dev/null redirects and /dev/fd aliases.
    /// Data writes only — no chmod/unlink on the devices.
    @Test func allowsMinimalDeviceDataWrites() {
        let profile = generate(Self.paths())
        #expect(profile.contains("(allow file-write-data (literal \"/dev/null\"))"))
        #expect(profile.contains("(allow file-write-data (subpath \"/dev/fd\"))"))
        #expect(!profile.contains("/dev/tty"))
        #expect(!profile.contains("/dev/dtracehelper"))
    }

    // MARK: - Canonicalization

    /// The `/tmp` → `/private/tmp` trap: seatbelt matchers resolve canonical
    /// paths, so every emitted define must be `realpath`-resolved. The test
    /// creates a REAL directory under `/tmp` so `realpath(3)` fully resolves.
    @Test func canonicalizesTmpRootsInTheDefines() throws {
        let suffix = "extractor-sandbox-\(UUID().uuidString)"
        let tmpRoot = URL(fileURLWithPath: "/tmp/\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: tmpRoot) }
            catch { Issue.record("tmp root cleanup failed: \(error)") }
        }
        let operationRoot = tmpRoot.appendingPathComponent("operation", isDirectory: true)
        try FileManager.default.createDirectory(at: operationRoot, withIntermediateDirectories: true)
        let paths = ManagedExtractorProcessPaths(
            operationRoot: operationRoot,
            packageRoot: operationRoot.appendingPathComponent("package", isDirectory: true),
            homeRoot: operationRoot.appendingPathComponent("home", isDirectory: true),
            temporaryRoot: operationRoot.appendingPathComponent("tmp", isDirectory: true),
            privateCacheRoot: operationRoot.appendingPathComponent("cache", isDirectory: true))

        let result = invocation(paths)
        let operationDefine = try #require(result.defines.first { $0.0 == "OPERATION_ROOT" })
        #expect(operationDefine.1.hasPrefix("/private/tmp/"))
        #expect(!operationDefine.1.hasPrefix("/tmp/"))
    }

    /// Non-existent roots cannot be realpath-resolved; they fall back to the
    /// input instead of disappearing (the seatbelt will create them).
    @Test func nonExistentRootsFallBackToInput() {
        let paths = Self.paths()
        let result = invocation(paths)
        #expect(result.defines.first { $0.0 == "OPERATION_ROOT" }?.1 == paths.operationRoot.path)
    }

    // MARK: - Wrapped argv

    /// Byte-for-byte the deleted `OperationCommand.applySandbox` pattern:
    /// `-p <profile> -D k=v … -- <executable> <args…>`.
    @Test func wrappedArgumentsMatchesTheHistoricPattern() {
        let invocation = SandboxProfile.SandboxInvocation(
            profile: "(version 1)",
            defines: [
                ("OPERATION_ROOT", "/private/tmp/op"),
                ("SHARED_RUNTIME_CACHE", "/shared/runtime"),
            ])
        let wrapped = ExtractorSandboxProfile.wrappedArguments(
            executablePath: "/usr/local/bin/bun",
            arguments: ["run", "/op/package/entry.js"],
            invocation: invocation)
        #expect(wrapped == [
            "-p", "(version 1)",
            "-D", "OPERATION_ROOT=/private/tmp/op",
            "-D", "SHARED_RUNTIME_CACHE=/shared/runtime",
            "--", "/usr/local/bin/bun",
            "run", "/op/package/entry.js",
        ])
    }

    /// The sandbox front-end is the absolute system path, never a PATH search.
    @Test func sandboxExecutableIsTheAbsoluteSystemPath() {
        #expect(ExtractorSandboxProfile.sandboxExecutablePath == "/usr/bin/sandbox-exec")
    }
}
#endif
