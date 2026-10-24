import Foundation
import WikiFSTypes

/// Per-class scoring for one fixture run (plan §6.8): recall and precision
/// against the fixture's seeded defects, with the report-only rule — a
/// seeded report-only defect satisfies recall through an accurate
/// unresolved/report outcome, NEVER a forbidden repair; a repairable bail
/// fixture left unresolved is a failure.
public enum LintEvalScoring {

    /// One run's reported outcome for a fixture, as the coordinator gathered
    /// it (all values are host-observed, never agent claims).
    public struct ObservedRun: Sendable, Equatable {
        /// The final report's confirmed findings (class rawValues).
        public let confirmedClasses: Set<String>
        /// Classes the report left unresolved (accurate report outcome).
        public let unresolvedClasses: Set<String>
        /// Classes the report marked valid-as-written (with reasons).
        public let validAsWrittenClasses: Set<String>
        /// Classes the report claims it repaired.
        public let repairedClasses: Set<String>
        /// The run never completed its coverage/accounting (audit failure).
        public let coverageFailed: Bool

        public init(
            confirmedClasses: Set<String>, unresolvedClasses: Set<String>,
            validAsWrittenClasses: Set<String>, repairedClasses: Set<String>,
            coverageFailed: Bool
        ) {
            self.confirmedClasses = confirmedClasses
            self.unresolvedClasses = unresolvedClasses
            self.validAsWrittenClasses = validAsWrittenClasses
            self.repairedClasses = repairedClasses
            self.coverageFailed = coverageFailed
        }
    }

    public struct FixtureScore: Equatable, Sendable {
        public let fixtureID: String
        /// Seeded defects the run correctly accounted for (detected+repaired,
        /// or report-only+accurately unresolved).
        public let hits: Set<String>
        /// Seeded defects missed entirely.
        public let misses: Set<String>
        /// Confirmed findings that map to NO seeded defect (false positives).
        public let falseConfirmed: Set<String>
        /// True only when the run may count this fixture as passed.
        public let passed: Bool
        /// Why it failed (empty when passed).
        public let failureReasons: [String]
    }

    /// Score one fixture run. Each SEEDED DEFECT is a separate scoring unit
    /// (review M9a/b): two defects of the same class score independently, a
    /// false-confirmed finding of a seeded class is still visible, and the
    /// class-granular aggregate below is derived from these per-defect
    /// results.
    public static func score(
        fixture: LintEvalFixture, run: ObservedRun
    ) -> FixtureScore {
        var failureReasons: [String] = []

        var hits: Set<String> = []
        var misses: Set<String> = []
        for (index, seed) in fixture.seededDefects.enumerated() {
            let unit = "\(seed.defectClass)#\(index + 1)"
            let repaired = run.repairedClasses.contains(seed.defectClass)
            let confirmed = run.confirmedClasses.contains(seed.defectClass)
            let unresolved = run.unresolvedClasses.contains(seed.defectClass)
            if repaired && seed.expectRepair {
                hits.insert(unit)
            } else if repaired {
                failureReasons.append("\(unit): report-only defect must not be repaired")
                hits.insert(unit)
            } else if unresolved {
                if seed.expectRepair {
                    failureReasons.append("\(unit): repairable defect left unresolved")
                } else {
                    hits.insert(unit)
                }
            } else if confirmed {
                failureReasons.append("\(unit): confirmed but never accounted")
                misses.insert(unit)
            } else {
                misses.insert(unit)
            }
        }
        for miss in misses.sorted() {
            failureReasons.append("\(miss): seeded defect missed entirely")
        }

        // False confirmed: findings confirmed that map to no seeded class.
        let seededClasses = Set(fixture.seededDefects.map(\.defectClass))
        let falseConfirmed = run.confirmedClasses.subtracting(seededClasses)
        if falseConfirmed.isEmpty == false {
            failureReasons.append(
                "false confirmed defects: \(falseConfirmed.sorted().joined(separator: ","))")
        }

        if run.coverageFailed {
            failureReasons.append("run coverage/accounting failed")
        }

        return FixtureScore(
            fixtureID: fixture.id,
            hits: hits,
            misses: misses,
            falseConfirmed: falseConfirmed,
            passed: failureReasons.isEmpty && misses.isEmpty,
            failureReasons: failureReasons.sorted())
    }

    /// Aggregate per-class recall/precision across fixture runs (plan §6.8).
    public struct ClassScore: Equatable, Sendable {
        public let defectClass: String
        public let seededRuns: Int
        public let hits: Int
        /// Confirmed findings of this class that mapped to no seed.
        public let falseConfirmedRuns: Int

        public var recall: Double {
            seededRuns == 0 ? 0 : Double(hits) / Double(seededRuns)
        }
    }

    public static func aggregate(
        _ scored: [(fixture: LintEvalFixture, score: FixtureScore)]
    ) -> [ClassScore] {
        var byClass: [String: (seeded: Int, hits: Int, falseConfirmed: Int)] = [:]
        for (fixture, score) in scored {
            // Hits are per-defect units ("D03#1", "D03#2"); the class key is
            // the part before the unit ordinal.
            for hit in score.hits {
                let cls = hit.split(separator: "#").first.map(String.init) ?? hit
                var entry = byClass[cls] ?? (0, 0, 0)
                entry.hits += 1
                byClass[cls] = entry
            }
            for seed in fixture.seededDefects {
                var entry = byClass[seed.defectClass] ?? (0, 0, 0)
                entry.seeded += 1
                byClass[seed.defectClass] = entry
            }
            for falseClass in score.falseConfirmed {
                var entry = byClass[falseClass] ?? (0, 0, 0)
                entry.falseConfirmed += 1
                byClass[falseClass] = entry
            }
        }
        return byClass
            .map { defectClass, counts in
                ClassScore(
                    defectClass: defectClass,
                    seededRuns: counts.seeded,
                    hits: counts.hits,
                    falseConfirmedRuns: counts.falseConfirmed)
            }
            .sorted { $0.defectClass < $1.defectClass }
    }
}
