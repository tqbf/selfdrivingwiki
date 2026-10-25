import Foundation

/// The SHIPPED rollout approval (plan §6.13/§6.14): a versioned bundle
/// resource that names the pipeline it was approved against and the exact
/// provider/model/effort rows that earn generalized repairs. Approvals are
/// public by design — safety comes from enforcement (exact patch, CAS,
/// coverage, verification), not from a secret per-machine record. The eval
/// harness mints a candidate with `WikiLintEvalRunner manifest`; the
/// operator reviews and commits it. Production needs no dependency on the
/// eval target, the App Group, or files under tmp/.
public struct LintAcceptanceManifest: Codable, Equatable, Sendable {

    /// The only schema this build understands. Anything else is invalid.
    public static let schema = 3

    /// The authority values a row may carry.
    public static let knownAuthorities: Set<String> = ["full"]

    /// The pipeline the approval was evaluated against. ONLY fields with a
    /// real runtime source: a change to any of them invalidates the
    /// shipped approval.
    public struct Pipeline: Codable, Equatable, Sendable {
        public let promptSHA256: String
        public let detectorRevision: String
        public let fixtureDigest: String

        public init(promptSHA256: String, detectorRevision: String, fixtureDigest: String) {
            self.promptSHA256 = promptSHA256
            self.detectorRevision = detectorRevision
            self.fixtureDigest = fixtureDigest
        }

        /// The pipeline the gate components were computed against.
        public init(_ components: LintAcceptanceKey.Components) {
            self.init(
                promptSHA256: components.promptSHA256,
                detectorRevision: components.detectorRevision,
                fixtureDigest: components.fixtureDigest)
        }

        /// The pipeline of THIS build: the lint-page-task template bytes
        /// hash, the detector revision, and the shipped canonical gate
        /// fixture digest.
        public static func live() throws -> Pipeline {
            guard let fixtureDigest = try LintGateFixtureManifestShipped.load()
                .digest(named: "canonical-gate") else {
                throw LintAcceptanceManifestError.missingShippedFixtureDigest
            }
            return Pipeline(
                promptSHA256: LintPromptBodies.lintPageTaskSHA256,
                detectorRevision: LintPreflightReport.detectorRevision,
                fixtureDigest: fixtureDigest)
        }
    }

    /// Provenance for the approvals — never matched at runtime.
    public struct Evidence: Codable, Equatable, Sendable {
        public let reportSHA256: String
        public let rubricReviewer: String
        public let decidedAt: Date
        public let bailTrials: String

        public init(reportSHA256: String, rubricReviewer: String, decidedAt: Date, bailTrials: String) {
            self.reportSHA256 = reportSHA256
            self.rubricReviewer = rubricReviewer
            self.decidedAt = decidedAt
            self.bailTrials = bailTrials
        }
    }

    /// One approved configuration. `evaluatedRevision` is the provider's
    /// advertised model revision at evaluation time, when it had one;
    /// `acceptanceKeySHA256` is the full key digest, for traceability only.
    public struct Approval: Codable, Equatable, Sendable {
        public let id: String
        public let provider: String
        public let model: String
        public let effort: String
        public let evaluatedRevision: String?
        public let acceptanceKeySHA256: String?
        public let authority: String

        public init(
            id: String, provider: String, model: String, effort: String,
            evaluatedRevision: String?, acceptanceKeySHA256: String?,
            authority: String = "full"
        ) {
            self.id = id
            self.provider = provider
            self.model = model
            self.effort = effort
            self.evaluatedRevision = evaluatedRevision
            self.acceptanceKeySHA256 = acceptanceKeySHA256
            self.authority = authority
        }

        enum CodingKeys: String, CodingKey {
            case id, provider, model, effort, evaluatedRevision, acceptanceKeySHA256, authority
        }

        // Explicit nulls, so an emitted candidate shows every field.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(provider, forKey: .provider)
            try container.encode(model, forKey: .model)
            try container.encode(effort, forKey: .effort)
            try container.encode(evaluatedRevision, forKey: .evaluatedRevision)
            try container.encode(acceptanceKeySHA256, forKey: .acceptanceKeySHA256)
            try container.encode(authority, forKey: .authority)
        }
    }

    public let manifestSchema: Int
    public let pipeline: Pipeline
    public let evidence: Evidence?
    public let approvals: [Approval]

    /// "Enabled" under the W5a ladder is simply whether approval rows exist
    /// — unevaluated configurations run as staged proposals, so there is no
    /// separate kill switch (schema 3 removed `defaultReportOnly`).
    public init(
        manifestSchema: Int = LintAcceptanceManifest.schema, pipeline: Pipeline,
        evidence: Evidence?, approvals: [Approval]
    ) {
        self.manifestSchema = manifestSchema
        self.pipeline = pipeline
        self.evidence = evidence
        self.approvals = approvals
    }

    enum CodingKeys: String, CodingKey {
        case manifestSchema, pipeline, evidence, approvals
    }

    // Explicit `"evidence": null`, so an emitted candidate matches the schema.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(manifestSchema, forKey: .manifestSchema)
        try container.encode(pipeline, forKey: .pipeline)
        try container.encode(evidence, forKey: .evidence)
        try container.encode(approvals, forKey: .approvals)
    }

    /// The first structural problem, or nil when the manifest is valid. An
    /// invalid manifest selects report-only at gate time — never a crash.
    public var structuralProblem: String? {
        guard manifestSchema == Self.schema else {
            return "unknown manifest schema \(manifestSchema)"
        }
        if approvals.isEmpty == false && evidence == nil {
            return "approvals without evidence"
        }
        if approvals.isEmpty && evidence != nil {
            return "evidence without approvals"
        }
        if let row = approvals.first(where: { Self.knownAuthorities.contains($0.authority) == false }) {
            return "approval \(row.id) has unknown authority \(row.authority)"
        }
        return nil
    }

    /// Decode a manifest from JSON bytes (ISO-8601 dates). Decoding does NOT
    /// validate structure — read `structuralProblem` for that.
    public static func decode(_ data: Data) throws -> LintAcceptanceManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LintAcceptanceManifest.self, from: data)
    }

    /// Encode as the reviewable, committed form (pretty, sorted keys).
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// The shipped resource bytes from the WikiFSCore bundle.
    public static func shippedData() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "manifest", withExtension: "json",
            subdirectory: "LintAcceptance") else {
            throw LintAcceptanceManifestError.missingResource
        }
        return try Data(contentsOf: url)
    }

    /// Load the shipped manifest from the WikiFSCore bundle.
    public static func load() throws -> LintAcceptanceManifest {
        try decode(try shippedData())
    }
}

public enum LintAcceptanceManifestError: Error, Equatable, Sendable {
    case missingResource
    case missingShippedFixtureDigest
}
