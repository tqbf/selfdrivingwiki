import Foundation

// pattern: Imperative Shell

private enum AuditCLIError: Error, CustomStringConvertible {
    case usage
    case invalidHead(String)
    case commandFailed(String, Int32, String)
    case invalidRecord(String)

    var description: String {
        switch self {
        case .usage: "usage: DynamicRendererPRSeriesAudit verify --series <path> --evidence <directory> | build-suite --head <sha> --evidence <directory>"
        case let .invalidHead(head): "HEAD does not match requested audit SHA: \(head)"
        case let .commandFailed(command, status, output): "audit command failed (\(status)): \(command)\n\(output)"
        case let .invalidRecord(message): "invalid dynamic renderer gate record: \(message)"
        }
    }
}

protocol GitRepositoryQuerying {
    func output(arguments: [String]) throws -> String
    func status(arguments: [String]) throws -> Int32
}

struct GitHubAuditPullRequest: Decodable, Equatable {
    struct Check: Decodable, Equatable { let name: String; let headSHA: String; let conclusion: String }
    struct Review: Decodable, Equatable { let author: String; let commitSHA: String; let state: String }
    let headRefName: String
    let headRefOID: String
    let baseRefName: String
    let baseRefOID: String
    let title: String
    let checks: [Check]
    let reviews: [Review]
}

protocol GitHubPullRequestQuerying { func pullRequest(head: String) throws -> GitHubAuditPullRequest }
protocol GateRecordReading { func records(at directory: URL) throws -> [DynamicRendererGateRecord] }
protocol GateRecordWriting { func write(_ record: DynamicRendererGateRecord, to directory: URL) throws }
protocol AuditClock { func recordedAt() -> String }

protocol GitHubCommandRunning {
    func run(arguments: [String]) throws -> (status: Int32, output: String)
}

struct FileGateRecords: GateRecordReading, GateRecordWriting {
    func records(at directory: URL) throws -> [DynamicRendererGateRecord] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { url in
                let data = try Data(contentsOf: url)
                try validateGateRecordJSONShape(data)
                let record = try JSONDecoder().decode(DynamicRendererGateRecord.self, from: data)
                try record.validate()
                guard url.deletingPathExtension().lastPathComponent == record.auditedSHA else {
                    throw AuditCLIError.invalidRecord("gate record filename does not match audited SHA")
                }
                return record
            }
    }
    func write(_ record: DynamicRendererGateRecord, to directory: URL) throws {
        try record.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(record.auditedSHA).json")
        try JSONEncoder.gateEncoder.encode(record).write(to: destination, options: .atomic)
    }
}

private func validateGateRecordJSONShape(_ data: Data) throws {
    let requiredKeys: Set<String> = ["schemaVersion", "auditedSHA", "headRefOID", "baseRefName", "baseRefOID", "cleanCheckout", "requiredCheckRuns", "review", "commands", "testInventory", "mutationReport", "findings", "recordedAt"]
    guard let record = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(record.keys) == requiredKeys,
          let checks = record["requiredCheckRuns"] as? [[String: Any]],
          checks.allSatisfy({ Set($0.keys) == ["name", "headSHA", "conclusion"] }),
          let commands = record["commands"] as? [[String: Any]],
          commands.allSatisfy({ Set($0.keys) == ["command", "exitCode"] }),
          let review = record["review"] as? [String: Any],
          (Set(review.keys) == ["approved"] || Set(review.keys) == ["approved", "author", "commitSHA"])
    else { throw AuditCLIError.invalidRecord("gate record does not match the tracked schema") }
}

struct SystemAuditClock: AuditClock {
    func recordedAt() -> String { ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: "Z", with: "+00:00") }
}

struct ProcessGitHubPullRequestQuery: GitHubPullRequestQuerying {
    private let commandRunner: any GitHubCommandRunning

    init(commandRunner: any GitHubCommandRunning = ProcessGitHubCommandRunner()) {
        self.commandRunner = commandRunner
    }

    func pullRequest(head: String) throws -> GitHubAuditPullRequest {
        let result = try commandRunner.run(arguments: ["gh", "pr", "view", head, "--json", "headRefName,headRefOid,baseRefName,baseRefOid,title,statusCheckRollup,reviews"])
        guard result.status == 0 else { throw AuditCLIError.commandFailed("gh pr view", result.status, result.output) }
        let object = try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any] ?? [:]
        let checks: [GitHubAuditPullRequest.Check] = (object["statusCheckRollup"] as? [[String: Any]] ?? []).map { value in
            .init(name: value["name"] as? String ?? "", headSHA: value["headSha"] as? String ?? "", conclusion: value["conclusion"] as? String ?? "")
        }
        let reviews: [GitHubAuditPullRequest.Review] = (object["reviews"] as? [[String: Any]] ?? []).map { value in
            let author = (value["author"] as? [String: Any])?["login"] as? String ?? ""
            let commit = (value["commit"] as? [String: Any])?["oid"] as? String ?? ""
            return .init(author: author, commitSHA: commit, state: value["state"] as? String ?? "")
        }
        return .init(headRefName: object["headRefName"] as? String ?? "", headRefOID: object["headRefOid"] as? String ?? "", baseRefName: object["baseRefName"] as? String ?? "", baseRefOID: object["baseRefOid"] as? String ?? "", title: object["title"] as? String ?? "", checks: checks, reviews: reviews)
    }
}

private struct ProcessGitHubCommandRunner: GitHubCommandRunning {
    func run(arguments: [String]) throws -> (status: Int32, output: String) {
        let result = try ProcessRunner.run(executable: "/usr/bin/env", arguments: arguments)
        return (result.status, result.output)
    }
}

private struct ProcessGitRepositoryQuery: GitRepositoryQuerying {
    func output(arguments: [String]) throws -> String {
        let result = try ProcessRunner.run(executable: "/usr/bin/env", arguments: ["git"] + arguments)
        guard result.status == 0 else { throw AuditCLIError.commandFailed("git \(arguments.joined(separator: " "))", result.status, result.output) }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func status(arguments: [String]) throws -> Int32 {
        try ProcessRunner.run(executable: "/usr/bin/env", arguments: ["git"] + arguments).status
    }
}

private struct ProcessRunner {
    struct Result { let status: Int32; let output: String }

    static func run(executable: String, arguments: [String], environment: [String: String]? = nil) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, replacement in replacement } }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        return .init(status: process.terminationStatus, output: String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}

enum DynamicRendererPRSeriesAuditMain {
    static func run(arguments: [String]) throws {
        guard let subcommand = arguments.first else { throw AuditCLIError.usage }
        let options = Dictionary(uniqueKeysWithValues: stride(from: 1, to: arguments.count - 1, by: 2).map { (arguments[$0], arguments[$0 + 1]) })
        switch subcommand {
        case "verify":
            guard let series = options["--series"], let evidence = options["--evidence"] else { throw AuditCLIError.usage }
            let records = FileGateRecords()
            try verify(seriesPath: series, evidenceDirectory: evidence, git: ProcessGitRepositoryQuery(), github: ProcessGitHubPullRequestQuery(), records: records, writer: records)
        case "build-suite":
            guard let head = options["--head"], let evidence = options["--evidence"], DynamicRendererAuditValidation.isSHA(head) else { throw AuditCLIError.usage }
            try buildSuite(head: head, evidenceDirectory: evidence, git: ProcessGitRepositoryQuery(), records: FileGateRecords(), clock: SystemAuditClock())
        default: throw AuditCLIError.usage
        }
    }

    static func verify(seriesPath: String, evidenceDirectory: String, git: GitRepositoryQuerying, github: GitHubPullRequestQuerying, records: GateRecordReading) throws {
        try verify(seriesPath: seriesPath, evidenceDirectory: evidenceDirectory, git: git, github: github, records: records, writer: DiscardingGateRecordWriter())
    }

    static func verify(seriesPath: String, evidenceDirectory: String, git: GitRepositoryQuerying, github: GitHubPullRequestQuerying, records: GateRecordReading, writer: GateRecordWriting) throws {
        let seriesURL = URL(fileURLWithPath: seriesPath)
        let series = try decodeSeries(at: seriesURL)
        guard try git.output(arguments: ["status", "--porcelain"]).isEmpty else { throw DynamicRendererAuditError.dirtyCheckout }
        let branch = try git.output(arguments: ["branch", "--show-current"])
        guard let phase = series.phases.first(where: { $0.branch == branch }) else { throw AuditCLIError.invalidRecord("branch is not in the PR series") }
        let first = try github.pullRequest(head: branch)
        guard first.headRefName == branch, first.baseRefName == phase.base, first.title.range(of: "^(feat|fix|test|chore|docs|refactor)(\\([^)]+\\))?: .+", options: .regularExpression) != nil else { throw AuditCLIError.invalidRecord("PR metadata does not bind this branch/base/title") }
        if phase.base == "main" {
            let currentBase = try git.output(arguments: ["rev-parse", "origin/main"])
            guard first.baseRefOID == currentBase else { throw AuditCLIError.invalidRecord("PR base is not the current origin/main SHA") }
        }
        guard try git.status(arguments: ["merge-base", "--is-ancestor", first.baseRefOID, first.headRefOID]) == 0 else { throw AuditCLIError.invalidRecord("PR base is not an ancestor") }
        _ = try git.output(arguments: ["diff", "--name-only", "\(first.baseRefOID)...\(first.headRefOID)"])
        let liveChecks = try requiredLiveChecks(from: first)
        guard let approval = first.reviews.last(where: { $0.state.uppercased() == "APPROVED" && $0.commitSHA == first.headRefOID }) else { throw AuditCLIError.invalidRecord("missing current-head approval") }
        let evidenceURL = URL(fileURLWithPath: evidenceDirectory)
        let matchingRecords = try records.records(at: evidenceURL).filter { $0.auditedSHA == first.headRefOID }
        guard matchingRecords.count == 1, let record = matchingRecords.first else { throw AuditCLIError.invalidRecord("missing exact-head gate record") }
        do { try record.validate() }
        catch { throw AuditCLIError.invalidRecord("invalid record: \(error)") }
        guard let inventory = phase.inventory, record.baseRefOID == first.baseRefOID, record.testInventory == inventory else { throw AuditCLIError.invalidRecord("evidence does not bind the PR series") }
        try validateEvidence(record: record, phase: phase, baseOID: first.baseRefOID, repositoryRoot: seriesURL.deletingLastPathComponent().deletingLastPathComponent())
        let second = try github.pullRequest(head: branch)
        guard second == first else { throw AuditCLIError.invalidRecord("PR changed during audit") }
        let retainedRecord = DynamicRendererGateRecord(schemaVersion: record.schemaVersion, auditedSHA: record.auditedSHA, headRefOID: record.headRefOID, baseRefName: record.baseRefName, baseRefOID: record.baseRefOID, cleanCheckout: record.cleanCheckout, requiredCheckRuns: liveChecks, review: .approved(author: approval.author, commitSHA: approval.commitSHA), commands: record.commands, testInventory: record.testInventory, mutationReport: record.mutationReport, findings: record.findings, recordedAt: record.recordedAt)
        try retainedRecord.validate()
        try writer.write(retainedRecord, to: evidenceURL)
    }

    static func buildSuite(head: String, evidenceDirectory: String, git: GitRepositoryQuerying, records: GateRecordWriting, clock: AuditClock) throws {
        guard try git.output(arguments: ["rev-parse", "HEAD"]) == head else { throw AuditCLIError.invalidHead(head) }
        guard try git.output(arguments: ["status", "--porcelain"]).isEmpty else { throw DynamicRendererAuditError.dirtyCheckout }
        var results: [DynamicRendererAuditCommandResult] = []
        for command in DynamicRendererBuildAndSuiteGate.requiredCommands {
            let environment = command.first?.hasPrefix("WIKIFS_APP_TESTS=") == true ? ["WIKIFS_APP_TESTS": "1"] : nil
            let executableArguments = environment == nil ? command : Array(command.dropFirst())
            let result = try ProcessRunner.run(executable: "/usr/bin/env", arguments: executableArguments, environment: environment)
            results.append(.init(command: command.joined(separator: " "), exitCode: Int(result.status)))
            guard result.status == 0 else { throw AuditCLIError.commandFailed(command.joined(separator: " "), result.status, result.output) }
        }
        let baseOID = try git.output(arguments: ["rev-parse", "origin/main"])
        guard try git.output(arguments: ["rev-parse", "HEAD"]) == head else { throw AuditCLIError.invalidHead(head) }
        let record = DynamicRendererGateRecord(schemaVersion: 1, auditedSHA: head, headRefOID: head, baseRefName: "main", baseRefOID: baseOID, cleanCheckout: true, requiredCheckRuns: DynamicRendererBuildAndSuiteGate.requiredLiveCheckNames.map { .init(name: $0, headSHA: head, conclusion: "pending") }, review: .noReview, commands: results, testInventory: "plans/dynamic-renderers-pr1-test-inventory.json", mutationReport: "tmp/dynamic-renderer-pr1-mutation-report.json", findings: [], recordedAt: clock.recordedAt())
        try record.validate()
        let phase = DynamicRendererAuditSeries.Phase(number: 1, branch: "feature/dynamic-renderers-01-model", base: "main", inventory: record.testInventory)
        try validateEvidence(record: record, phase: phase, baseOID: baseOID, repositoryRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
        try records.write(record, to: URL(fileURLWithPath: evidenceDirectory, isDirectory: true))
    }
}

private struct DiscardingGateRecordWriter: GateRecordWriting {
    func write(_ record: DynamicRendererGateRecord, to directory: URL) throws {}
}

private struct DynamicRendererAuditSeries: Decodable {
    struct Phase: Decodable {
        let number: Int
        let branch: String
        let base: String
        let inventory: String?
    }

    let schemaVersion: Int
    let issue: Int
    let phases: [Phase]
}

private struct DynamicRendererAuditInventory: Decodable {
    struct MutationEvidence: Decodable { let report: String }

    let schemaVersion: Int
    let issue: Int
    let pr: Int
    let baseCommit: String
    let mutationEvidence: MutationEvidence
}

private func decodeSeries(at url: URL) throws -> DynamicRendererAuditSeries {
    let series = try JSONDecoder().decode(DynamicRendererAuditSeries.self, from: Data(contentsOf: url))
    guard series.schemaVersion == 1, series.issue == 1026 else { throw AuditCLIError.invalidRecord("invalid PR series") }
    return series
}

private func requiredLiveChecks(from pullRequest: GitHubAuditPullRequest) throws -> [DynamicRendererAuditCheckRun] {
    try DynamicRendererBuildAndSuiteGate.requiredLiveCheckNames.map { name in
        guard let check = pullRequest.checks.last(where: { $0.name == name && $0.headSHA == pullRequest.headRefOID && $0.conclusion.lowercased() == "success" }) else {
            throw AuditCLIError.invalidRecord("required check \(name) is missing, unsuccessful, or bound to another SHA")
        }
        return .init(name: check.name, headSHA: check.headSHA, conclusion: check.conclusion)
    }
}

private func validateEvidence(record: DynamicRendererGateRecord, phase: DynamicRendererAuditSeries.Phase, baseOID: String, repositoryRoot: URL) throws {
    guard let expectedInventory = phase.inventory else { throw AuditCLIError.invalidRecord("PR phase has no test inventory") }
    let schemaURL = repositoryRoot.appendingPathComponent("plans/dynamic-renderer-gate-record.schema.json")
    let schema = try JSONSerialization.jsonObject(with: Data(contentsOf: schemaURL)) as? [String: Any]
    guard schema?["additionalProperties"] as? Bool == false,
          (schema?["properties"] as? [String: Any])?["schemaVersion"] as? [String: Any] != nil else {
        throw AuditCLIError.invalidRecord("gate record schema is missing or malformed")
    }

    let inventoryURL = repositoryRoot.appendingPathComponent(expectedInventory)
    let inventory = try JSONDecoder().decode(DynamicRendererAuditInventory.self, from: Data(contentsOf: inventoryURL))
    guard inventory.schemaVersion == 1, inventory.issue == 1026, inventory.pr == phase.number, inventory.baseCommit == baseOID else {
        throw AuditCLIError.invalidRecord("test inventory does not bind the current PR base")
    }
    guard record.testInventory == expectedInventory,
          record.mutationReport == inventory.mutationEvidence.report else {
        throw AuditCLIError.invalidRecord("record does not bind the tracked inventory and mutation report")
    }
    let mutationURL = repositoryRoot.appendingPathComponent(inventory.mutationEvidence.report)
    let mutationReport = try JSONSerialization.jsonObject(with: Data(contentsOf: mutationURL)) as? [String: Any]
    guard mutationReport?["files"] as? [String: Any] != nil else {
        throw AuditCLIError.invalidRecord("mutation report is missing or malformed")
    }
}

do {
    try DynamicRendererPRSeriesAuditMain.run(arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

private extension JSONEncoder {
    static var gateEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
