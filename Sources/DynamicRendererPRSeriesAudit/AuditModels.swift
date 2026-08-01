import Foundation

// pattern: Functional Core

public enum DynamicRendererAuditError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedSchemaVersion(Int)
    case invalidSHA(String)
    case mismatchedHead
    case dirtyCheckout
    case invalidInventoryPath(String)
    case invalidCommandExitCode(Int)
    case invalidCheckRun
    case invalidReview
    case invalidCommandEvidence
    case invalidMutationReport
    case invalidRecordedAt(String)

    public var description: String {
        switch self {
        case let .unsupportedSchemaVersion(version): "unsupported gate record schema version: \(version)"
        case let .invalidSHA(sha): "invalid git SHA: \(sha)"
        case .mismatchedHead: "audited SHA and head reference OID differ"
        case .dirtyCheckout: "audit requires a clean checkout"
        case let .invalidInventoryPath(path): "invalid test inventory path: \(path)"
        case let .invalidCommandExitCode(code): "invalid command exit code: \(code)"
        case .invalidCheckRun: "required check run is missing, mismatched, or incomplete"
        case .invalidReview: "review binding is missing or targets another commit"
        case .invalidCommandEvidence: "build-suite command evidence is missing, out of order, or unsuccessful"
        case .invalidMutationReport: "mutation report evidence is missing or invalid"
        case let .invalidRecordedAt(value): "record timestamp must carry an explicit UTC offset: \(value)"
        }
    }
}

public struct DynamicRendererAuditCheckRun: Codable, Equatable, Sendable {
    public let name: String
    public let headSHA: String
    public let conclusion: String
    public init(name: String, headSHA: String, conclusion: String) { self.name = name; self.headSHA = headSHA; self.conclusion = conclusion }
}

public enum DynamicRendererAuditReview: Codable, Equatable, Sendable {
    case approved(author: String, commitSHA: String)
    case noReview

    private enum CodingKeys: String, CodingKey { case approved, author, commitSHA }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(Bool.self, forKey: .approved) {
            self = .approved(author: try container.decode(String.self, forKey: .author), commitSHA: try container.decode(String.self, forKey: .commitSHA))
        } else {
            self = .noReview
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .approved(author, commitSHA):
            try container.encode(true, forKey: .approved)
            try container.encode(author, forKey: .author)
            try container.encode(commitSHA, forKey: .commitSHA)
        case .noReview:
            try container.encode(false, forKey: .approved)
        }
    }
}

public struct DynamicRendererAuditCommandResult: Codable, Equatable, Sendable {
    public let command: String
    public let exitCode: Int

    public init(command: String, exitCode: Int) {
        self.command = command
        self.exitCode = exitCode
    }
}

public struct DynamicRendererGateRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let auditedSHA: String
    public let headRefOID: String
    public let baseRefName: String
    public let baseRefOID: String
    public let cleanCheckout: Bool
    public let requiredCheckRuns: [DynamicRendererAuditCheckRun]
    public let review: DynamicRendererAuditReview
    public let commands: [DynamicRendererAuditCommandResult]
    public let testInventory: String
    public let mutationReport: String?
    public let findings: [String]
    public let recordedAt: String

    public init(schemaVersion: Int, auditedSHA: String, headRefOID: String, baseRefName: String, baseRefOID: String, cleanCheckout: Bool, requiredCheckRuns: [DynamicRendererAuditCheckRun], review: DynamicRendererAuditReview, commands: [DynamicRendererAuditCommandResult], testInventory: String, mutationReport: String?, findings: [String], recordedAt: String) {
        self.schemaVersion = schemaVersion
        self.auditedSHA = auditedSHA
        self.headRefOID = headRefOID
        self.baseRefName = baseRefName
        self.baseRefOID = baseRefOID
        self.cleanCheckout = cleanCheckout
        self.requiredCheckRuns = requiredCheckRuns
        self.review = review
        self.commands = commands
        self.testInventory = testInventory
        self.mutationReport = mutationReport
        self.findings = findings
        self.recordedAt = recordedAt
    }

    public func validate() throws {
        guard schemaVersion == 1 else { throw DynamicRendererAuditError.unsupportedSchemaVersion(schemaVersion) }
        for sha in [auditedSHA, headRefOID, baseRefOID] where DynamicRendererAuditValidation.isSHA(sha) == false {
            throw DynamicRendererAuditError.invalidSHA(sha)
        }
        guard auditedSHA == headRefOID else { throw DynamicRendererAuditError.mismatchedHead }
        guard cleanCheckout else { throw DynamicRendererAuditError.dirtyCheckout }
        guard requiredCheckRuns.map(\.name) == DynamicRendererBuildAndSuiteGate.requiredLiveCheckNames,
              requiredCheckRuns.allSatisfy({ $0.conclusion.isEmpty == false && $0.headSHA == auditedSHA && DynamicRendererAuditValidation.isSHA($0.headSHA) }) else {
            throw DynamicRendererAuditError.invalidCheckRun
        }
        if case let .approved(author, commitSHA) = review, (author.isEmpty || commitSHA != auditedSHA || DynamicRendererAuditValidation.isSHA(commitSHA) == false) { throw DynamicRendererAuditError.invalidReview }
        guard testInventory.hasPrefix("plans/"), testInventory.hasSuffix(".json") else {
            throw DynamicRendererAuditError.invalidInventoryPath(testInventory)
        }
        guard let mutationReport, mutationReport.hasPrefix("tmp/"), mutationReport.hasSuffix(".json") else {
            throw DynamicRendererAuditError.invalidMutationReport
        }
        guard commands.map(\.command) == DynamicRendererBuildAndSuiteGate.requiredCommands.map({ $0.joined(separator: " ") }),
              commands.allSatisfy({ $0.exitCode == 0 }) else { throw DynamicRendererAuditError.invalidCommandEvidence }
        guard DynamicRendererAuditValidation.hasExplicitOffset(recordedAt) else { throw DynamicRendererAuditError.invalidRecordedAt(recordedAt) }
    }
}

public enum DynamicRendererAuditValidation {
    public static func isSHA(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }
    }
    public static func hasExplicitOffset(_ value: String) -> Bool { value.range(of: "[+-][0-9]{2}:[0-9]{2}$", options: .regularExpression) != nil }
}

public enum DynamicRendererBuildAndSuiteGate {
    /// Keep this order identical to the reviewed plan. The environment prefix
    /// remains one command token so callers can render it without shell parsing.
    public static let requiredCommands = [
        ["make", "build"],
        ["make", "test"],
        ["WIKIFS_APP_TESTS=1", "swift", "test"],
        ["make", "prompts"],
        ["swift", "build"],
        ["swift", "test"],
    ]

    public static let requiredLiveCheckNames = ["lint", "skills", "swift", "swift-linux", "pdf2md"]
}
