import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSCore

/// Per-session scripted behavior for `FakeAgentBackend`. Each `start()` call
/// pops the next behavior in sequence.
struct FakeSessionBehavior: Sendable {
    /// Events to yield in `send()` (ended implicitly by finishing the stream).
    /// Defaults to just `.messageStop` (the turn-boundary marker).
    var events: [AgentEvent] = [.messageStop]
    /// If true, `start()` throws `FakeBackendError.startFailed`.
    var shouldFailOnStart: Bool = false
    /// If set, write this JSON to `plan.json` in the scratch directory on
    /// `start()`, simulating the planner phase's output.
    var planJSON: Data? = nil

    init(
        events: [AgentEvent] = [.messageStop],
        shouldFailOnStart: Bool = false,
        planJSON: Data? = nil
    ) {
        self.events = events
        self.shouldFailOnStart = shouldFailOnStart
        self.planJSON = planJSON
    }
}

enum FakeBackendError: Error {
    case startFailed
}

/// Test double conforming to `AgentBackend`. Records all `start`/`send`/`cancel`
/// calls, yields scripted `AgentEvent` sequences per session, and can write a
/// canned `plan.json` to simulate the planner phase.
///
/// Usage: construct with a list of `FakeSessionBehavior` (one per expected
/// `start()` call), inject into `AgentLauncher.backend`, drive the launcher,
/// then assert on the recorded calls.
actor FakeAgentBackend: AgentBackend {

    // MARK: - Records (for assertion)

    private(set) var startCount = 0
    private(set) var sendCount = 0
    private(set) var cancelCount = 0
    /// Session IDs in start order.
    private(set) var startedSessionIDs: [String] = []
    /// Sent prompt texts in send order.
    private(set) var sentTexts: [String] = []
    /// Cancelled session IDs in cancel order.
    private(set) var cancelledSessionIDs: [String] = []
    /// All events yielded across all sessions (flattened, in order).
    private(set) var allYieldedEvents: [AgentEvent] = []
    /// Model hints seen in start profiles (the `acpSelectedModelId` provider hint).
    private(set) var startModelHints: [String?] = []

    // MARK: - Scripted behavior

    private var behaviors: [FakeSessionBehavior]
    private var behaviorIndex = 0
    private var sessionCounter = 0
    private var sessionBehaviors: [String: FakeSessionBehavior] = [:]

    init(behaviors: [FakeSessionBehavior] = []) {
        self.behaviors = behaviors
    }

    // MARK: - AgentBackend conformance

    func start(
        profile: BackendProfile,
        systemPrompt: String,
        onExit: @escaping @Sendable (Int) -> Void
    ) async throws -> SessionHandle {
        startCount += 1

        let behavior = behaviorIndex < behaviors.count
            ? behaviors[behaviorIndex]
            : FakeSessionBehavior()
        behaviorIndex += 1

        startModelHints.append(profile.providerHints["acpSelectedModelId"])

        if behavior.shouldFailOnStart {
            throw FakeBackendError.startFailed
        }

        sessionCounter += 1
        let sessionId = "fake-\(sessionCounter)"
        startedSessionIDs.append(sessionId)
        sessionBehaviors[sessionId] = behavior

        // Write plan.json if configured (simulates the planner writing the plan).
        if let planData = behavior.planJSON, let scratch = profile.scratchDirectory {
            let planURL = scratch.appendingPathComponent("plan.json")
            try? planData.write(to: planURL)
        }

        return SessionHandle(id: sessionId)
    }

    func send(_ turn: TurnInput, into session: SessionHandle) async -> AsyncStream<AgentEvent> {
        sendCount += 1
        sentTexts.append(turn.userText)

        let events = sessionBehaviors[session.id]?.events ?? [.messageStop]
        allYieldedEvents.append(contentsOf: events)

        return AsyncStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func resume(sessionID: String, profile: BackendProfile) async throws -> SessionHandle? {
        return nil
    }

    func cancel(_ session: SessionHandle) async {
        cancelCount += 1
        cancelledSessionIDs.append(session.id)
    }
}
