#if os(macOS)
import Foundation
import Testing
import WikiDaemonGRPC
import WikiDaemonGRPCContract

/// Rust↔Swift conformance for the app–daemon wire contract (AC.4,
/// plans/app-daemon-wire-contract.md): the SAME corpus drives both roles.
///
/// Role A: the Rust fixture server (`serve`) answers the PRODUCTION Swift
/// client; the Swift side compares decoded values and presence against the
/// corpus.
///
/// Role B: the PRODUCTION Swift listener answers the Rust probe
/// (`probe`); the probe compares decoded values and presence against the
/// same corpus and exits 0 only when every check passed.
///
/// The peer binary must exist for this tier (`make app-daemon-interop`);
/// its absence fails the suite rather than skipping it.
@Suite("App Daemon Rust interop", .serialized, .timeLimit(.minutes(8)))
struct AppDaemonRustInteropTests {

    // MARK: - Peer + corpus location

    static func peerPath() -> String {
        if let override = ProcessInfo.processInfo.environment["WIKIFS_INTEROP_PEER"] {
            return override
        }
        // Default: the make target's build output (repo-root relative).
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/WikiFSAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        return repoRoot
            .appendingPathComponent("tools/app-daemon-interop/target/debug/app-daemon-interop")
            .path
    }

    static func corpusPath() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let path = repoRoot
            .appendingPathComponent("Protocol/app-daemon/fixtures/corpus.json")
            .path
        guard FileManager.default.fileExists(atPath: path) else {
            throw AppDaemonFailure(
                code: .invalidRequest,
                message: "shared corpus missing at \(path)")
        }
        return path
    }

    /// The tier requires the peer; a missing binary is a loud failure,
    /// never a skip.
    static func requirePeer() throws -> String {
        let path = peerPath()
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw AppDaemonFailure(
                code: .invalidRequest,
                message: """
                    Rust interop peer missing at \(path). \
                    Build it with `make app-daemon-interop` — this tier was \
                    selected, so the test peer must exist.
                    """)
        }
        return path
    }

    // MARK: - Role A: Rust fixture server → production Swift client

    @Test("role A: rust fixture server serves the production swift client")
    func rustServesSwiftClient() async throws {
        let peer = try Self.requirePeer()
        let corpus = try Self.corpusPath()
        let socketPath = Self.smokeSocketPath("interop-a")
        let server = try PeerProcess(
            peer: peer, args: [
                "serve", "--socket", socketPath,
                "--corpus", corpus,
            ])
        try await server.waitUntilSocketReady(timeout: .seconds(10))
        try server.ensureRunning(context: "role A normal")
        defer { server.stop() }

        let client = try AppDaemonSessionClient(admission: AppDaemonAdmission(
            socketPath: socketPath,
            bootstrapCredentialHex: "fixture-bootstrap-credential",
            daemonInstanceID: "fixture-instance",
            expiresAt: Date().addingTimeInterval(30)))
        defer { client.close() }
        try await client.bootstrap()
        #expect(client.authenticatedInstanceID == "fixture-instance")
        // Registry read: decoded values + presence against the corpus.
        let reply = try await client.listWikis()
        #expect(reply.wikis.count == 2)
        #expect(reply.wikis[0].id.value == "01HZY4WXQ8PJ7RKP3GV9X8QW2T")
        #expect(reply.wikis[0].displayName == "Fixture Wiki")
        #expect(reply.wikis[0].hasCreatedAt)
        #expect(!reply.wikis[0].hasHomePageID)
        #expect(reply.wikis[1].displayName == "Second Wiki 兄")
        #expect(reply.wikis[1].hasHomePageID)
        #expect(reply.wikis[1].homePageID.value
            == "01HPAGE0123456789ABCDEFGHIJKLMNOP")

        // Typed events: the corpus's registry events, in order.
        let stream = client.subscribeRegistryEvents()
        var iterator = stream.makeAsyncIterator()
        let created = try await iterator.next()
        #expect(created?.kind == .created)
        #expect(created?.wikiID.value == "01HZY4WXQ8PJ7RKP3GV9X8QW2T")
        #expect(created?.displayName == "Fixture Wiki")
        let deleted = try await iterator.next()
        #expect(deleted?.kind == .deleted)
        #expect(deleted?.wikiID.value == "01JABCDEF0123456789ABCDEF0")
        #expect(deleted?.hasDisplayName == false)
    }

    @Test("role A: oversized reply fails at the declared bound")
    func rustServerOversizedReplyFails() async throws {
        let peer = try Self.requirePeer()
        let corpus = try Self.corpusPath()
        let socketPath = Self.smokeSocketPath("interop-oversize")
        let server = try PeerProcess(
            peer: peer, args: [
                "serve", "--socket", socketPath,
                "--corpus", corpus, "--oversize-response",
            ])
        try await server.waitUntilSocketReady(timeout: .seconds(10))
        try server.ensureRunning(context: "role A oversize")
        defer { server.stop() }

        let client = try AppDaemonSessionClient(admission: AppDaemonAdmission(
            socketPath: socketPath,
            bootstrapCredentialHex: "fixture-bootstrap-credential",
            daemonInstanceID: "fixture-instance",
            expiresAt: Date().addingTimeInterval(30)))
        defer { client.close() }
        try await client.bootstrap()
        do {
            _ = try await client.listWikis()
            Issue.record("oversized reply must fail at the declared bound")
        } catch let failure as AppDaemonFailure {
            // grpc-swift reports the enforced bound as RESOURCE_EXHAUSTED;
            // the transport may surface the frame-level rejection as an
            // unavailable-family typed failure. Either way it must NOT
            // succeed and must be a typed failure, never a crash.
            #expect(
                failure.code == .resourceExhausted || failure.code == .unavailable)
        }
    }

    @Test("role A: incompatible capabilities fail the handshake typed")
    func rustServerIncompatibleCapabilitiesFails() async throws {
        let peer = try Self.requirePeer()
        let corpus = try Self.corpusPath()
        let socketPath = Self.smokeSocketPath("interop-incompatible")
        let server = try PeerProcess(
            peer: peer, args: [
                "serve", "--socket", socketPath,
                "--corpus", corpus, "--incompatible",
            ])
        try await server.waitUntilSocketReady(timeout: .seconds(10))
        try server.ensureRunning(context: "role A incompatible")
        defer { server.stop() }

        let client = try AppDaemonSessionClient(admission: AppDaemonAdmission(
            socketPath: socketPath,
            bootstrapCredentialHex: "fixture-bootstrap-credential",
            daemonInstanceID: "fixture-instance",
            expiresAt: Date().addingTimeInterval(30)))
        defer { client.close() }
        do {
            try await client.bootstrap()
            Issue.record("incompatible contract version must fail the handshake")
        } catch let failure as AppDaemonFailure {
            #expect(failure.code == .capabilityMismatch)
        }
    }

    @Test("role A: typed error carries the versioned details")
    func rustServerTypedErrorCarriesDetails() async throws {
        let peer = try Self.requirePeer()
        let corpus = try Self.corpusPath()
        let socketPath = Self.smokeSocketPath("interop-error")
        let server = try PeerProcess(
            peer: peer, args: [
                "serve", "--socket", socketPath,
                "--corpus", corpus, "--serve-error", "error-wiki-not-found",
            ])
        try await server.waitUntilSocketReady(timeout: .seconds(10))
        try server.ensureRunning(context: "role A error")
        defer { server.stop() }

        let client = try AppDaemonSessionClient(admission: AppDaemonAdmission(
            socketPath: socketPath,
            bootstrapCredentialHex: "fixture-bootstrap-credential",
            daemonInstanceID: "fixture-instance",
            expiresAt: Date().addingTimeInterval(30)))
        defer { client.close() }
        try await client.bootstrap()
        do {
            _ = try await client.listWikis()
            Issue.record("injected wiki-not-found must fail typed")
        } catch let failure as AppDaemonFailure {
            #expect(failure.code == .wikiNotFound)
            #expect(failure.message == "no such wiki")
            #expect(failure.daemonInstanceID == "fixture-instance")
            #expect(failure.retryable == false)
        }
    }

    // MARK: - Role B: production Swift server → Rust probe

    @Test("role B: production swift server serves the rust probe")
    func swiftServesRustProbe() async throws {
        let peer = try Self.requirePeer()
        let corpus = try Self.corpusPath()
        let reply = try Self.corpusListWikisReply()

        let socketPath = Self.smokeSocketPath("interop-b")
        let harness = try await InteropHarness.make(
            socketPath: socketPath,
            listWikis: { reply },
            publishEventsOnSubscribe: true)
        defer { harness.stopInBackground() }

        let result = try await PeerProcess.runToCompletion(
            peer: peer, args: [
                "probe", "--socket", socketPath,
                "--corpus", corpus,
            ],
            timeout: .seconds(60))
        #expect(result.exitCode == 0, "probe failed: \(result.stderr)")
    }

    @Test("role B: rust probe verifies the typed error")
    func rustProbeVerifiesTypedError() async throws {
        let peer = try Self.requirePeer()
        let corpus = try Self.corpusPath()

        let socketPath = Self.smokeSocketPath("interop-b-error")
        let harness = try await InteropHarness.make(
            socketPath: socketPath,
            listWikis: {
                throw AppDaemonFailure(
                    code: .wikiNotFound,
                    message: "no such wiki",
                    daemonInstanceID: nil)
            },
            publishEventsOnSubscribe: false)
        defer { harness.stopInBackground() }

        let result = try await PeerProcess.runToCompletion(
            peer: peer, args: [
                "probe", "--socket", socketPath,
                "--corpus", corpus, "--expect-error", "error-wiki-not-found",
            ],
            timeout: .seconds(60))
        #expect(result.exitCode == 0, "probe failed: \(result.stderr)")
    }

    @Test("role B: rust probe verifies the oversize bound")
    func rustProbeVerifiesOversizeBound() async throws {
        let peer = try Self.requirePeer()
        let corpus = try Self.corpusPath()

        let socketPath = Self.smokeSocketPath("interop-b-oversize")
        let harness = try await InteropHarness.make(
            socketPath: socketPath,
            listWikis: {
                // A reply padded past the declared 4 MiB bound. The probe's
                // decode limit must reject it predictably.
                AppDaemonListWikisReply.with {
                    $0.wikis = [AppDaemonWikiDescriptor.with {
                        $0.id = AppDaemonWikiId.with {
                            $0.value = "01HZY4WXQ8PJ7RKP3GV9X8QW2T"
                        }
                        $0.displayName = String(repeating: "p", count: 5 * 1024 * 1024)
                    }]
                }
            },
            publishEventsOnSubscribe: false)
        defer { harness.stopInBackground() }

        let result = try await PeerProcess.runToCompletion(
            peer: peer, args: [
                "probe", "--socket", socketPath,
                "--corpus", corpus, "--expect-oversize",
            ],
            timeout: .seconds(60))
        #expect(result.exitCode == 0, "probe failed: \(result.stderr)")
    }

    @Test("role B: rust probe detects incompatible capabilities")
    func rustProbeDetectsIncompatibleCapabilities() async throws {
        let peer = try Self.requirePeer()
        let corpus = try Self.corpusPath()

        let socketPath = Self.smokeSocketPath("interop-b-incompatible")
        let harness = try await InteropHarness.make(
            socketPath: socketPath,
            listWikis: { AppDaemonListWikisReply() },
            publishEventsOnSubscribe: false,
            contractVersion: 2)
        defer { harness.stopInBackground() }

        let result = try await PeerProcess.runToCompletion(
            peer: peer, args: [
                "probe", "--socket", socketPath,
                "--corpus", corpus, "--expect-incompatible",
            ],
            timeout: .seconds(60))
        #expect(result.exitCode == 0, "probe failed: \(result.stderr)")
    }

    // MARK: - Corpus decode (Swift side)

    /// The corpus's `list-wikis-basic` reply, decoded into the wire type —
    /// the Swift ENCODER path the Rust probe validates against.
    static func corpusListWikisReply() throws -> AppDaemonListWikisReply {
        struct Corpus: Decodable {
            struct Case: Decodable {
                let id: String
                let operation: String
                let reply: Reply?
            }
            struct Reply: Decodable {
                struct Wiki: Decodable {
                    let id: String
                    let displayName: String
                    let createdAt: String
                    let lastUsedAt: String
                    let homePageID: String?
                }
                let wikis: [Wiki]
            }
            let cases: [Case]
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: corpusPath()))
        let corpus = try JSONDecoder().decode(Corpus.self, from: data)
        guard let basic = corpus.cases
            .first(where: { $0.id == "list-wikis-basic" && $0.operation == "listWikis" })?
            .reply
        else {
            throw AppDaemonFailure(
                code: .invalidRequest,
                message: "corpus case list-wikis-basic missing")
        }
        let formatter = ISO8601DateFormatter()
        return AppDaemonListWikisReply.with {
            $0.wikis = basic.wikis.map { wiki in
                AppDaemonWikiDescriptor.with {
                    $0.id = AppDaemonWikiId.with { $0.value = wiki.id }
                    $0.displayName = wiki.displayName
                    $0.createdAt = .init(date: Self.decodeDate(formatter, wiki.createdAt))
                    $0.lastUsedAt = .init(date: Self.decodeDate(formatter, wiki.lastUsedAt))
                    if let homePageID = wiki.homePageID {
                        $0.homePageID = AppDaemonPageId.with { $0.value = homePageID }
                    }
                }
            }
        }
    }

    /// Corpus timestamps are whole seconds UTC; a malformed one is a
    /// corpus bug and fails the test loudly instead of force-unwrapping.
    static func decodeDate(_ formatter: ISO8601DateFormatter, _ value: String) -> Date {
        guard let date = formatter.date(from: value) else {
            fatalError("corpus timestamp unparseable: \(value)")
        }
        return date
    }

    static func smokeSocketPath(_ name: String) -> String {
        // The listener composes <container>/g/s; the peer is told the same
        // complete path, so both sides must agree on it. STABLE per name:
        // callers capture it ONCE and pass the same value to the peer and
        // the client. The peer removes stale files at bind.
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikid-interop-\(name)", isDirectory: true)
        return container
            .appendingPathComponent("g", isDirectory: true)
            .appendingPathComponent("s", isDirectory: false)
            .path
    }
}

/// The Swift-side harness for Role B: a real listener whose workload
/// handlers are driven from the corpus (fixture operations injected behind
/// the shipping provider — every reply goes through the production mapping
/// and encoder).
private struct InteropHarness {
    let listener: DaemonGRPCListener
    let hub: DaemonRegistryEventHub

    static func make(
        socketPath: String,
        listWikis: @escaping @Sendable () async throws -> AppDaemonListWikisReply,
        publishEventsOnSubscribe: Bool,
        contractVersion: UInt32? = nil
    ) async throws -> InteropHarness {
        let harness = try await InteropHarness.makeLocked(
            socketPath: socketPath,
            listWikis: listWikis,
            publishEventsOnSubscribe: publishEventsOnSubscribe,
            contractVersion: contractVersion)
        return harness
    }

    private static func makeLocked(
        socketPath: String,
        listWikis: @escaping @Sendable () async throws -> AppDaemonListWikisReply,
        publishEventsOnSubscribe: Bool,
        contractVersion: UInt32?
    ) async throws -> InteropHarness {
        // The container is the socket path's grandparent: the listener
        // composes <container>/g/s, and the peer is told that same path.
        let components = (socketPath as NSString).pathComponents // […, g, s]
        let containerComponents = components.dropLast(2)
        let container = URL(fileURLWithPath: "/" + containerComponents.joined(separator: "/"),
                            isDirectory: true)

        // Stale teardown from a previous run of the same name (the
        // listener replaces stale socket FILES, but a previous g dir's
        // leftovers should not leak into this run).
        // Test-teardown/cleanup: the failure path is the assertion below.
        // swiftlint:disable:next silent_try_optional
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: socketPath).deletingLastPathComponent())
        let hub = DaemonRegistryEventHub()
        let store = DaemonSessionStore()
        // Seed the corpus's fixed bootstrap through the production issuer's
        // fixture seam, so the peer can admit exactly like the corpus says.
        store.seedBootstrapForFixtures(
            bootstrapHex: "fixture-bootstrap-credential",
            sessionHex: "647570657373696f6e63726564656e7469616c3332",
            connectionID: "fixture-connection")
        let provider = AppDaemonServiceProvider(
            store: store,
            hub: hub,
            handlers: .init(listWikis: listWikis),
            contractVersion: contractVersion,
            daemonInstanceID: "fixture-instance")
        let listener = try DaemonGRPCListener(
            containerDirectory: container,
            provider: provider,
            onShutdown: { store.revokeAll(); hub.closeAll() })
        try listener.start()
        try await listener.waitUntilServing(timeout: .seconds(10))

        if publishEventsOnSubscribe {
            // Publish the corpus's registry events once the probe's
            // subscription is live (the stream carries no replay).
            let publisher = Task {
                let deadline = ContinuousClock.now.advanced(by: .seconds(20))
                while hub.subscriptionCount == 0 && ContinuousClock.now < deadline {
                    // Test-teardown/cleanup: the failure path is the assertion below.
                    // swiftlint:disable:next silent_try_optional
                    try? await Task.sleep(for: .milliseconds(50))
                }
                hub.publish(kind: .created, wikiIDRawValue: "01HZY4WXQ8PJ7RKP3GV9X8QW2T",
                            displayName: "Fixture Wiki")
                hub.publish(kind: .deleted, wikiIDRawValue: "01JABCDEF0123456789ABCDEF0",
                            displayName: nil)
            }
            _ = publisher
        }
        return InteropHarness(listener: listener, hub: hub)
    }

    func stopInBackground() {
        let listener = listener
        Task.detached(priority: .utility) {
            await listener.stop()
        }
    }
}

/// Non-blocking peer-process runner (AGENTS.md subprocess rules: no
/// waitUntilExit on the cooperative pool; a timeout turns a starved wait
/// into a fast, diagnosed failure). The Process handle is boxed because
/// Process is not Sendable and both racing tasks need it.
private struct PeerProcess {
    let process: Process

    init(peer: String, args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: peer)
        process.arguments = args
        // Child output lands beside the socket for post-mortem (bind
        // failures, panics) — decisive when connect failures are indirect.
        if let socket = args.first(where: { $0.hasSuffix("/s") }) {
            let output = URL(fileURLWithPath: socket)
                .deletingLastPathComponent()
                .appendingPathComponent("serve-output.txt")
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: output.path, contents: nil)
            process.standardError = try FileHandle(forWritingTo: output)
            process.standardOutput = process.standardError
        }
        self.process = process
        try process.run()
    }

    /// The fixture server's own output (its bind failures and panics print
    /// here; surfacing them turns "socket never ready" into a diagnosis).
    func drainOutput() -> String {
        guard let socket = process.arguments?.first(where: { $0.hasSuffix("/s") }) else {
            return ""
        }
        let output = URL(fileURLWithPath: socket)
            .deletingLastPathComponent()
            .appendingPathComponent("serve-output.txt")
        // A missing/empty file just means the server printed nothing —
        // that is the common healthy case, not a swallowed error.
        // swiftlint:disable:next silent_try_optional
        return (try? String(contentsOf: output, encoding: .utf8)) ?? ""
    }

    /// Wait for the fixture server's socket to be ACTUALLY accepting (the
    /// socket file appears at bind; the accept loop starts a beat later —
    /// connecting is the only real readiness signal, and callers hand the
    /// endpoint out only after it).
    func waitUntilSocketReady(timeout: Duration) async throws {
        let socket = process.arguments?.first { $0.hasSuffix("/s") } ?? ""
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            guard process.isRunning else {
                throw AppDaemonFailure(
                    code: .unavailable,
                    message: "fixture server exited before binding: \(drainOutput())")
            }
            if await DaemonGRPCListener.endpointAccepts(path: socket) {
                return
            }
            // Test-teardown/cleanup: the failure path is the assertion below.
            // swiftlint:disable:next silent_try_optional
            try? await Task.sleep(for: .milliseconds(50))
        }
        throw AppDaemonFailure(
            code: .deadlineExceeded,
            message: "fixture server did not accept on \(socket) within \(timeout); \(drainOutput())")
    }

    func stop() {
        if process.isRunning {
            process.interrupt()
        }
    }

    func ensureRunning(context: String) throws {
        guard process.isRunning else {
            throw AppDaemonFailure(
                code: .unavailable,
                message: "\(context): fixture server exited: \(drainOutput())")
        }
    }

    static func runToCompletion(
        peer: String, args: [String], timeout: Duration
    ) async throws -> (exitCode: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: peer)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let box = ProcessBox(process: process, pipe: pipe)
        try process.run()

        return try await withThrowingTaskGroup(of: (Int32, String).self) { group in
            group.addTask {
                await box.waitAndDrain()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                box.interrupt()
                throw AppDaemonFailure(
                    code: .deadlineExceeded,
                    message: "peer probe did not exit within \(timeout)")
            }
            let first = try await group.next() ?? (0, "no task result")
            group.cancelAll()
            return first
        }
    }
}

/// @unchecked Sendable: Process and Pipe are documented thread-safe for
/// terminationHandler + read; the box exists only to satisfy the Sendable
/// boundary for the racing wait/timeout tasks.
// Process and Pipe are documented thread-safe for terminationHandler +
// read; the box exists only to cross the Sendable boundary for the racing
// wait/timeout tasks.
// swiftlint:disable:next unchecked_sendable
private final class ProcessBox: @unchecked Sendable {
    private let process: Process
    private let pipe: Pipe

    init(process: Process, pipe: Pipe) {
        self.process = process
        self.pipe = pipe
    }

    func interrupt() {
        if process.isRunning {
            process.interrupt()
        }
    }

    func waitAndDrain() async -> (Int32, String) {
        let code: Int32 = await withCheckedContinuation { continuation in
            let tracked = process
            if !tracked.isRunning {
                continuation.resume(returning: tracked.terminationStatus)
                return
            }
            tracked.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return (code, text)
    }
}
#endif
