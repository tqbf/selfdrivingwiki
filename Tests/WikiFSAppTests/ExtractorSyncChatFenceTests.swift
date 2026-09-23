#if os(macOS)
import Foundation
import Testing
import WikiFSCore

/// Issue #1314, end to end: the chat-confined write fence vs
/// `wikictl extractor sync <package>` — the command the issue caught
/// returning `SQLite error 8: attempt to write a readonly database`.
///
/// The real built `wikictl` runs under the REAL `/usr/bin/sandbox-exec`
/// profile against a disposable App Group container (fake sidecar config,
/// no credentials, no network — the sync's `--force` path is fully offline:
/// discovery reads the catalog, and an existing source goes straight to the
/// durable enqueue). The PRE-FIX fence (no queue DB allowance) must strand
/// the run exactly as the issue describes — the byteless source is created
/// (the wiki DB write is allowed) and the enqueue fails with the readonly
/// error, leaving no durable job — and the FIXED fence must let the same
/// valid `--force` request re-enqueue exactly one extraction job.
///
/// The profile here adds one rule the production launcher does not emit: a
/// write allow for the container's `extractors/` subtree, so the reviewed
/// overlay beside the CLI binary can admit the package. Production chat
/// runs discover the package from the durable catalog the app publishes at
/// launch instead; this test exercises the CLI-layout discovery shape
/// (`runExtractorSync`'s reviewed-root path). The queue DB allowance under
/// test is the production one.
@Suite("Extractor sync chat fence", .serialized, .timeLimit(.minutes(5)))
struct ExtractorSyncChatFenceTests {

    struct FixtureUnavailable: Error, CustomStringConvertible {
        let description = "requires the built wikictl and the staged reviewed ExtractorPackages tree (make build)"
    }

    /// Root = the `Tests/` parent — the repo root, matching the suite's
    /// `wikictlPath()` resolution.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static let wikictlURL = repositoryRoot
        .appendingPathComponent(".build/debug/wikictl")
    private static let reviewedTreeURL = repositoryRoot
        .appendingPathComponent("build/ExtractorPackages", isDirectory: true)

    private static let wikictlBuilt = FileManager.default.isExecutableFile(
        atPath: wikictlURL.path)
    private static let reviewedTreeStaged = FileManager.default.fileExists(
        atPath: reviewedTreeURL.path)

    final class World {
        let root: URL
        let home: URL
        let container: URL
        let scratch: URL
        let queueDatabase: URL
        let wiki: WikiDescriptor
        let overlayLink: URL
        let createdOverlayLink: Bool

        static let appGroupID = "group.test.syncfence"

        /// A disposable production-shaped world. The container is a
        /// test-prefixed App Group SIBLING of the real one — never the real
        /// container; the wiki store + queue DB are created unsandboxed here
        /// exactly as the app creates them.
        init() throws {
            guard ExtractorSyncChatFenceTests.wikictlBuilt,
                  ExtractorSyncChatFenceTests.reviewedTreeStaged else {
                throw FixtureUnavailable()
            }
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("sync-fence-\(UUID().uuidString)", isDirectory: true)
            home = root.appendingPathComponent("home", isDirectory: true)
            container = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Group Containers", isDirectory: true)
                .appendingPathComponent(Self.appGroupID, isDirectory: true)
            scratch = root.appendingPathComponent("scratch", isDirectory: true)
            queueDatabase = container.appendingPathComponent("queue.sqlite", isDirectory: false)
            for dir in [home, container, scratch] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try FileManager.default.createDirectory(
                at: scratch.appendingPathComponent(".tmp", isDirectory: true),
                withIntermediateDirectories: true)

            // The reviewed overlay root `runExtractorSync` probes: beside the
            // binary. The build layout stages the tree beside the app bundle,
            // not beside `.build/debug/wikictl`, so link it in (removed again
            // unless it already existed).
            overlayLink = ExtractorSyncChatFenceTests.wikictlURL
                .deletingLastPathComponent()
                .appendingPathComponent("ExtractorPackages", isDirectory: true)
            if FileManager.default.fileExists(atPath: overlayLink.path) {
                createdOverlayLink = false
            } else {
                try FileManager.default.createSymbolicLink(
                    at: overlayLink,
                    withDestinationURL: ExtractorSyncChatFenceTests.reviewedTreeURL)
                createdOverlayLink = true
            }

            var mutable = WikiDescriptor.make(displayName: "Sync Fence")
            mutable.lastUsedAt = Date()
            wiki = mutable
            var registry = WikiRegistry.load(from: container)
            registry.add(wiki)
            try registry.save(to: container)

            // The central queue DB, schema-complete, created unsandboxed —
            // the app published it long before the chat ran the sync.
            let queue = try QueueStore(databaseURL: queueDatabase)
            queue.close()

            // The zotero sync sidecar: fake library id + an item key shaped
            // like the issue's PD7VA2H8 (8 chars, declared alphabet). No
            // credentials — the required-key gate is describe-only in the CLI
            // and defers verification to the draining host.
            try Data(
                #"{"libraryID": "12345", "attachments": ["PD7VA2H8"]}"#.utf8)
                .write(to: container.appendingPathComponent("zotero-config.json"))
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: container)
            try? FileManager.default.removeItem(at: root)
            if createdOverlayLink {
                try? FileManager.default.removeItem(at: overlayLink)
            }
        }

        func childEnvironment() -> [String: String] {
            var env = ProcessInfo.processInfo.environment
            env["HOME"] = home.path
            env["WIKI_APP_GROUP_ID"] = Self.appGroupID
            env["TMPDIR"] = scratch.appendingPathComponent(".tmp").path
            env["PATH"] = "/usr/bin:/bin"
            env.removeValue(forKey: "WIKI_DB")
            env.removeValue(forKey: "WIKICTL")
            return env
        }

        /// The chat write fence for the fixture wiki, with the overlay
        /// admission subtree allowed (see the suite doc comment). The
        /// `queueAllowed` flag is the fix under test: `false` rebuilds the
        /// PRE-FIX fence that produced the issue's error.
        func chatFence(queueAllowed: Bool) -> SandboxProfile.SandboxInvocation {
            let wikiDB = container.appendingPathComponent(
                wiki.dbFileName, isDirectory: false).path
            let base = SandboxProfile.invocation(
                homePath: home.path,
                scratchDir: scratch.path,
                wikiDBPath: wikiDB,
                queueDBPath: queueAllowed ? queueDatabase.path : nil)
            let extractorsSubtree = "(allow file-write* (subpath \""
                + container.appendingPathComponent("extractors", isDirectory: true)
                    .standardizedFileURL.path + "\"))\n"
            return SandboxProfile.SandboxInvocation(
                baseProfile: base.baseProfile + extractorsSubtree,
                trailer: base.trailer,
                defines: base.defines)
        }
    }

    private struct CLIResult {
        let status: Int32
        let standardOutput: String
        let standardError: String
    }

    /// Nonblocking subprocess wait (terminationHandler + continuation, per
    /// the repo's cooperative-pool rule); the suite's timeLimit bounds it.
    private func runSandboxed(
        _ world: World, arguments: [String],
        invocation: SandboxProfile.SandboxInvocation
    ) async throws -> CLIResult {
        let wrapped = SandboxProfile.wrappedArguments(
            executablePath: Self.wikictlURL.path,
            arguments: arguments,
            invocation: invocation)
        let process = Process()
        let out = Pipe()
        let err = Pipe()
        process.executableURL = URL(fileURLWithPath: SandboxProfile.sandboxExecutablePath)
        process.arguments = wrapped
        process.environment = world.childEnvironment()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            if !process.isRunning {
                continuation.resume(returning: process.terminationStatus)
                return
            }
            process.terminationHandler = { completed in
                continuation.resume(returning: completed.terminationStatus)
            }
        }
        return CLIResult(
            status: status,
            standardOutput: String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            standardError: String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    @Test(.enabled(if: ExtractorSyncChatFenceTests.wikictlBuilt && ExtractorSyncChatFenceTests.reviewedTreeStaged))
    func preFixFenceStrandsForceSyncAtEnqueueAndFixedFenceEnqueuesOneJob() async throws {
        let world = try World()
        defer { world.cleanup() }
        let syncArgs = [
            "--wiki", world.wiki.id.rawValue,
            "extractor", "sync", "zotero", "--force",
        ]
        let itemURL = "https://api.zotero.org/users/12345/items/PD7VA2H8/file"

        // PRE-FIX: the sync reaches the enqueue and fails there with the
        // issue's exact error — after the byteless source was created.
        let denied = try await runSandboxed(
            world, arguments: syncArgs, invocation: world.chatFence(queueAllowed: false))
        #expect(denied.status != 0,
                "the queue write must be denied under the pre-fix fence, stdout: \(denied.standardOutput)")
        #expect(denied.standardError.contains("SQLite error 8: attempt to write a readonly database"),
                "the denial must surface as SQLITE_READONLY (error 8), stderr: \(denied.standardError)")

        let store = try GRDBWikiStore(
            databaseURL: world.container.appendingPathComponent(
                world.wiki.dbFileName, isDirectory: false))
        defer { store.close() }
        let identity = try #require(URLFetchService.urlIdentity(itemURL))
        let stranded = try store.sourceMatchingURLIdentity(identity)
        #expect(stranded != nil,
                "the byteless source must exist — the wiki DB write is allowed, the enqueue is not")
        #expect(stranded?.mimeType == "application/zotero",
                "the stranded source carries the byteless sync MIME (the issue's zero-byte source)")

        let queueAfterDenial = try QueueStore(databaseURL: world.queueDatabase)
        defer { queueAfterDenial.close() }
        #expect(try queueAfterDenial.loadActive(for: .extraction).isEmpty,
                "a denied enqueue must leave no durable job (the issue's missing extraction job)")

        // FIXED: the same valid --force request re-enqueues the existing
        // source; exactly one durable extraction job appears, targeting it.
        let allowed = try await runSandboxed(
            world, arguments: syncArgs, invocation: world.chatFence(queueAllowed: true))
        #expect(allowed.status == 0,
                "the fixed fence must let the enqueue through, stderr: \(allowed.standardError)")
        #expect(allowed.standardOutput.contains("re-enqueued"),
                "the re-enqueue outcome must be reported, stdout: \(allowed.standardOutput)")

        let queueAfterFix = try QueueStore(databaseURL: world.queueDatabase)
        defer { queueAfterFix.close() }
        let active = try queueAfterFix.loadActive(for: .extraction)
        #expect(active.count == 1, "exactly one durable job after the fixed enqueue")
        #expect(active.first?.payload.sourceIDs == [stranded?.id].compactMap { $0 },
                "the durable job must target the stranded source")
    }
}
#endif
