#if os(macOS)
// Fault injection at the `DaemonSearchClient` transport seam.
//
// The transport closure replaces the daemon's `search(request:reply:)` XPC
// method, so every scenario here runs without a daemon: a fake can answer,
// hold, corrupt, or never answer a reply. Pinned contract (mirrors
// `DaemonWorkloadClientTimeoutTests`):
//
// 1. a never-replying transport surfaces `DaemonXPCError.timeout` promptly,
// 2. a reply arriving after the timeout is absorbed (exactly one resume — a
//    double resume traps at runtime) and later calls still work,
// 3. normal replies decode to typed `[TantivyShadowSearchResult]`,
// 4. daemon-reported `SearchRPCError`s surface as `.failure`,
// 5. a reply carrying NEITHER hits NOR error is malformed, not an empty
//    success,
// 6. cancelling the caller releases the pending wait.
//
// Suite discipline per AGENTS.md #1051: `.serialized` + `.timeLimit`, and
// every scenario is bounded by a short injected `timeout` — never the 30 s
// production default.

import Foundation
import Testing
import WikiCtlCore
import WikiDaemonContract
import WikiFSSearch
@testable import WikiCtlCore

@Suite(.serialized, .timeLimit(.minutes(2)))
struct DaemonSearchClientTests {

    /// Short injected per-call bound so scenarios finish in well under a
    /// second of waiting.
    private static let testTimeout: TimeInterval = 0.5

    /// Generous wall-clock ceiling for "the timeout was delivered promptly" —
    /// catches a regression to never-returning behavior without being
    /// load-sensitive.
    private static let promptDeliveryCeiling: Duration = .seconds(10)

    private static let wikiID = WikiID(rawValue: "01TESTSEARCH")

    // MARK: - Fakes

    /// Thread-safe record of the wire requests the client sent.
    private final class RequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [SearchRPCRequest] = []

        func record(_ request: SearchRPCRequest) {
            lock.lock()
            requests.append(request)
            lock.unlock()
        }

        func snapshot() -> [SearchRPCRequest] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }
    }

    /// A transport whose reply behavior each test controls.
    private final class ControlledTransport: @unchecked Sendable {
        enum Behavior {
            case replyImmediately(Data)
            case transportFailure(any Error)
            /// Capture the reply closure; nothing is delivered until
            /// ``deliverHeld(_:)`` (or never).
            case hold
        }

        private let lock = NSLock()
        private var behavior: Behavior
        private var heldReply: (@Sendable (Result<Data, any Error>) -> Void)?

        init(behavior: Behavior) {
            self.behavior = behavior
        }

        func setBehavior(_ newBehavior: Behavior) {
            lock.lock()
            behavior = newBehavior
            lock.unlock()
        }

        /// Fire the held reply exactly once. Returns `false` when nothing
        /// was held (e.g. no request was ever sent).
        @discardableResult
        func deliverHeld(_ result: Result<Data, any Error>) -> Bool {
            lock.lock()
            let reply = heldReply
            heldReply = nil
            lock.unlock()
            reply?(result)
            return reply != nil
        }

        func send(_ request: Data, _ reply: @escaping @Sendable (Result<Data, any Error>) -> Void) {
            lock.lock()
            switch behavior {
            case .replyImmediately(let data):
                lock.unlock()
                reply(.success(data))
            case .transportFailure(let error):
                lock.unlock()
                reply(.failure(error))
            case .hold:
                heldReply = reply
                lock.unlock()
            }
        }
    }

    /// Transport that decodes and records every request, then delegates the
    /// reply behavior to a `ControlledTransport`.
    private func recordingTransport(
        _ recorder: RequestRecorder,
        _ controlled: ControlledTransport
    ) -> DaemonSearchTransport {
        return { request, reply in
            if let decoded = try? SearchRPCWire.decode(request) {
                recorder.record(decoded)
            }
            controlled.send(request, reply)
        }
    }

    // MARK: - Reply builders

    private static func hit(ulid: String, kind: TantivyDocumentKind = .page, score: Double) -> SearchRPCHit {
        SearchRPCHit(documentID: kind.documentID(for: ulid), kind: kind.rawValue, title: "t-\(ulid)", score: score)
    }

    private static func replyData(_ reply: SearchRPCReply) -> Data {
        // SearchRPCReply always encodes; a failure here is a test bug.
        try! JSONEncoder().encode(reply)
    }

    private static func successReplyData(_ hits: [SearchRPCHit]) -> Data {
        replyData(.success(hits))
    }

    // MARK: - Happy path + wire mapping

    @Test func searchDecodesHitsIntoTypedResultsInReplyOrder() async throws {
        let recorder = RequestRecorder()
        let transport = ControlledTransport(behavior: .hold)
        let client = DaemonSearchClient(
            transport: recordingTransport(recorder, transport),
            timeout: Self.testTimeout)

        transport.setBehavior(.replyImmediately(Self.successReplyData([
            Self.hit(ulid: "01AAAA", score: 3.5),
            Self.hit(ulid: "01BBBB", kind: .chat, score: 1.25),
        ])))

        let results = try await client.search(
            wikiID: Self.wikiID, query: "rust", kinds: [.page], limit: 7)

        // The wire request carried the typed inputs.
        let sent = try #require(recorder.snapshot().first)
        #expect(sent.version == SearchRPCVersion.current)
        #expect(sent.wikiID == Self.wikiID.rawValue)
        #expect(sent.operation == .search(query: "rust", kinds: ["page"], limit: 7))

        // Hits decode best-first, kind + Float score mapped.
        #expect(results.count == 2)
        #expect(results[0].documentID == TantivyDocumentKind.page.documentID(for: "01AAAA"))
        #expect(results[0].kind == .page)
        #expect(results[0].score == Float(3.5))
        #expect(results[1].kind == .chat)
        #expect(results[1].ulid == "01BBBB")
    }

    @Test func searchWithNoKindsSendsNilKindsOnTheWire() async throws {
        let recorder = RequestRecorder()
        let transport = ControlledTransport(behavior: .hold)
        let client = DaemonSearchClient(
            transport: recordingTransport(recorder, transport),
            timeout: Self.testTimeout)

        transport.setBehavior(.replyImmediately(Self.successReplyData([])))
        let results = try await client.search(wikiID: Self.wikiID, query: "anything")

        // Empty kinds means "all kinds" — encoded as absent, not [].
        let sent = try #require(recorder.snapshot().first)
        #expect(sent.operation == .search(query: "anything", kinds: nil, limit: 20))
        #expect(results.isEmpty)
    }

    @Test func autocompleteSendsPartialSortedKindsDistanceAndLimit() async throws {
        let recorder = RequestRecorder()
        let transport = ControlledTransport(behavior: .hold)
        let client = DaemonSearchClient(
            transport: recordingTransport(recorder, transport),
            timeout: Self.testTimeout)

        transport.setBehavior(.replyImmediately(Self.successReplyData([
            Self.hit(ulid: "01CCCC", kind: .source, score: 2),
        ])))

        let results = try await client.autocomplete(
            wikiID: Self.wikiID,
            partial: "hel",
            kinds: [.chat, .source],
            distance: 3,
            limit: 5)

        let sent = try #require(recorder.snapshot().first)
        #expect(sent.operation == .autocomplete(
            partial: "hel", kinds: ["chat", "source"], distance: 3, limit: 5))
        #expect(results.count == 1)
        #expect(results[0].kind == .source)
    }

    // MARK: - Error mapping

    @Test func daemonErrorReplySurfacesAsFailureWithCode() async throws {
        let transport = ControlledTransport(behavior: .replyImmediately(Self.replyData(
            .failure(.operationFailed, "index closed"))))
        let client = DaemonSearchClient(transport: { transport.send($0, $1) }, timeout: Self.testTimeout)

        do {
            _ = try await client.search(wikiID: Self.wikiID, query: "q", limit: 5)
            Issue.record("expected .failure")
        } catch let error as DaemonXPCError {
            guard case .failure(let message) = error else {
                Issue.record("expected .failure, got \(error)")
                return
            }
            #expect(message.contains("operationFailed"))
            #expect(message.contains("index closed"))
        } catch {
            Issue.record("expected DaemonXPCError, got \(error)")
        }
    }

    @Test func malformedReplySurfacesAsUnexpectedReply() async throws {
        let transport = ControlledTransport(behavior: .replyImmediately(Data("not json".utf8)))
        let client = DaemonSearchClient(transport: { transport.send($0, $1) }, timeout: Self.testTimeout)

        do {
            _ = try await client.search(wikiID: Self.wikiID, query: "q", limit: 5)
            Issue.record("expected .unexpectedReply")
        } catch let error as DaemonXPCError {
            guard case .unexpectedReply = error else {
                Issue.record("expected .unexpectedReply, got \(error)")
                return
            }
        } catch {
            Issue.record("expected DaemonXPCError, got \(error)")
        }
    }

    @Test func wrongVersionReplySurfacesAsUnexpectedReply() async throws {
        let transport = ControlledTransport(behavior: .replyImmediately(Self.replyData(
            SearchRPCReply(version: 99, hits: [], error: nil))))
        let client = DaemonSearchClient(transport: { transport.send($0, $1) }, timeout: Self.testTimeout)

        do {
            _ = try await client.autocomplete(wikiID: Self.wikiID, partial: "a", limit: 3)
            Issue.record("expected .unexpectedReply")
        } catch let error as DaemonXPCError {
            guard case .unexpectedReply = error else {
                Issue.record("expected .unexpectedReply, got \(error)")
                return
            }
        } catch {
            Issue.record("expected DaemonXPCError, got \(error)")
        }
    }

    @Test func replyWithNeitherHitsNorErrorIsMalformedNotEmptySuccess() async throws {
        let transport = ControlledTransport(behavior: .replyImmediately(Self.replyData(
            SearchRPCReply(version: SearchRPCVersion.current, hits: nil, error: nil))))
        let client = DaemonSearchClient(transport: { transport.send($0, $1) }, timeout: Self.testTimeout)

        do {
            let results = try await client.search(wikiID: Self.wikiID, query: "q", limit: 5)
            Issue.record("expected .unexpectedReply, got \(results)")
        } catch let error as DaemonXPCError {
            guard case .unexpectedReply = error else {
                Issue.record("expected .unexpectedReply, got \(error)")
                return
            }
        } catch {
            Issue.record("expected DaemonXPCError, got \(error)")
        }
    }

    @Test func hitNamingUnknownKindSurfacesAsUnexpectedReply() async throws {
        let bogus = SearchRPCHit(documentID: "bookmark:01DDDD", kind: "bookmark", title: "t", score: 1)
        let transport = ControlledTransport(behavior: .replyImmediately(Self.successReplyData([bogus])))
        let client = DaemonSearchClient(transport: { transport.send($0, $1) }, timeout: Self.testTimeout)

        do {
            _ = try await client.search(wikiID: Self.wikiID, query: "q", limit: 5)
            Issue.record("expected .unexpectedReply")
        } catch let error as DaemonXPCError {
            guard case .unexpectedReply = error else {
                Issue.record("expected .unexpectedReply, got \(error)")
                return
            }
        } catch {
            Issue.record("expected DaemonXPCError, got \(error)")
        }
    }

    @Test func transportFailureRethrowsAsIs() async throws {
        struct SeededFailure: Error {}
        let transport = ControlledTransport(behavior: .transportFailure(SeededFailure()))
        let client = DaemonSearchClient(transport: { transport.send($0, $1) }, timeout: Self.testTimeout)

        do {
            _ = try await client.search(wikiID: Self.wikiID, query: "q", limit: 5)
            Issue.record("expected SeededFailure")
        } catch is SeededFailure {
            // The transport owns its failure vocabulary; the client rethrows.
        } catch {
            Issue.record("expected SeededFailure, got \(error)")
        }
    }

    // MARK: - Timeout / straggler / cancellation

    @Test func neverReplyingTransportTimesOutPromptly() async throws {
        let transport = ControlledTransport(behavior: .hold)
        let client = DaemonSearchClient(transport: { transport.send($0, $1) }, timeout: Self.testTimeout)

        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await client.search(wikiID: Self.wikiID, query: "q", limit: 5)
            Issue.record("expected .timeout")
        } catch let error as DaemonXPCError {
            guard case .timeout = error else {
                Issue.record("expected .timeout, got \(error)")
                return
            }
        } catch {
            Issue.record("expected DaemonXPCError.timeout, got \(error)")
        }
        #expect(clock.now - start < Self.promptDeliveryCeiling)
    }

    @Test func lateReplyAfterTimeoutIsAbsorbedAndNextSearchWorks() async throws {
        let transport = ControlledTransport(behavior: .hold)
        let client = DaemonSearchClient(transport: { transport.send($0, $1) }, timeout: Self.testTimeout)

        // First call times out while the transport holds the reply.
        await #expect(throws: DaemonXPCError.self) {
            try await client.search(wikiID: Self.wikiID, query: "slow", limit: 5)
        }

        // The straggling reply arrives afterwards — absorbing it must not
        // double-resume (which traps the process).
        #expect(transport.deliverHeld(.success(Self.successReplyData([Self.hit(ulid: "01EEEE", score: 1)]))))

        // The client stays usable: the next call answers normally.
        transport.setBehavior(.replyImmediately(Self.successReplyData([Self.hit(ulid: "01FFFF", score: 2)])))
        let results = try await client.search(wikiID: Self.wikiID, query: "fast", limit: 5)
        #expect(results.map(\.ulid) == ["01FFFF"])
    }

    @Test func cancellingPendingSearchReleasesTheWaitPromptly() async throws {
        let transport = ControlledTransport(behavior: .hold)
        let client = DaemonSearchClient(transport: { transport.send($0, $1) }, timeout: 60)

        let task = Task { try await client.search(wikiID: Self.wikiID, query: "q", limit: 5) }
        // Let the task install its continuation before cancelling.
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected CancellationError")
        } catch is CancellationError {
            // Cancellation released the box; no 60 s timeout, no hang.
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
    }

    // MARK: - SearchServices adapter

    @Test func daemonSearchServicesBindsWikiAndDelegatesBothOperations() async throws {
        let recorder = RequestRecorder()
        let transport = ControlledTransport(behavior: .hold)
        let client = DaemonSearchClient(
            transport: recordingTransport(recorder, transport),
            timeout: Self.testTimeout)

        let services = DaemonSearchServices(wikiID: Self.wikiID, client: client)
        transport.setBehavior(.replyImmediately(Self.successReplyData([Self.hit(ulid: "01GGGG", score: 1)])))
        let results = try await services.search(query: "ownership", kinds: [.page], limit: 4)
        #expect(results.map(\.ulid) == ["01GGGG"])

        transport.setBehavior(.replyImmediately(Self.successReplyData([])))
        let suggestions = try await services.autocomplete(
            partial: "own", kinds: [.page, .chat], distance: 1, limit: 6)
        #expect(suggestions.isEmpty)

        let sent = recorder.snapshot()
        #expect(sent.count == 2)
        #expect(sent[0].wikiID == Self.wikiID.rawValue)
        #expect(sent[0].operation == .search(query: "ownership", kinds: ["page"], limit: 4))
        // UInt8 distance crosses the seam as the wire's Int.
        #expect(sent[1].operation == .autocomplete(
            partial: "own", kinds: ["chat", "page"], distance: 1, limit: 6))
    }
}
#endif
