// pattern: Functional Core

import Foundation

/// A deterministic partition of repository files for the read-only ACP
/// `repo-reader` fan-out. The final curator receives every resulting digest and
/// is the only agent that can write through `wikictl`.
public struct RepoReaderWorkPlan: Equatable, Sendable {
    public static let minimumReaderCount = 2
    public static let maximumReaderCount = 19

    public struct Assignment: Equatable, Sendable, Identifiable {
        public let ordinal: Int
        public let paths: [String]

        public var id: Int { ordinal }

        public init(ordinal: Int, paths: [String]) {
            self.ordinal = ordinal
            self.paths = paths
        }
    }

    public let assignments: [Assignment]

    public init(assignments: [Assignment]) {
        self.assignments = assignments
    }

    /// Whether this plan can safely start reader agents. Empty assignments are
    /// rejected because an empty prompt allowlist would let a reader inspect an
    /// unbounded checkout instead of its assigned slice.
    public var isEligibleForReaderFanout: Bool {
        assignments.count >= Self.minimumReaderCount
            && assignments.count <= Self.maximumReaderCount
            && assignments.allSatisfy { !$0.paths.isEmpty }
    }

    /// Make 2...19 balanced reader assignments when at least two paths are
    /// available. A single allowed path bypasses fan-out so the curator handles
    /// it directly; this prevents an empty reader allowlist. The input order is
    /// normalized before partitioning, so the same repository revision always
    /// produces the same reader prompts and digest order.
    public static func make(paths: [String]) -> RepoReaderWorkPlan {
        let uniquePaths = Array(Set(paths.filter { !$0.isEmpty })).sorted()
        guard uniquePaths.count >= minimumReaderCount else {
            return RepoReaderWorkPlan(assignments: [])
        }

        let readerCount = min(
            maximumReaderCount,
            max(minimumReaderCount, uniquePaths.count))
        var buckets = Array(repeating: [String](), count: readerCount)
        for (index, path) in uniquePaths.enumerated() {
            buckets[index % readerCount].append(path)
        }
        return RepoReaderWorkPlan(assignments: buckets.enumerated().map { index, paths in
            Assignment(ordinal: index + 1, paths: paths)
        })
    }
}
