import Foundation

// pattern: Functional Core

public enum DynamicRendererAuditError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedSchemaVersion(Int)
    case invalidSHA(String)
    case mismatchedHead
    case dirtyCheckout
    case invalidInventoryPath(String)
    case invalidCommandExitCode(Int)

    public var description: String {
        switch self {
        case let .unsupportedSchemaVersion(version): "unsupported gate record schema version: \(version)"
        case let .invalidSHA(sha): "invalid git SHA: \(sha)"
        case .mismatchedHead: "audited SHA and head reference OID differ"
        case .dirtyCheckout: "audit requires a clean checkout"
        case let .invalidInventoryPath(path): "invalid test inventory path: \(path)"
        case let .invalidCommandExitCode(code): "invalid command exit code: \(code)"
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
    public let commands: [DynamicRendererAuditCommandResult]
    public let testInventory: String
    public let mutationReport: String?
    public let findings: [String]
    public let recordedAt: String

    public init(schemaVersion: Int, auditedSHA: String, headRefOID: String, baseRefName: String, baseRefOID: String, cleanCheckout: Bool, commands: [DynamicRendererAuditCommandResult], testInventory: String, mutationReport: String?, findings: [String], recordedAt: String) {
        self.schemaVersion = schemaVersion
        self.auditedSHA = auditedSHA
        self.headRefOID = headRefOID
        self.baseRefName = baseRefName
        self.baseRefOID = baseRefOID
        self.cleanCheckout = cleanCheckout
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
        guard testInventory.hasPrefix("plans/"), testInventory.hasSuffix(".json") else {
            throw DynamicRendererAuditError.invalidInventoryPath(testInventory)
        }
        for command in commands where command.exitCode < 0 {
            throw DynamicRendererAuditError.invalidCommandExitCode(command.exitCode)
        }
    }
}

public enum DynamicRendererAuditValidation {
    public static func isSHA(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }
    }
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
}
