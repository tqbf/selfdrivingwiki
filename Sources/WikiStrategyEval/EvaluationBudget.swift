import Foundation

/// The bounds of one evaluation run. The live runner applies these through
/// ``BoundedRunner/withBudget(_:body:)`` — structured cancellation, never a
/// cooperative-thread block.
public struct EvaluationBudget: Sendable, Equatable, Codable {
    /// Whole-scenario wall-clock bound (all ingests of one scenario share it).
    public var maxDuration: Duration
    /// Cumulative token bound across all of a scenario's runs, when reported.
    public var maxTotalTokens: Int?
    /// Cumulative cost bound in the provider's currency (USD), when reported.
    public var maxCost: Double?

    public init(
        maxDuration: Duration = .seconds(1200),
        maxTotalTokens: Int? = 4_000_000,
        maxCost: Double? = 5.0
    ) {
        self.maxDuration = maxDuration
        self.maxTotalTokens = maxTotalTokens
        self.maxCost = maxCost
    }
}

/// One usage snapshot mapped from the backend's live usage reports. Carries no
/// secrets.
public struct UsageSnapshot: Sendable, Equatable, Codable {
    public var totalTokens: Int
    public var cost: Double?

    public init(totalTokens: Int, cost: Double? = nil) {
        self.totalTokens = totalTokens
        self.cost = cost
    }
}

/// Why a bounded run stopped before its body finished.
public enum EvaluationRunLimit: Error, Equatable, Sendable {
    case timedOut(limitSeconds: Double)
    case tokenBudgetExceeded(limit: Int, observed: Int)
    case costBudgetExceeded(limit: Double, observed: Double)

    public var localizedDescription: String {
        switch self {
        case .timedOut(let seconds):
            "evaluation exceeded its \(Int(seconds))s time budget and was cancelled"
        case .tokenBudgetExceeded(let limit, let observed):
            "evaluation exceeded its token budget (\(observed) > \(limit))"
        case .costBudgetExceeded(let limit, let observed):
            "evaluation exceeded its cost budget (\(observed) > \(limit))"
        }
    }
}

/// Tracks cumulative usage against a budget from `usage_update` callbacks.
/// An actor: callbacks fire from backend streams while the run body awaits.
public actor UsageBudgetTracker {
    private let budget: EvaluationBudget
    private var cumulative = UsageSnapshot(totalTokens: 0)
    private var hasCompletedRun = false

    public init(budget: EvaluationBudget) {
        self.budget = budget
    }

    /// Record one cumulative snapshot (backends report session-cumulative
    /// totals, not deltas). Throws when a budget is exceeded so the run body
    /// stops before starting further work.
    public func observe(_ snapshot: UsageSnapshot) throws {
        cumulative = snapshot
        if let maxTokens = budget.maxTotalTokens, snapshot.totalTokens > maxTokens {
            throw EvaluationRunLimit.tokenBudgetExceeded(limit: maxTokens, observed: snapshot.totalTokens)
        }
        if let maxCost = budget.maxCost, let cost = snapshot.cost, cost > maxCost {
            throw EvaluationRunLimit.costBudgetExceeded(limit: maxCost, observed: cost)
        }
    }

    /// Record the completed usage from one independently constructed run.
    /// Unlike ``observe(_:)``, this adds the run to the aggregate. Cost stays
    /// unknown once any completed run does not report one, so an unknown cost
    /// is never undercounted as zero.
    public func recordCompletedRun(_ snapshot: UsageSnapshot) throws {
        let (tokens, overflowed) = cumulative.totalTokens.addingReportingOverflow(snapshot.totalTokens)
        let aggregateTokens = overflowed
            ? (snapshot.totalTokens >= 0 ? Int.max : Int.min)
            : tokens
        let aggregateCost: Double? = {
            guard hasCompletedRun else { return snapshot.cost }
            guard let existing = cumulative.cost, let cost = snapshot.cost else { return nil }
            return existing + cost
        }()
        hasCompletedRun = true
        cumulative = UsageSnapshot(totalTokens: aggregateTokens, cost: aggregateCost)

        if let maxTokens = budget.maxTotalTokens, aggregateTokens > maxTokens {
            throw EvaluationRunLimit.tokenBudgetExceeded(limit: maxTokens, observed: aggregateTokens)
        }
        if let maxCost = budget.maxCost, let cost = aggregateCost, cost > maxCost {
            throw EvaluationRunLimit.costBudgetExceeded(limit: maxCost, observed: cost)
        }
    }

    public func current() -> UsageSnapshot {
        cumulative
    }
}

/// Structured, cancellation-first execution under a time budget.
///
/// The body runs alongside one timeout task in a throwing task group. When
/// the timeout elapses first, the timer task runs `onTimeout` (force-stop the
/// agent subprocess — a body that ignores cooperative cancellation must not
/// leave the task group's drain waiting), then throws; the group cancels
/// every child. The body completing first cancels the timer. No thread is
/// ever parked, and the duration must be positive (asserted; the CLI validates
/// its flags too).
public enum BoundedRunner {
    public static func withBudget<T: Sendable>(
        _ budget: EvaluationBudget,
        onTimeout: (@Sendable () async -> Void)? = nil,
        body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        precondition(
            budget.maxDuration > .zero,
            "evaluation budget duration must be positive")
        let limitSeconds = Double(budget.maxDuration.components.seconds)
            + Double(budget.maxDuration.components.attoseconds) / 1e18
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await body()
            }
            group.addTask {
                try await Task.sleep(for: budget.maxDuration)
                // Timer fired while the body is still running: stop the
                // underlying work hard BEFORE the thrown error unwinds the
                // group, so the implicit drain cannot park on a body that
                // ignores cancellation.
                await onTimeout?()
                throw EvaluationRunLimit.timedOut(limitSeconds: limitSeconds)
            }
            guard let first = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return first
        }
    }
}
