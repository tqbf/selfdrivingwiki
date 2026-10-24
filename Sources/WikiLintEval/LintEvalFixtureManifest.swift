import Foundation
import WikiFSTypes

/// A half-open UTF-8 byte range, Codable for manifests (`{"lowerBound":N,"upperBound":M}`).
public struct LintEvalByteRange: Codable, Equatable, Sendable {
    public let lowerBound: Int
    public let upperBound: Int

    public init(lowerBound: Int, upperBound: Int) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    public var range: Range<Int> { lowerBound..<upperBound }
}

/// One versioned evaluation fixture (plan §6.5): the seeded defects, the
/// repairs the harness may accept, the bytes a repair must never touch, the
/// unresolved findings a correct run may leave, and the edits that are
/// forbidden outright. Frozen by digest before tuning; the held-out split
/// never feeds prompt tuning.
public struct LintEvalFixture: Codable, Equatable, Sendable {

    public struct SeededDefect: Codable, Equatable, Sendable {
        /// The defect class the fixture seeds.
        public let defectClass: String
        /// The exact seeded text (the evidence a correct detection quotes).
        public let evidence: String
        /// Whether the seeded defect is REPAIRABLE in the fixture's
        /// expectation, or report-only (a correct run leaves it unresolved).
        public let expectRepair: Bool

        public init(defectClass: String, evidence: String, expectRepair: Bool) {
            self.defectClass = defectClass
            self.evidence = evidence
            self.expectRepair = expectRepair
        }
    }

    public struct AllowedRepair: Codable, Equatable, Sendable {
        public let defectClass: String
        /// The exact original text the repair may replace…
        public let oldText: String
        /// …with this exact replacement (mechanical fixtures only —
        /// judgment fixtures declare `nil` and require recorded human
        /// semantic review instead of oracle acceptance).
        public let newText: String?

        public init(defectClass: String, oldText: String, newText: String?) {
            self.defectClass = defectClass
            self.oldText = oldText
            self.newText = newText
        }
    }

    /// Stable fixture identity inside its manifest.
    public let id: String
    /// The seeded page body (exact bytes — the harness seeds this verbatim).
    public let body: String
    public let seededDefects: [SeededDefect]
    /// The only repairs the diff oracle accepts (mechanical fixtures).
    public let allowedRepairs: [AllowedRepair]
    /// Byte ranges (UTF-8, half-open, original coordinates) no hunk may
    /// touch — evidence quotes, citations the run must preserve.
    public let protectedByteRanges: [LintEvalByteRange]
    /// Finding ids/classes a correct run may leave unresolved without
    /// losing the fixture (e.g. report-only classes).
    public let permittedUnresolvedClasses: [String]
    /// "mechanical" (diff oracle decides) or "judgment" (human rubric
    /// decides — the oracle only rejects known-bad edits).
    public let kind: String

    public init(
        id: String, body: String, seededDefects: [SeededDefect],
        allowedRepairs: [AllowedRepair], protectedByteRanges: [LintEvalByteRange],
        permittedUnresolvedClasses: [String], kind: String
    ) {
        self.id = id
        self.body = body
        self.seededDefects = seededDefects
        self.allowedRepairs = allowedRepairs
        self.protectedByteRanges = protectedByteRanges
        self.permittedUnresolvedClasses = permittedUnresolvedClasses
        self.kind = kind
    }
}

/// The versioned manifest: tuning groups, the held-out group, and the
/// canonical digest the shipped gate resource freezes (plan §6.5/§6.13).
public struct LintEvalFixtureManifest: Codable, Equatable, Sendable {
    public static let version = 1

    public let manifestVersion: Int
    public let tuning: [LintEvalFixture]
    /// Held-out fixtures: scored by every gate run, never shown to tuning.
    public let heldOut: [LintEvalFixture]

    public init(tuning: [LintEvalFixture], heldOut: [LintEvalFixture]) {
        self.manifestVersion = Self.version
        self.tuning = tuning
        self.heldOut = heldOut
    }

    /// The canonical JSON digest of the whole manifest — the value the
    /// shipped `LintGateFixtureManifest.json` freezes and the acceptance key
    /// carries. Deterministic: sorted keys, no whitespace choices.
    public func digest() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        return RendererSHA256.digest(data).hex
    }

    /// Decode the manifest from its JSON representation.
    public static func load(from data: Data) throws -> LintEvalFixtureManifest {
        try JSONDecoder().decode(LintEvalFixtureManifest.self, from: data)
    }
}
