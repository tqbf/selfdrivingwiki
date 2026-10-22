#if os(macOS)
import Foundation
import Testing
import WikiCtlCore
import WikiDaemonContract
import WikiFSCore
import wikid

// Real end-to-end tests for the CLI ⇄ daemon search socket transport: actual
// AF_UNIX connections between `DaemonSearchSocketClient.transport` and
// `DaemonSearchSocketServer` in this process, carrying the real
// `SearchRPCRequest`/`SearchRPCReply` JSON through the real codec and the
// real `DaemonSearchClient` seam. No transport is mocked; only the daemon's
// search back end is replaced by a handler shaped exactly like
// `WikiDaemon.searchData` (decode through the wire, always answer with an
// encoded reply, never throw).
//
// Suite discipline per AGENTS.md #1051: `.serialized` + `.timeLimit`, and
// every scenario is bounded by a short injected timeout — never the 30 s
// production default.
@Suite(.serialized, .timeLimit(.minutes(3)))
struct DaemonSearchSocketTests {

    // MARK: Fixtures

    /// Unique throwaway container directory per test, so guard flocks never
    /// overlap. Left in place on purpose: the system temp cleaner owns
    /// scratch dirs, and a best-effort removal would race the server's own
    /// stop() unlink.
    private func makeContainer() -> URL {
        // Short name on purpose: the socket path must fit sockaddr_un's
        // 103-byte sun_path, and the system temp base already consumes most
        // of it. A long prefix pushed every fixture past the limit.
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "wsk-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    /// A handler shaped exactly like `WikiDaemon.searchData(request:)`:
    /// decode through `SearchRPCWire`, ALWAYS answer with a JSON
    /// `SearchRPCReply` (failures carry its `error`), never throw.
    private static func rpcHandler() -> @Sendable (Data) async -> Data {
        { request in
            let reply: SearchRPCReply
            do {
                let decoded = try SearchRPCWire.decode(request)
                switch decoded.operation {
                case .search(let query, _, _):
                    reply = .success([
                        SearchRPCHit(
                            documentID: "page:0100000000000000000000000A",
                            kind: "page",
                            title: "hit for \(query)",
                            score: 1)
                    ])
                case .autocomplete:
                    reply = .success([])
                }
            } catch let error as SearchRPCError {
                reply = .failure(error.code, error.message)
            } catch {
                reply = .failure(.invalidRequest, String(describing: error))
            }
            do {
                return try SearchRPCWire.encode(reply)
            } catch {
                // SearchRPCReply encoding cannot fail for these value
                // payloads; if it ever did, an empty body is the honest
                // "no reply" and the client surfaces it as malformed.
                return Data()
            }
        }
    }

    private static func sleepHandler() -> @Sendable (Data) async -> Data {
        { _ in
            // Deliberately outlives every timeout in this suite.
            try? await Task.sleep(for: .seconds(10))
            return Data()
        }
    }

    private func startServer(
        container: URL,
        handler: @escaping @Sendable (Data) async -> Data
    ) throws -> DaemonSearchSocketServer {
        let server = try DaemonSearchSocketServer(containerDirectory: container, handler: handler)
        try server.start()
        return server
    }

    /// Collects the transport's single reply. The transport contract is
    /// reply-exactly-once and deadline-bounded, so this continuation always
    /// resumes within the injected transport timeout.
    private func transportResult(
        _ transport: DaemonSearchTransport,
        request: Data
    ) async -> Result<Data, Error> {
        await withCheckedContinuation { continuation in
            transport(request) { result in
                continuation.resume(returning: result)
            }
        }
    }

    private func searchRequest(query: String) throws -> Data {
        try SearchRPCWire.encode(SearchRPCRequest(
            wikiID: "0100000000000000000000000A",
            operation: .search(query: query, kinds: nil, limit: 5)))
    }

    // MARK: Round trip

    @Test func roundTripRealSocketCarriesSearchReply() async throws {
        let container = makeContainer()
        let server = try startServer(container: container, handler: Self.rpcHandler())
        defer { server.stop() }

        let transport = try DaemonSearchSocketClient.transport(
            containerDirectory: container, timeout: 10)
        let client = DaemonSearchClient(transport: transport, timeout: 10)
        let hits = try await client.search(
            wikiID: WikiID(rawValue: "0100000000000000000000000A"),
            query: "hello",
            limit: 5)
        #expect(hits.count == 1)
        #expect(hits.first?.title == "hit for hello")
        #expect(hits.first?.kind == .page)
        #expect(hits.first?.documentID == "page:0100000000000000000000000A")
    }

    @Test func concurrentClientsAllRoundTrip() async throws {
        let container = makeContainer()
        let server = try startServer(container: container, handler: Self.rpcHandler())
        defer { server.stop() }

        let transport = try DaemonSearchSocketClient.transport(
            containerDirectory: container, timeout: 10)
        let client = DaemonSearchClient(transport: transport, timeout: 10)
        let counts = try await withThrowingTaskGroup(of: Int.self) { group -> [Int] in
            for index in 0..<8 {
                group.addTask {
                    let hits = try await client.search(
                        wikiID: WikiID(rawValue: "0100000000000000000000000A"),
                        query: "q\(index)",
                        limit: 1)
                    return hits.count
                }
            }
            var collected: [Int] = []
            for try await count in group {
                collected.append(count)
            }
            return collected
        }
        #expect(counts.count == 8)
        #expect(counts.allSatisfy { $0 == 1 })
    }

    /// Application-level failures travel INSIDE replies: a request the
    /// handler cannot decode comes back as a `SearchRPCError` payload, not a
    /// transport error.
    @Test func malformedRequestSurfacesAsApplicationFailure() async throws {
        let container = makeContainer()
        let server = try startServer(container: container, handler: Self.rpcHandler())
        defer { server.stop() }

        let transport = try DaemonSearchSocketClient.transport(
            containerDirectory: container, timeout: 5)
        let result = await transportResult(transport, request: Data("not json".utf8))
        let reply: SearchRPCReply
        switch result {
        case .failure(let error):
            Issue.record("expected a delivered reply, got transport failure \(error)")
            return
        case .success(let data):
            reply = try JSONDecoder().decode(SearchRPCReply.self, from: data)
        }
        #expect(reply.hits == nil)
        #expect(reply.error?.code == .invalidRequest)
    }

    // MARK: Absent daemon + bounds

    @Test func absentDaemonSurfacesExplicitNotRunningError() async throws {
        let container = makeContainer()
        let transport = try DaemonSearchSocketClient.transport(
            containerDirectory: container, timeout: 2)
        let result = await transportResult(transport, request: try searchRequest(query: "q"))
        guard case .failure(let error as SearchSocketError) = result,
              case .daemonNotRunning(let path) = error else {
            Issue.record("expected daemonNotRunning, got \(result)")
            return
        }
        #expect(path.hasSuffix(SearchSocketWire.socketFileName))
    }

    /// A leftover socket file with no listener (crashed-daemon shape) must
    /// also map to the explicit not-running error, not a raw errno.
    @Test func staleSocketWithoutListenerSurfacesNotRunning() async throws {
        let container = makeContainer()
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let socketPath = try SearchSocketWire.socketPath(inContainerDirectory: container)
        FileManager.default.createFile(atPath: socketPath, contents: nil)

        let transport = try DaemonSearchSocketClient.transport(
            containerDirectory: container, timeout: 2)
        let result = await transportResult(transport, request: try searchRequest(query: "q"))
        guard case .failure(let error as SearchSocketError) = result,
              case .daemonNotRunning = error else {
            Issue.record("expected daemonNotRunning, got \(result)")
            return
        }
    }

    /// The client-side frame cap trips BEFORE any connection is attempted —
    /// with no server present at all.
    @Test func oversizedRequestFailsFastWithoutConnecting() async throws {
        let container = makeContainer()
        let transport = try DaemonSearchSocketClient.transport(
            containerDirectory: container, timeout: 2)
        let oversized = Data(count: Int(SearchSocketWire.maxFrameSize) + 1)
        let result = await transportResult(transport, request: oversized)
        guard case .failure(let error as SearchSocketError) = result,
              case .frameTooLarge(let length) = error else {
            Issue.record("expected frameTooLarge, got \(result)")
            return
        }
        #expect(length == SearchSocketWire.maxFrameSize + 1)
    }

    /// A handler that never answers within the bound must surface the
    /// client's cancellation-safe timeout promptly instead of hanging.
    @Test func unresponsiveHandlerTimesOutWithoutHanging() async throws {
        let container = makeContainer()
        let server = try startServer(container: container, handler: Self.sleepHandler())
        defer { server.stop() }

        let transport = try DaemonSearchSocketClient.transport(
            containerDirectory: container, timeout: 5)
        let client = DaemonSearchClient(transport: transport, timeout: 1)
        do {
            _ = try await client.search(
                wikiID: WikiID(rawValue: "0100000000000000000000000A"),
                query: "q",
                limit: 1)
            Issue.record("expected the outer timeout to fire")
        } catch {
            #expect(error is DaemonXPCError)
        }
    }

    // MARK: Guard flock + stale cleanup

    @Test func secondServerFailsOnGuardWhileFirstServes() async throws {
        let container = makeContainer()
        let server = try startServer(container: container, handler: Self.rpcHandler())
        defer { server.stop() }

        let duplicatePath = try SearchSocketWire.socketPath(inContainerDirectory: container)
        #expect(throws: SearchSocketError.serverAlreadyRunning(path: duplicatePath)) {
            _ = try DaemonSearchSocketServer(
                containerDirectory: container, handler: Self.rpcHandler())
        }
    }

    /// A socket file left over from a dead process is replaced by a live
    /// listener on start — and stays owned (the guard was already held).
    @Test func staleSocketFileIsReplacedByLiveListener() async throws {
        let container = makeContainer()
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let socketPath = try SearchSocketWire.socketPath(inContainerDirectory: container)
        FileManager.default.createFile(atPath: socketPath, contents: Data("stale".utf8))

        let server = try startServer(container: container, handler: Self.rpcHandler())
        defer { server.stop() }

        let transport = try DaemonSearchSocketClient.transport(
            containerDirectory: container, timeout: 5)
        let client = DaemonSearchClient(transport: transport, timeout: 5)
        let hits = try await client.search(
            wikiID: WikiID(rawValue: "0100000000000000000000000A"),
            query: "stale",
            limit: 1)
        #expect(hits.count == 1)
    }

    @Test func stopTearsDownListenerAndReleasesGuard() async throws {
        let container = makeContainer()
        let server = try startServer(container: container, handler: Self.rpcHandler())
        let socketPath = try SearchSocketWire.socketPath(inContainerDirectory: container)
        server.stop()

        // The socket file is gone: the next client sees a clean ENOENT
        // ("not running"), not a refusal against a dead inode.
        #expect(FileManager.default.fileExists(atPath: socketPath) == false)

        // The guard is released: a fresh server takes over immediately.
        let second = try DaemonSearchSocketServer(
            containerDirectory: container, handler: Self.rpcHandler())
        try second.start()
        second.stop()
    }

    /// Stop is terminal: a restart on the same instance refuses.
    @Test func startAfterStopRefuses() throws {
        let container = makeContainer()
        let server = try startServer(container: container, handler: Self.rpcHandler())
        server.stop()
        #expect(throws: SearchSocketError.serverStopped) {
            try server.start()
        }
    }

    // MARK: Permissions

    @Test func permissionsAreOwnerOnly() throws {
        let container = makeContainer()
        // Created with the default umask (looser than 0700): the server must
        // tighten it, not just tolerate it.
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let server = try startServer(container: container, handler: Self.rpcHandler())
        defer { server.stop() }

        let directoryPermissions = try FileManager.default
            .attributesOfItem(atPath: container.path)[.posixPermissions] as? NSNumber
        #expect(directoryPermissions?.uint32Value == 0o700)

        let socketPath = try SearchSocketWire.socketPath(inContainerDirectory: container)
        let socketPermissions = try FileManager.default
            .attributesOfItem(atPath: socketPath)[.posixPermissions] as? NSNumber
        #expect(socketPermissions?.uint32Value == 0o600)
    }

    // MARK: Wire codec (pure checks of the shared framing, no sockets)

    @Test func frameParserRoundTripsAndEnforcesCap() throws {
        var parser = SearchSocketWire.FrameParser()
        let payload = Data("hello search".utf8)
        let frame = SearchSocketWire.framed(payload)

        // Feed one byte at a time and check every prefix state.
        var decoded: Data?
        for byte in frame {
            parser.append(Data([byte]))
            if let payload = try parser.nextPayload() {
                decoded = payload
            }
        }
        #expect(decoded == payload)
        #expect(parser.isMidFrame == false)

        // An announced oversize throws before any buffering.
        var over = SearchSocketWire.FrameParser()
        let oversizedLength = SearchSocketWire.maxFrameSize + 1
        var prefix = Data()
        let bigEndianLength = oversizedLength.bigEndian
        withUnsafeBytes(of: bigEndianLength) { prefix.append(contentsOf: $0) }
        over.append(prefix)
        #expect(throws: SearchSocketError.frameTooLarge(oversizedLength)) {
            _ = try over.nextPayload()
        }
    }

    @Test func pathValidationRejectsOversizedContainerPath() throws {
        let longDirectory = URL(fileURLWithPath: String(repeating: "d", count: 200))
        let expectedActual = longDirectory
            .appendingPathComponent(SearchSocketWire.socketFileName)
            .path.utf8.count
        #expect(expectedActual > SearchSocketWire.maxPathBytes)
        #expect(throws: SearchSocketError.pathTooLong(
            limit: SearchSocketWire.maxPathBytes, actual: expectedActual)) {
            _ = try SearchSocketWire.socketPath(inContainerDirectory: longDirectory)
        }
    }
}
#endif
