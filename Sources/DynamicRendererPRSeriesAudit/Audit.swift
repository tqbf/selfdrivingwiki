// pattern: Mixed (unavoidable)
// Reason: this executable's injected boundary types and shell coordinator must
// share a small public module so SwiftPM test targets can exercise it directly.

import Foundation

public enum DynamicRendererAuditError: Error, Equatable, LocalizedError, Sendable {
    case invalidArguments
    case dirtyCheckout
    case wrongHead(expected: String, actual: String)
    case ancestryFailed
    case githubDrift
    case staleEvidence
    case schemaMismatch
    case commandFailed(String)
    case headChangedDuringWrite

    public var errorDescription: String? {
        switch self {
        case .invalidArguments: "invalid audit arguments"
        case .dirtyCheckout: "dirty checkout"
        case .wrongHead: "wrong local head"
        case .ancestryFailed: "branch ancestry failed"
        case .githubDrift: "github pull request metadata drifted"
        case .staleEvidence: "stale gate evidence"
        case .schemaMismatch: "gate record schema mismatch"
        case .commandFailed(let command): "command failed: \(command)"
        case .headChangedDuringWrite: "head changed during evidence write"
        }
    }
}

public struct AuditCommandResult: Codable, Equatable, Sendable {
    public let command: String
    public let exitStatus: Int32
    public init(command: String, exitStatus: Int32) { self.command = command; self.exitStatus = exitStatus }
}

public struct PullRequestSnapshot: Codable, Equatable, Sendable {
    public let title: String
    public let headRefName: String
    public let headRefOid: String
    public let baseRefName: String
    public let baseRefOid: String
    public let requiredCheckNames: [String]
    public let checkRunHeadOIDs: [String]
    public let approvalCommitOIDs: [String]
    public init(title: String, headRefName: String, headRefOid: String, baseRefName: String, baseRefOid: String, requiredCheckNames: [String], checkRunHeadOIDs: [String], approvalCommitOIDs: [String]) {
        self.title = title; self.headRefName = headRefName; self.headRefOid = headRefOid; self.baseRefName = baseRefName; self.baseRefOid = baseRefOid; self.requiredCheckNames = requiredCheckNames; self.checkRunHeadOIDs = checkRunHeadOIDs; self.approvalCommitOIDs = approvalCommitOIDs
    }
}

public protocol GitRepositoryQuerying: Sendable {
    func currentHead() async throws -> String
    func currentBranch() async throws -> String
    func isClean() async throws -> Bool
    func isAncestor(_ ancestor: String, _ descendant: String) async throws -> Bool
    func run(_ command: String, environment: [String: String]) async throws -> AuditCommandResult
}
public protocol GitHubPullRequestQuerying: Sendable { func pullRequest(headRefName: String) async throws -> PullRequestSnapshot }
public protocol GateRecordReading: Sendable { func record(head: String, evidenceDirectory: URL) throws -> GateRecord? }
public protocol GateRecordWriting: Sendable { func writeAtomically(_ record: GateRecord, evidenceDirectory: URL) throws }
public protocol AuditClock: Sendable { func now() -> Date }
public struct SystemAuditClock: AuditClock {
    public init() {}
    public func now() -> Date { Date() }
}

public struct PRSeries: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let branches: [PRSeriesBranch]
    public let policy: PRSeriesPolicy
}
public struct PRSeriesBranch: Codable, Equatable, Sendable { public let branch: String; public let base: String; public let titlePrefix: String }
public struct PRSeriesPolicy: Codable, Equatable, Sendable { public let requireExactHead: Bool; public let requireChecksOnHead: Bool; public let requireApprovalsOnHead: Bool }

public struct GateRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let auditedHead: String
    public let headRefOid: String
    public let baseRefName: String
    public let baseRefOid: String
    public let cleanCheckout: Bool
    public let requiredCheckNames: [String]
    public let checkRunHeadOIDs: [String]
    public let approvalCommitOIDs: [String]
    public let commandResults: [AuditCommandResult]
    public let inventoryPath: String
    public let findingDispositions: [String]
    public let recordedAt: Date
}

public enum GateRecordSchemaValidator {
    public static let schemaVersion = 1
    public static func validate(_ record: GateRecord) throws {
        guard record.schemaVersion == schemaVersion,
              record.auditedHead.count >= 7,
              record.headRefOid == record.auditedHead,
              record.cleanCheckout,
              !record.baseRefName.isEmpty,
              !record.baseRefOid.isEmpty,
              !record.inventoryPath.isEmpty,
              record.checkRunHeadOIDs.allSatisfy({ $0 == record.auditedHead }),
              record.approvalCommitOIDs.allSatisfy({ $0 == record.auditedHead }),
              record.commandResults.allSatisfy({ $0.exitStatus == 0 })
        else { throw DynamicRendererAuditError.schemaMismatch }
    }
    public static func validateSchema(at url: URL) throws {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        guard object?["$schema"] != nil, (object?["properties"] as? [String: Any])?["schemaVersion"] != nil else { throw DynamicRendererAuditError.schemaMismatch }
    }
}

public struct DynamicRendererPRSeriesAuditor: Sendable {
    private let git: any GitRepositoryQuerying; private let github: any GitHubPullRequestQuerying; private let reader: any GateRecordReading; private let writer: any GateRecordWriting; private let clock: any AuditClock
    public init(git: any GitRepositoryQuerying, github: any GitHubPullRequestQuerying, reader: any GateRecordReading, writer: any GateRecordWriting, clock: any AuditClock) { self.git = git; self.github = github; self.reader = reader; self.writer = writer; self.clock = clock }

    public func verify(series: PRSeries, head: String, evidenceDirectory: URL) async throws {
        guard try await git.isClean() else { throw DynamicRendererAuditError.dirtyCheckout }
        guard try await git.currentHead() == head else { throw DynamicRendererAuditError.wrongHead(expected: head, actual: try await git.currentHead()) }
        let branch = try await git.currentBranch()
        guard let current = series.branches.first(where: { $0.branch == branch }) else { throw DynamicRendererAuditError.githubDrift }
        let snapshot = try await github.pullRequest(headRefName: current.branch)
        guard snapshot.headRefOid == head, snapshot.baseRefName == current.base, snapshot.title.hasPrefix(current.titlePrefix), try await git.isAncestor(snapshot.baseRefOid, head) else { throw DynamicRendererAuditError.githubDrift }
        guard snapshot.checkRunHeadOIDs.allSatisfy({ $0 == head }), snapshot.approvalCommitOIDs.allSatisfy({ $0 == head }) else { throw DynamicRendererAuditError.githubDrift }
        guard let record = try reader.record(head: head, evidenceDirectory: evidenceDirectory) else { throw DynamicRendererAuditError.staleEvidence }
        try GateRecordSchemaValidator.validate(record)
        guard record.recordedAt <= clock.now(), record.baseRefOid == snapshot.baseRefOid else { throw DynamicRendererAuditError.staleEvidence }
    }

    public func buildSuite(head: String, evidenceDirectory: URL, inventoryPath: String) async throws {
        guard try await git.isClean() else { throw DynamicRendererAuditError.dirtyCheckout }
        let localHead = try await git.currentHead(); guard localHead == head else { throw DynamicRendererAuditError.wrongHead(expected: head, actual: localHead) }
        let commands = [("make build", [:]), ("make test", [:]), ("swift test", ["WIKIFS_APP_TESTS": "1"]), ("make prompts", [:]), ("swift build", [:]), ("swift test", [:])]
        var results: [AuditCommandResult] = []
        for (command, environment) in commands { let result = try await git.run(command, environment: environment); guard result.exitStatus == 0 else { throw DynamicRendererAuditError.commandFailed(command) }; results.append(result) }
        let beforeWrite = try await github.pullRequest(headRefName: try await git.currentBranch())
        guard beforeWrite.headRefOid == head, try await git.currentHead() == head else { throw DynamicRendererAuditError.headChangedDuringWrite }
        let record = GateRecord(schemaVersion: GateRecordSchemaValidator.schemaVersion, auditedHead: head, headRefOid: head, baseRefName: beforeWrite.baseRefName, baseRefOid: beforeWrite.baseRefOid, cleanCheckout: true, requiredCheckNames: beforeWrite.requiredCheckNames, checkRunHeadOIDs: beforeWrite.checkRunHeadOIDs, approvalCommitOIDs: beforeWrite.approvalCommitOIDs, commandResults: results, inventoryPath: inventoryPath, findingDispositions: [], recordedAt: clock.now())
        try GateRecordSchemaValidator.validate(record)
        let afterQuery = try await github.pullRequest(headRefName: beforeWrite.headRefName)
        guard afterQuery == beforeWrite, try await git.currentHead() == head else { throw DynamicRendererAuditError.headChangedDuringWrite }
        try writer.writeAtomically(record, evidenceDirectory: evidenceDirectory)
    }
}

public struct FileGateRecordStore: GateRecordReading, GateRecordWriting {
    public init() {}
    public func record(head: String, evidenceDirectory: URL) throws -> GateRecord? { let url = evidenceDirectory.appendingPathComponent("\(head).json"); guard FileManager.default.fileExists(atPath: url.path) else { return nil }; return try JSONDecoder().decode(GateRecord.self, from: Data(contentsOf: url)) }
    public func writeAtomically(_ record: GateRecord, evidenceDirectory: URL) throws { try GateRecordSchemaValidator.validate(record); try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true); let url = evidenceDirectory.appendingPathComponent("\(record.auditedHead).json"); try JSONEncoder().encode(record).write(to: url, options: .atomic) }
}
