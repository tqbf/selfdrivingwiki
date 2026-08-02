import Foundation

#if os(Linux)
import Glibc
import Crypto
#else
import Darwin
import CryptoKit
#endif

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
    struct Check: Decodable, Equatable {
        let name: String
        let headSHA: String
        let status: String
        let conclusion: String
        let startedAt: String
        let completedAt: String?
        let id: Int

        init(name: String, headSHA: String, status: String = "COMPLETED", conclusion: String = "success", startedAt: String = "2026-08-01T00:00:00+00:00", completedAt: String? = "2026-08-01T00:00:01+00:00", id: Int = 1) {
            self.name = name
            self.headSHA = headSHA
            self.status = status
            self.conclusion = conclusion
            self.startedAt = startedAt
            self.completedAt = completedAt
            self.id = id
        }
    }
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
protocol AuditCommandRunning { func run(command: [String], environment: [String: String]?) throws -> ProcessRunner.Result }

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

private struct ProcessAuditCommandRunner: AuditCommandRunning {
    func run(command: [String], environment: [String: String]?) throws -> ProcessRunner.Result {
        let executableArguments = environment == nil ? command : Array(command.dropFirst())
        return try ProcessRunner.run(executable: "/usr/bin/env", arguments: executableArguments, environment: environment)
    }
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
        let rawChecks = checksObject["check_runs"] as? [[String: Any]] ?? []
        guard (checksObject["total_count"] as? Int ?? rawChecks.count) <= rawChecks.count else {
            throw AuditCLIError.invalidRecord("check run query is paginated; refusing an incomplete ordering")
        }
        let checks: [GitHubAuditPullRequest.Check] = rawChecks.map { value in
            .init(name: value["name"] as? String ?? "", headSHA: value["head_sha"] as? String ?? "", status: value["status"] as? String ?? "", conclusion: value["conclusion"] as? String ?? "", startedAt: value["started_at"] as? String ?? "", completedAt: value["completed_at"] as? String, id: value["id"] as? Int ?? 0)
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

enum ProcessRunnerError: Error, Equatable {
    case timedOut
    case cancelled
}

struct ProcessRunner {
    struct Result { let status: Int32; let output: String }

    struct Policy: Sendable {
        let timeout: TimeInterval
        let terminationGrace: TimeInterval
        let isCancelled: @Sendable () -> Bool

        init(timeout: TimeInterval = 300, terminationGrace: TimeInterval = 2, isCancelled: @escaping @Sendable () -> Bool = { false }) {
            self.timeout = timeout
            self.terminationGrace = terminationGrace
            self.isCancelled = isCancelled
        }
    }

    // The NSLock serializes the dispatch-drainer writes and caller read.
    // swiftlint:disable:next unchecked_sendable
    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = Data()
        func set(_ data: Data) { lock.lock(); defer { lock.unlock() }; stored = data }
        func value() -> Data { lock.lock(); defer { lock.unlock() }; return stored }
    }

    static func run(executable: String, arguments: [String], environment: [String: String]? = nil, policy: Policy = .init()) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, replacement in replacement } }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let drains = DispatchGroup()
        let stdoutData = DataBox()
        let stderrData = DataBox()
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        try process.run()
        drains.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutData.set(stdout.fileHandleForReading.readDataToEndOfFile())
            drains.leave()
        }
        drains.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderrData.set(stderr.fileHandleForReading.readDataToEndOfFile())
            drains.leave()
        }

        let deadline = Date().addingTimeInterval(policy.timeout)
        var failure: ProcessRunnerError?
        while terminated.wait(timeout: .now() + .milliseconds(20)) == .timedOut {
            if policy.isCancelled() { failure = .cancelled; break }
            if Date() >= deadline { failure = .timedOut; break }
        }
        if let failure {
            terminate(process, grace: policy.terminationGrace, completion: terminated)
            _ = drains.wait(timeout: .now() + policy.terminationGrace)
            throw failure
        }
        _ = drains.wait(timeout: .now() + policy.terminationGrace)
        return .init(status: process.terminationStatus, output: String(decoding: stdoutData.value() + stderrData.value(), as: UTF8.self))
    }

    private static func terminate(_ process: Process, grace: TimeInterval, completion: DispatchSemaphore) {
        process.terminate()
        guard completion.wait(timeout: .now() + grace) == .timedOut else { return }
        _ = kill(process.processIdentifier, SIGKILL)
        _ = completion.wait(timeout: .now() + grace)
    }
}

enum DynamicRendererPRSeriesAuditMain {
    static func run(arguments: [String]) throws {
        guard let subcommand = arguments.first else { throw AuditCLIError.usage }
        let options = try options(for: subcommand, arguments: Array(arguments.dropFirst()))
        switch subcommand {
        case "verify":
            guard let series = options["--series"], let evidence = options["--evidence"] else { throw AuditCLIError.usage }
            let records = FileGateRecords()
            try verify(seriesPath: series, evidenceDirectory: evidence, git: ProcessGitRepositoryQuery(), github: ProcessGitHubPullRequestQuery(), records: records, writer: records)
        case "build-suite":
            guard let head = options["--head"], let evidence = options["--evidence"], DynamicRendererAuditValidation.isSHA(head) else { throw AuditCLIError.usage }
            try buildSuite(head: head, evidenceDirectory: evidence, git: ProcessGitRepositoryQuery(), github: ProcessGitHubPullRequestQuery(), records: FileGateRecords(), clock: SystemAuditClock())
        default: throw AuditCLIError.usage
        }
    }

    static func parseOptions(_ arguments: [String]) throws -> [String: String] {
        guard arguments.count.isMultiple(of: 2) else { throw AuditCLIError.usage }
        var options: [String: String] = [:]
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let key = arguments[index]
            let value = arguments[arguments.index(after: index)]
            guard key.hasPrefix("--"), value.isEmpty == false, options.updateValue(value, forKey: key) == nil else {
                throw AuditCLIError.usage
            }
            index = arguments.index(index, offsetBy: 2)
        }
        return options
    }

    static func options(for subcommand: String, arguments: [String]) throws -> [String: String] {
        let options = try parseOptions(arguments)
        let allowed: Set<String>
        switch subcommand {
        case "verify": allowed = ["--series", "--evidence"]
        case "build-suite": allowed = ["--head", "--evidence"]
        default: throw AuditCLIError.usage
        }
        guard Set(options.keys) == allowed else { throw AuditCLIError.usage }
        return options
    }

    static func verify(seriesPath: String, evidenceDirectory: String, git: GitRepositoryQuerying, github: GitHubPullRequestQuerying, records: GateRecordReading) throws {
        try verify(seriesPath: seriesPath, evidenceDirectory: evidenceDirectory, git: git, github: github, records: records, writer: DiscardingGateRecordWriter())
    }

    static func verify(seriesPath: String, evidenceDirectory: String, git: GitRepositoryQuerying, github: GitHubPullRequestQuerying, records: GateRecordReading, writer: GateRecordWriting) throws {
        let seriesURL = URL(fileURLWithPath: seriesPath)
        let series = try decodeSeries(at: seriesURL)
        guard try git.output(arguments: ["status", "--porcelain"]).isEmpty else { throw DynamicRendererAuditError.dirtyCheckout }
        let branch = try git.output(arguments: ["branch", "--show-current"])
        let localHead = try git.output(arguments: ["rev-parse", "HEAD"])
        guard let phase = series.phases.first(where: { $0.branch == branch }) else { throw AuditCLIError.invalidRecord("branch is not in the PR series") }
        let first = try github.pullRequest(head: branch)
        guard first.headRefOID == localHead else { throw AuditCLIError.invalidHead(first.headRefOID) }
        guard first.headRefName == branch, first.baseRefName == phase.base, first.title.range(of: "^(feat|fix|test|chore|docs|refactor)(\\([^)]+\\))?: .+", options: .regularExpression) != nil else { throw AuditCLIError.invalidRecord("PR metadata does not bind this branch/base/title") }
        let repositoryRoot = seriesURL.deletingLastPathComponent().deletingLastPathComponent()
        let changedProductionSources = try verifyExactBase(phase: phase, pullRequest: first, git: git, repositoryRoot: repositoryRoot)
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
        guard let inventory = phase.inventory, record.baseRefName == first.baseRefName, record.baseRefOID == first.baseRefOID, record.testInventory == inventory else { throw AuditCLIError.invalidRecord("evidence does not bind the PR series") }
        try validateEvidence(record: record, phase: phase, baseOID: first.baseRefOID, changedProductionSources: changedProductionSources, repositoryRoot: repositoryRoot)
        let second = try github.pullRequest(head: branch)
        guard second == first else { throw AuditCLIError.invalidRecord("PR changed during audit") }
        guard try git.output(arguments: ["rev-parse", "HEAD"]) == localHead,
              try git.output(arguments: ["status", "--porcelain"]).isEmpty else { throw DynamicRendererAuditError.dirtyCheckout }
        let retainedRecord = DynamicRendererGateRecord(schemaVersion: record.schemaVersion, auditedSHA: record.auditedSHA, headRefOID: record.headRefOID, localHeadOID: localHead, baseRefName: second.baseRefName, baseRefOID: second.baseRefOID, cleanCheckout: record.cleanCheckout, requiredCheckRuns: liveChecks, review: .approved(author: approval.author, commitSHA: approval.commitSHA), commands: record.commands, testInventory: record.testInventory, mutationReport: record.mutationReport, findings: record.findings, recordedAt: record.recordedAt)
        try retainedRecord.validate()
        try writer.write(retainedRecord, to: evidenceURL)
    }

    static func buildSuite(head: String, evidenceDirectory: String, git: GitRepositoryQuerying, github: GitHubPullRequestQuerying, records: GateRecordWriting, clock: AuditClock, runner: AuditCommandRunning = ProcessAuditCommandRunner(), seriesPath: String? = nil) throws {
        try requireStableCheckout(expectedHead: head, git: git)
        let branch = try git.output(arguments: ["branch", "--show-current"])
        let seriesURL = seriesPath.map(URL.init(fileURLWithPath:)) ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("plans/dynamic-renderers-pr-series.json")
        let series = try decodeSeries(at: seriesURL)
        guard let phase = series.phases.first(where: { $0.branch == branch }) else { throw AuditCLIError.invalidRecord("branch is not in the PR series") }
        let first = try github.pullRequest(head: branch)
        guard first.headRefOID == head, first.headRefName == branch, first.baseRefName == phase.base else {
            throw AuditCLIError.invalidRecord("PR metadata does not bind this build-suite run")
        }
        let repositoryRoot = seriesURL.deletingLastPathComponent().deletingLastPathComponent()
        _ = try verifyExactBase(phase: phase, pullRequest: first, git: git, repositoryRoot: repositoryRoot)
        var results: [DynamicRendererAuditCommandResult] = []
        for command in DynamicRendererBuildAndSuiteGate.requiredCommands {
            try requireStableCheckout(expectedHead: head, git: git)
            let environment = command.first?.hasPrefix("WIKIFS_APP_TESTS=") == true ? ["WIKIFS_APP_TESTS": "1"] : nil
            let result = try runner.run(command: command, environment: environment)
            results.append(.init(command: command.joined(separator: " "), exitCode: Int(result.status)))
            try requireStableCheckout(expectedHead: head, git: git)
            guard result.status == 0 else { throw AuditCLIError.commandFailed(command.joined(separator: " "), result.status, result.output) }
        }
        try requireStableCheckout(expectedHead: head, git: git)
        let second = try github.pullRequest(head: branch)
        guard second == first else { throw AuditCLIError.invalidRecord("PR changed during build-suite") }
        let changedProductionSources = try verifyExactBase(phase: phase, pullRequest: second, git: git, repositoryRoot: repositoryRoot)
        let record = DynamicRendererGateRecord(schemaVersion: 1, auditedSHA: head, headRefOID: head, localHeadOID: head, baseRefName: second.baseRefName, baseRefOID: second.baseRefOID, cleanCheckout: true, requiredCheckRuns: DynamicRendererBuildAndSuiteGate.requiredLiveCheckNames.map { .init(name: $0, headSHA: head, conclusion: "pending") }, review: .noReview, commands: results, testInventory: try requiredInventoryPath(for: phase), mutationReport: nil, findings: [], recordedAt: clock.recordedAt())
        try record.validate()
        try validateEvidence(record: record, phase: phase, baseOID: second.baseRefOID, changedProductionSources: changedProductionSources, repositoryRoot: repositoryRoot)
        try requireStableCheckout(expectedHead: head, git: git)
        try records.write(record, to: URL(fileURLWithPath: evidenceDirectory, isDirectory: true))
    }
}

private func requireStableCheckout(expectedHead: String, git: GitRepositoryQuerying) throws {
    guard try git.output(arguments: ["rev-parse", "HEAD"]) == expectedHead else { throw AuditCLIError.invalidHead(expectedHead) }
    guard try git.output(arguments: ["status", "--porcelain"]).isEmpty else { throw DynamicRendererAuditError.dirtyCheckout }
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
    struct TestMapping: Decodable {
        let symbol: String?
        let path: String?
        let tests: [String]

        var subject: String { symbol ?? path ?? "" }
    }
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
    let productionSources: [String]
    let productionSymbols: [TestMapping]
    let decisionBranches: [TestMapping]
    let mutationEvidence: MutationEvidence
}

private struct DynamicRendererMutationReport: Decodable {
    struct Result: Decodable {
        let killed: Int
        let survived: Int
        let unviable: Int
    }

    struct Mutant: Decodable {
        let id: String
        let outcome: String
        let severity: String
        let disposition: String
        let rationale: String
    }

    let schemaVersion: Int
    let auditedSHA: String
    let baseOID: String
    let generatedAt: String
    let command: String
    let toolVersion: String
    let nativeReport: String
    let nativeReportSHA256: String
    let scope: String
    let coveredSymbols: [String]
    let result: Result
    let threshold: DynamicRendererAuditInventory.MutationEvidence.Threshold
    let mutants: [Mutant]
    let passed: Bool
}

private func decodeSeries(at url: URL) throws -> DynamicRendererAuditSeries {
    let series = try JSONDecoder().decode(DynamicRendererAuditSeries.self, from: Data(contentsOf: url))
    guard series.schemaVersion == 1, series.issue == 1026 else { throw AuditCLIError.invalidRecord("invalid PR series") }
    return series
}

private func requiredInventoryPath(for phase: DynamicRendererAuditSeries.Phase) throws -> String {
    guard let inventory = phase.inventory else { throw AuditCLIError.invalidRecord("PR phase has no test inventory") }
    return inventory
}

private func decodeInventory(phase: DynamicRendererAuditSeries.Phase, repositoryRoot: URL) throws -> DynamicRendererAuditInventory {
    let inventory = try JSONDecoder().decode(DynamicRendererAuditInventory.self, from: Data(contentsOf: repositoryRoot.appendingPathComponent(try requiredInventoryPath(for: phase))))
    guard inventory.schemaVersion == 1, inventory.issue == 1026, inventory.pr == phase.number else {
        throw AuditCLIError.invalidRecord("invalid test inventory")
    }
    return inventory
}

private func verifyExactBase(phase: DynamicRendererAuditSeries.Phase, pullRequest: GitHubAuditPullRequest, git: GitRepositoryQuerying, repositoryRoot: URL) throws -> Set<String> {
    let inventory = try decodeInventory(phase: phase, repositoryRoot: repositoryRoot)
    guard inventory.baseCommit == pullRequest.baseRefOID else { throw AuditCLIError.invalidRecord("PR base does not match the series inventory") }
    guard try git.status(arguments: ["fetch", "origin", pullRequest.baseRefOID]) == 0,
          try git.output(arguments: ["rev-parse", pullRequest.baseRefOID]) == pullRequest.baseRefOID else {
        throw AuditCLIError.invalidRecord("cannot fetch the exact PR base")
    }
    guard try git.status(arguments: ["merge-base", "--is-ancestor", pullRequest.baseRefOID, pullRequest.headRefOID]) == 0 else {
        throw AuditCLIError.invalidRecord("PR base is not an ancestor")
    }
    let diff = try git.output(arguments: ["diff", "--name-only", "\(pullRequest.baseRefOID)...\(pullRequest.headRefOID)"])
    return Set(diff.split(separator: "\n").map(String.init).filter { $0.hasPrefix("Sources/") })
}

private func requiredLiveChecks(from pullRequest: GitHubAuditPullRequest) throws -> [DynamicRendererAuditCheckRun] {
    try DynamicRendererBuildAndSuiteGate.requiredLiveCheckNames.map { name in
        let candidates = pullRequest.checks.filter { $0.name == name && $0.headSHA == pullRequest.headRefOID }
        guard let check = try latestCheckRun(candidates) else { throw AuditCLIError.invalidRecord("required check \(name) is missing or bound to another SHA") }
        guard check.status.uppercased() == "COMPLETED", check.conclusion.lowercased() == "success" else {
            throw AuditCLIError.invalidRecord("latest required check \(name) is incomplete or unsuccessful")
        }
        return .init(name: check.name, headSHA: check.headSHA, conclusion: check.conclusion)
    }
}

private func latestCheckRun(_ checks: [GitHubAuditPullRequest.Check]) throws -> GitHubAuditPullRequest.Check? {
    guard checks.isEmpty == false else { return nil }
    let formatter = ISO8601DateFormatter()
    let ordered: [(check: GitHubAuditPullRequest.Check, date: Date)] = try checks.map { check in
        guard check.id > 0, let date = formatter.date(from: check.completedAt ?? check.startedAt) else {
            throw AuditCLIError.invalidRecord("required check run lacks immutable ordering metadata")
        }
        return (check, date)
    }
    return ordered.max { lhs, rhs in
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        return lhs.check.id < rhs.check.id
    }?.check
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

private func validateEvidence(record: DynamicRendererGateRecord, phase: DynamicRendererAuditSeries.Phase, baseOID: String, changedProductionSources: Set<String>, repositoryRoot: URL) throws {
    guard let expectedInventory = phase.inventory else { throw AuditCLIError.invalidRecord("PR phase has no test inventory") }
    let schemaURL = repositoryRoot.appendingPathComponent("plans/dynamic-renderer-gate-record.schema.json")
    let schemaData = try Data(contentsOf: schemaURL)
    let recordData = try JSONEncoder.gateEncoder.encode(record)
    do { try GateRecordSchemaValidator.validate(instanceData: recordData, schemaData: schemaData) }
    catch { throw AuditCLIError.invalidRecord("gate record does not match the tracked schema") }

    let inventory = try decodeInventory(phase: phase, repositoryRoot: repositoryRoot)
    guard inventory.schemaVersion == 1, inventory.issue == 1026, inventory.pr == phase.number, inventory.baseCommit == baseOID else {
        throw AuditCLIError.invalidRecord("test inventory does not bind the current PR base")
    }
    try validateTestMappings(inventory, changedProductionSources: changedProductionSources, repositoryRoot: repositoryRoot)
    guard record.testInventory == expectedInventory else {
        throw AuditCLIError.invalidRecord("record does not bind the tracked inventory")
    }
    guard let mutationPath = record.mutationReport else { return }
    guard mutationPath == inventory.mutationEvidence.report else { throw AuditCLIError.invalidRecord("record does not bind the tracked mutation report") }
    let mutationURL = repositoryRoot.appendingPathComponent(mutationPath)
    let mutationData = try Data(contentsOf: mutationURL)
    let mutationSchemaURL = repositoryRoot.appendingPathComponent("plans/dynamic-renderer-mutation-evidence.schema.json")
    do { try MutationEvidenceSchemaValidator.validate(instanceData: mutationData, schemaData: Data(contentsOf: mutationSchemaURL)) }
    catch { throw AuditCLIError.invalidRecord("mutation report does not match the tracked schema") }
    let mutationReport = try JSONDecoder().decode(DynamicRendererMutationReport.self, from: mutationData)
    try validateMutationReport(mutationReport, inventory: inventory.mutationEvidence, record: record, baseOID: baseOID, repositoryRoot: repositoryRoot)
}

private func validateMutationReport(
    _ report: DynamicRendererMutationReport,
    inventory: DynamicRendererAuditInventory.MutationEvidence,
    record: DynamicRendererGateRecord,
    baseOID: String,
    repositoryRoot: URL
) throws {
    guard report.schemaVersion == 2,
          report.auditedSHA == record.auditedSHA,
          report.baseOID == baseOID,
          DynamicRendererAuditValidation.isSHA(report.auditedSHA),
          DynamicRendererAuditValidation.isSHA(report.baseOID),
          report.scope == inventory.scope,
          Set(report.coveredSymbols) == Set(inventory.coveredSymbols),
          report.coveredSymbols.count == Set(report.coveredSymbols).count,
          report.threshold == inventory.threshold,
          report.passed,
          report.command == "make mutate-scope SOURCES_PATH=\(inventory.scope)",
          report.toolVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
          isRetainedTemporaryPath(report.nativeReport),
          DynamicRendererAuditValidation.isSHA256(report.nativeReportSHA256),
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

    let nativeURL = repositoryRoot.appendingPathComponent(report.nativeReport)
    let nativeData = try Data(contentsOf: nativeURL)
    let nativeMutants = try nativeMutationOutcomes(from: nativeData, expectedScope: report.scope)
    guard sha256Hex(nativeData) == report.nativeReportSHA256,
          Set(report.mutants.map(\.id)).count == report.mutants.count,
          Set(report.mutants.map(\.id)) == Set(nativeMutants.keys),
          report.mutants.allSatisfy({ mutant in
              nativeMutants[mutant.id] == mutant.outcome &&
              ["killed", "survived", "unviable"].contains(mutant.outcome) &&
              ["critical", "high", "medium", "low"].contains(mutant.severity) &&
              ["fixed", "rebutted"].contains(mutant.disposition) &&
              mutant.rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
          }),
          report.mutants.filter({ $0.outcome == "killed" }).count == report.result.killed,
          report.mutants.filter({ $0.outcome == "survived" }).count == report.result.survived,
          report.mutants.filter({ $0.outcome == "unviable" }).count == report.result.unviable,
          report.mutants.filter({ $0.outcome == "unviable" }).allSatisfy({ inventory.phasePolicy.allowedUnviableSeverities.contains($0.severity) })
    else { throw AuditCLIError.invalidRecord("native mutation report digest or complete mutant ledger does not match") }
}

private func isRetainedTemporaryPath(_ path: String) -> Bool {
    path.hasPrefix("tmp/") && path.hasSuffix(".json") && path.contains("..") == false
}

private func sha256Hex(_ data: Data) -> String {
    #if os(Linux)
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    #else
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    #endif
}

private func nativeMutationOutcomes(from data: Data, expectedScope: String) throws -> [String: String] {
    let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    let files = root["files"] as? [String: Any] ?? [:]
    guard files.isEmpty == false else { throw DynamicRendererAuditError.invalidMutationReport }
    var outcomes: [String: String] = [:]
    for (path, value) in files {
        let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard normalized == expectedScope || normalized.hasPrefix("\(expectedScope)/"),
              let file = value as? [String: Any],
              let mutants = file["mutants"] as? [[String: Any]] else { throw DynamicRendererAuditError.invalidMutationReport }
        for mutant in mutants {
            guard let id = mutant["id"] as? String,
                  id.isEmpty == false,
                  let status = mutant["status"] as? String,
                  let outcome = nativeOutcome(status),
                  outcomes.updateValue(outcome, forKey: id) == nil else { throw DynamicRendererAuditError.invalidMutationReport }
        }
    }
    guard outcomes.isEmpty == false else { throw DynamicRendererAuditError.invalidMutationReport }
    return outcomes
}

private func validateTestMappings(_ inventory: DynamicRendererAuditInventory, changedProductionSources: Set<String>, repositoryRoot: URL) throws {
    let mappings = inventory.productionSymbols + inventory.decisionBranches
    guard mappings.isEmpty == false,
          mappings.allSatisfy({ $0.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false && $0.tests.isEmpty == false }),
          Set(mappings.map(\.subject)).count == mappings.count,
          inventory.productionSources.isEmpty == false,
          Set(inventory.productionSources).count == inventory.productionSources.count,
          Set(inventory.productionSources) == changedProductionSources else {
        throw AuditCLIError.invalidRecord("test inventory mappings must be non-empty and unique")
    }
    let discovered = try discoveredTestNames(repositoryRoot: repositoryRoot)
    guard mappings.allSatisfy({ mapping in
        Set(mapping.tests).count == mapping.tests.count && mapping.tests.allSatisfy(discovered.contains)
    }) else {
        throw AuditCLIError.invalidRecord("test inventory references an unknown or duplicate test")
    }
}

private func discoveredTestNames(repositoryRoot: URL) throws -> Set<String> {
    let testsURL = repositoryRoot.appendingPathComponent("Tests", isDirectory: true)
    guard let enumerator = FileManager.default.enumerator(at: testsURL, includingPropertiesForKeys: [.isRegularFileKey]) else {
        throw AuditCLIError.invalidRecord("cannot discover test inventory")
    }
    let suitePattern = try NSRegularExpression(pattern: "(?:struct|final\\s+class|class)\\s+([A-Za-z_][A-Za-z0-9_]*)")
    let functionPattern = try NSRegularExpression(pattern: "@Test[\\s\\S]{0,300}?func\\s+([A-Za-z_][A-Za-z0-9_]*)")
    var names: Set<String> = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
        let source = try String(contentsOf: url, encoding: .utf8)
        let range = NSRange(source.startIndex..., in: source)
        let suites = suitePattern.matches(in: source, range: range)
        for function in functionPattern.matches(in: source, range: range) {
            guard let functionNameRange = Range(function.range(at: 1), in: source),
                  let suite = suites.last(where: { $0.range.location < function.range.location }),
                  let suiteNameRange = Range(suite.range(at: 1), in: source) else { continue }
            names.insert("\(source[suiteNameRange]).\(source[functionNameRange])")
        }
    }
    return names
}

private func nativeOutcome(_ status: String) -> String? {
    switch status.lowercased() {
    case "crash", "killed": "killed"
    case "survived": "survived"
    case "unviable": "unviable"
    default: nil
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
