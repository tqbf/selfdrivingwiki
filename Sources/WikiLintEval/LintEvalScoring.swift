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

    /// Score one fixture run.
    public static func score(
        fixture: LintEvalFixture, run: ObservedRun
    ) -> FixtureScore {
        var failureReasons: [String] = []
        let seeded = Dictionary(
            uniqueKeysWithValues: fixture.seededDefects.map { ($0.defectClass, $0) })

        var hits: Set<String> = []
        var misses: Set<String> = []
        for (classRaw, seed) in seeded {
            let repaired = run.repairedClasses.contains(classRaw)
            let confirmed = run.confirmedClasses.contains(classRaw)
            let unresolved = run.unresolvedClasses.contains(classRaw)
            if repaired && seed.expectRepair {
                hits.insert(classRaw)
            } else if repaired && seed.expectRepair == false {
                // A forbidden repair of a report-only seeded defect.
                failureReasons.append("\(classRaw): report-only defect must not be repaired")
                hits.insert(classRaw) // it was seen…
            } else if unresolved {
                if seed.expectRepair {
                    // A repairable bail fixture left unresolved is a failure.
                    failureReasons.append("\(classRaw): repairable defect left unresolved")
                } else if fixture.permittedUnresolvedClasses.contains(classRaw)
                    || seed.expectRepair == false {
                    hits.insert(classRaw) // accurate report outcome for a report-only class
                } else {
                    failureReasons.append("\(classRaw): unresolved without permission")
                }
            } else if confirmed {
                // Seen but neither repaired nor unresolved — an incomplete audit.
                failureReasons.append("\(classRaw): confirmed but never accounted")
                misses.insert(classRaw)
            } else {
                misses.insert(classRaw)
            }
        }
        for miss in misses {
            failureReasons.append("\(miss): seeded defect missed entirely")
        }

        // False confirmed: findings confirmed that map to no seeded defect.
        let falseConfirmed = run.confirmedClasses.subtracting(seeded.keys)
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
            for seed in fixture.seededDefects {
                var entry = byClass[seed.defectClass] ?? (0, 0, 0)
                entry.seeded += 1
                if score.hits.contains(seed.defectClass) { entry.hits += 1 }
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
