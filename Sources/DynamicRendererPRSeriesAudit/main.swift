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
    struct Review: Decodable, Equatable { let author: String; let commitSHA: String; let state: String; let submittedAt: String }
    let headRefName: String
    let headRefOID: String
    let baseRefName: String
    let baseRefOID: String
    let title: String
    let reviewDecision: String
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
    private let schemaURL: URL

    init(schemaURL: URL? = nil) {
        self.schemaURL = schemaURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("plans/dynamic-renderer-gate-record.schema.json")
    }

    func records(at directory: URL) throws -> [DynamicRendererGateRecord] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { url in
                let data = try Data(contentsOf: url)
                try GateRecordSchemaValidator.validate(instanceData: data, schemaData: Data(contentsOf: schemaURL))
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
        let data = try JSONEncoder.gateEncoder.encode(record)
        try GateRecordSchemaValidator.validate(instanceData: data, schemaData: Data(contentsOf: schemaURL))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(record.auditedSHA).json")
        try data.write(to: destination, options: .atomic)
    }
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
        let result = try commandRunner.run(arguments: ["gh", "pr", "view", head, "--json", "headRefName,headRefOid,baseRefName,baseRefOid,title,reviewDecision,reviews"])
        guard result.status == 0 else { throw AuditCLIError.commandFailed("gh pr view", result.status, result.output) }
        let object = try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any] ?? [:]
        let headOID = object["headRefOid"] as? String ?? ""
        guard DynamicRendererAuditValidation.isSHA(headOID) else { throw AuditCLIError.invalidRecord("PR head SHA is missing or invalid") }
        let checksResult = try commandRunner.run(arguments: ["gh", "api", "repos/{owner}/{repo}/commits/\(headOID)/check-runs?per_page=100"])
        guard checksResult.status == 0 else { throw AuditCLIError.commandFailed("gh api check-runs", checksResult.status, checksResult.output) }
        let checksObject = try JSONSerialization.jsonObject(with: Data(checksResult.output.utf8)) as? [String: Any] ?? [:]
        let checks: [GitHubAuditPullRequest.Check] = (checksObject["check_runs"] as? [[String: Any]] ?? []).map { value in
            .init(name: value["name"] as? String ?? "", headSHA: value["head_sha"] as? String ?? "", conclusion: value["conclusion"] as? String ?? "")
        }
        let reviews: [GitHubAuditPullRequest.Review] = (object["reviews"] as? [[String: Any]] ?? []).map { value in
            let author = (value["author"] as? [String: Any])?["login"] as? String ?? ""
            let commit = (value["commit"] as? [String: Any])?["oid"] as? String ?? ""
            return .init(author: author, commitSHA: commit, state: value["state"] as? String ?? "", submittedAt: value["submittedAt"] as? String ?? "")
        }
        let pullRequest = GitHubAuditPullRequest(headRefName: object["headRefName"] as? String ?? "", headRefOID: headOID, baseRefName: object["baseRefName"] as? String ?? "", baseRefOID: object["baseRefOid"] as? String ?? "", title: object["title"] as? String ?? "", reviewDecision: object["reviewDecision"] as? String ?? "", checks: checks, reviews: reviews)
        _ = try requiredLiveChecks(from: pullRequest)
        return pullRequest
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
        guard first.reviewDecision.uppercased() == "APPROVED",
              let approval = effectiveCurrentHeadApproval(from: first) else {
            throw AuditCLIError.invalidRecord("missing current effective head approval")
        }
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
    struct MutationEvidence: Decodable {
        struct Threshold: Decodable, Equatable {
            let maximumSurvivors: Int
            let maximumUnviable: Int
        }

        struct PhasePolicy: Decodable {
            let allowedUnviableSeverities: [String]
        }

        let report: String
        let scope: String
        let coveredSymbols: [String]
        let threshold: Threshold
        let phasePolicy: PhasePolicy
    }

    let schemaVersion: Int
    let issue: Int
    let pr: Int
    let baseCommit: String
    let mutationEvidence: MutationEvidence
}

private struct DynamicRendererMutationReport: Decodable {
    struct Result: Decodable {
        let killed: Int
        let survived: Int
        let unviable: Int
    }

    struct Disposition: Decodable {
        let outcome: String
        let severity: String
        let count: Int
        let disposition: String
        let rationale: String
    }

    let schemaVersion: Int
    let auditedSHA: String
    let baseOID: String
    let generatedAt: String
    let scope: String
    let coveredSymbols: [String]
    let result: Result
    let threshold: DynamicRendererAuditInventory.MutationEvidence.Threshold
    let dispositions: [Disposition]
    let passed: Bool
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

private func effectiveCurrentHeadApproval(from pullRequest: GitHubAuditPullRequest) -> GitHubAuditPullRequest.Review? {
    let latestByAuthor = Dictionary(grouping: pullRequest.reviews.filter { $0.author.isEmpty == false }, by: \.author)
        .compactMapValues { $0.max(by: { $0.submittedAt < $1.submittedAt }) }
    guard latestByAuthor.values.contains(where: { $0.state.uppercased() == "CHANGES_REQUESTED" }) == false else {
        return nil
    }
    return latestByAuthor.values
        .filter { $0.state.uppercased() == "APPROVED" && $0.commitSHA == pullRequest.headRefOID && DynamicRendererAuditValidation.isSHA($0.commitSHA) }
        .max(by: { $0.submittedAt < $1.submittedAt })
}

private func validateEvidence(record: DynamicRendererGateRecord, phase: DynamicRendererAuditSeries.Phase, baseOID: String, repositoryRoot: URL) throws {
    guard let expectedInventory = phase.inventory else { throw AuditCLIError.invalidRecord("PR phase has no test inventory") }
    let schemaURL = repositoryRoot.appendingPathComponent("plans/dynamic-renderer-gate-record.schema.json")
    let schemaData = try Data(contentsOf: schemaURL)
    let recordData = try JSONEncoder.gateEncoder.encode(record)
    do { try GateRecordSchemaValidator.validate(instanceData: recordData, schemaData: schemaData) }
    catch { throw AuditCLIError.invalidRecord("gate record does not match the tracked schema") }

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
    let mutationReport = try JSONDecoder().decode(DynamicRendererMutationReport.self, from: Data(contentsOf: mutationURL))
    try validateMutationReport(mutationReport, inventory: inventory.mutationEvidence, record: record, baseOID: baseOID)
}

private func validateMutationReport(
    _ report: DynamicRendererMutationReport,
    inventory: DynamicRendererAuditInventory.MutationEvidence,
    record: DynamicRendererGateRecord,
    baseOID: String
) throws {
    guard report.schemaVersion == 1,
          report.auditedSHA == record.auditedSHA,
          report.baseOID == baseOID,
          DynamicRendererAuditValidation.isSHA(report.auditedSHA),
          DynamicRendererAuditValidation.isSHA(report.baseOID),
          report.scope == inventory.scope,
          Set(report.coveredSymbols) == Set(inventory.coveredSymbols),
          report.coveredSymbols.count == Set(report.coveredSymbols).count,
          report.threshold == inventory.threshold,
          report.passed,
          report.result.killed >= 0,
          report.result.survived >= 0,
          report.result.unviable >= 0,
          report.result.survived <= inventory.threshold.maximumSurvivors,
          report.result.unviable <= inventory.threshold.maximumUnviable,
          DynamicRendererAuditValidation.hasExplicitOffset(report.generatedAt),
          DynamicRendererAuditValidation.hasExplicitOffset(record.recordedAt),
          let generatedAt = ISO8601DateFormatter().date(from: report.generatedAt),
          let recordedAt = ISO8601DateFormatter().date(from: record.recordedAt),
          generatedAt <= recordedAt
    else { throw DynamicRendererAuditError.invalidMutationReport }

    let unviableCount = report.dispositions.filter { $0.outcome == "unviable" }.reduce(0) { $0 + $1.count }
    let survivorCount = report.dispositions.filter { $0.outcome == "survived" }.reduce(0) { $0 + $1.count }
    guard unviableCount == report.result.unviable,
          survivorCount == report.result.survived,
          report.dispositions.allSatisfy({ disposition in
              disposition.count > 0 && disposition.rationale.isEmpty == false &&
              ["survived", "unviable"].contains(disposition.outcome) &&
              ["critical", "high", "medium", "low"].contains(disposition.severity) &&
              disposition.disposition == "accepted"
          }),
          report.dispositions.contains(where: { ["critical", "high"].contains($0.severity) }) == false,
          report.dispositions.filter({ $0.outcome == "unviable" }).allSatisfy({ inventory.phasePolicy.allowedUnviableSeverities.contains($0.severity) })
    else { throw DynamicRendererAuditError.invalidMutationReport }
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
