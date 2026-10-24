import Foundation
import WikiFSTypes

/// The rollout gate (plan §6.13/§6.14): a configuration earns generalized
/// repairs only with a complete, fresh, human-approved acceptance record
/// whose key matches EXACTLY. Everything else selects report-only — never a
/// downgrade of the safety posture, and never a CLI-writable mutation.
public struct LintAcceptanceKey: Equatable, Sendable, Hashable {

    /// Every component that changes the key: provider, model, the provider's
    /// advertised revision fingerprint when available, the effective effort
    /// tier, the prompt bytes hash, the detector revision, and the shipped
    /// gate-fixture digests (plan §6.12 — a changed component invalidates
    /// all prior evidence).
    public struct Components: Equatable, Sendable {
        public let provider: String
        public let model: String
        public let modelRevision: String?
        public let effort: String
        public let promptSHA256: String
        public let detectorRevision: String
        public let fixtureDigest: String

        public init(
            provider: String, model: String, modelRevision: String?,
            effort: String, promptSHA256: String, detectorRevision: String,
            fixtureDigest: String
        ) {
            self.provider = provider
            self.model = model
            self.modelRevision = modelRevision
            self.effort = effort
            self.promptSHA256 = promptSHA256
            self.detectorRevision = detectorRevision
            self.fixtureDigest = fixtureDigest
        }

        /// The stable canonical string the digest hashes (sorted labels).
        public var canonical: String {
            let parts: [(String, String)] = [
                ("provider", provider),
                ("model", model),
                ("revision", modelRevision ?? "unavailable"),
                ("effort", effort),
                ("prompt", promptSHA256),
                ("detector", detectorRevision),
                ("fixtures", fixtureDigest),
            ]
            return parts.sorted { $0.0 < $1.0 }
                .map { "\($0.0)=\($0.1)" }
                .joined(separator: "\n")
        }
    }

    /// The SHA-256 hex of the canonical components — the record's filename
    /// stem and the gate's match key.
    public static func digest(_ components: Components) -> String {
        RendererSHA256.digest(Data(components.canonical.utf8)).hex
    }
}

/// One accepted-rollout record. Versioned JSON, written ATOMICALLY by the
/// trusted host ONLY after complete scoring and required human rubric
/// approval. The hash identifies evidence; it is not an authorization
/// signature by itself — the rubric metadata is required.
public struct LintAcceptanceRecord: Codable, Equatable, Sendable {
    public static let version = 1

    public let recordVersion: Int
    public let key: String
    /// The manifest digest this record's evidence was produced against.
    public let artifactManifestDigest: String
    public let verdict: String // "accepted"
    /// The human rubric: who reviewed, when, and the fixture ids covered.
    public let rubricReviewer: String
    public let rubricDecidedAt: Date
    public let rubricFixtureIDs: [String]
    public let recordedAt: Date

    public init(
        key: String, artifactManifestDigest: String,
        rubricReviewer: String, rubricDecidedAt: Date,
        rubricFixtureIDs: [String], recordedAt: Date
    ) {
        self.recordVersion = Self.version
        self.key = key
        self.artifactManifestDigest = artifactManifestDigest
        self.verdict = "accepted"
        self.rubricReviewer = rubricReviewer
        self.rubricDecidedAt = rubricDecidedAt
        self.rubricFixtureIDs = rubricFixtureIDs
        self.recordedAt = recordedAt
    }

    /// Structural validation: complete, version-matched, human-approved.
    public var isValid: Bool {
        recordVersion == Self.version
            && key.count == 64
            && verdict == "accepted"
            && artifactManifestDigest.count == 64
            && rubricReviewer.trimmingCharacters(in: .whitespaces).isEmpty == false
            && rubricFixtureIDs.isEmpty == false
    }
}

/// What the trusted coordinator selects for a configuration.
public enum LintRolloutSelection: Equatable, Sendable {
    /// A valid, matching, fresh record exists — the repair-capable lease.
    case repairAuthorized
    /// No valid record: report-only instructions and authority, with the
    /// reason recorded in artifacts and queue/UI state.
    case reportOnly(reason: String)
}

/// The gate itself: records live in `<gate directory>/<key>.json`. The
/// directory defaults to the App Group's `lint-acceptance/`; tests inject a
/// temp directory. There is NO CLI mutation path — the trusted host writes.
public struct LintAcceptanceGate: Sendable {

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The production gate directory: the resolved App Group container's
    /// `lint-acceptance/` folder (created on demand by the writer).
    public static func production() throws -> LintAcceptanceGate {
        let container = try DatabaseLocation.appGroupContainerDirectory()
        return LintAcceptanceGate(
            directory: container.appendingPathComponent("lint-acceptance", isDirectory: true))
    }

    func recordURL(key: String) -> URL {
        directory.appendingPathComponent("\(key).json", isDirectory: false)
    }

    /// Load and validate the record for a key. Returns nil when no record
    /// exists; THROWS when one exists but is malformed (a malformed record
    /// is a finding, not silence). Records are written with ISO-8601 dates.
    public func record(for key: String) throws -> LintAcceptanceRecord? {
        let url = recordURL(key: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LintAcceptanceGateError.unreadable(
                key: key, underlying: String(describing: error))
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let record = try decoder.decode(LintAcceptanceRecord.self, from: data)
            guard record.isValid else {
                throw LintAcceptanceGateError.malformedRecord(key: key)
            }
            guard record.key == key else {
                throw LintAcceptanceGateError.keyMismatch(key: key)
            }
            return record
        } catch let error as LintAcceptanceGateError {
            throw error
        } catch {
            throw LintAcceptanceGateError.malformedRecord(key: key)
        }
    }

    /// The rollout selection for one configuration.
    public func selection(for components: LintAcceptanceKey.Components) throws
        -> LintRolloutSelection {
        let key = LintAcceptanceKey.digest(components)
        guard let record = try record(for: key) else {
            return .reportOnly(
                reason: "no acceptance record for this configuration — generalized repairs stay disabled until a fresh gate passes")
        }
        guard record.artifactManifestDigest == components.fixtureDigest else {
            return .reportOnly(
                reason: "acceptance record's fixture digest does not match the shipped gate fixtures")
        }
        return .repairAuthorized
    }

    /// HOST-ONLY write: persist an accepted record atomically. The evaluation
    /// runner and the agent CLI never call this.
    public func write(record: LintAcceptanceRecord) throws {
        guard record.isValid else {
            throw LintAcceptanceGateError.malformedRecord(key: record.key)
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        try data.write(to: recordURL(key: record.key), options: .atomic)
    }

    /// The evaluation admission (plan §6.13): a harness-only restricted
    /// admission for the disposable wiki ids the harness JUST created, for
    /// the exact evaluated configuration. It can never authorize an operator
    /// wiki and never writes acceptance records.
    public static func evaluationAdmission(
        admittedWikiIDs: Set<WikiID>, requestedWikiID: WikiID
    ) -> Bool {
        admittedWikiIDs.contains(requestedWikiID)
    }
}

public enum LintAcceptanceGateError: Error, Equatable, Sendable {
    case unreadable(key: String, underlying: String)
    case malformedRecord(key: String)
    case keyMismatch(key: String)
}
