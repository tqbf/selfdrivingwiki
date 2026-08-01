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

struct FileGateRecords: GateRecordReading, GateRecordWriting {
    func records(at directory: URL) throws -> [DynamicRendererGateRecord] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(DynamicRendererGateRecord.self, from: Data(contentsOf: $0)) }
    }
    func write(_ record: DynamicRendererGateRecord, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(record.auditedSHA).json")
        try JSONEncoder.gateEncoder.encode(record).write(to: destination, options: .atomic)
    }
}

struct SystemAuditClock: AuditClock {
    func recordedAt() -> String { ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: "Z", with: "+00:00") }
}

struct ProcessGitHubPullRequestQuery: GitHubPullRequestQuerying {
    func pullRequest(head: String) throws -> GitHubAuditPullRequest {
        let result = try ProcessRunner.run(executable: "/usr/bin/env", arguments: ["gh", "pr", "view", "--head", head, "--json", "headRefName,headRefOid,baseRefName,baseRefOid,title,statusCheckRollup,reviews"])
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
            try verify(seriesPath: series, evidenceDirectory: evidence, git: ProcessGitRepositoryQuery(), github: ProcessGitHubPullRequestQuery(), records: FileGateRecords())
        case "build-suite":
            guard let head = options["--head"], let evidence = options["--evidence"], DynamicRendererAuditValidation.isSHA(head) else { throw AuditCLIError.usage }
            try buildSuite(head: head, evidenceDirectory: evidence, git: ProcessGitRepositoryQuery(), records: FileGateRecords(), clock: SystemAuditClock())
        default: throw AuditCLIError.usage
        }
    }

    static func verify(seriesPath: String, evidenceDirectory: String, git: GitRepositoryQuerying, github: GitHubPullRequestQuerying, records: GateRecordReading) throws {
        let series = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: seriesPath))) as? [String: Any] ?? [:]
        guard series["schemaVersion"] as? Int == 1 else { throw AuditCLIError.invalidRecord("invalid PR series") }
        guard try git.output(arguments: ["status", "--porcelain"]).isEmpty else { throw DynamicRendererAuditError.dirtyCheckout }
        let branch = try git.output(arguments: ["branch", "--show-current"])
        let first = try github.pullRequest(head: branch)
        guard first.headRefName == branch, first.baseRefName == "main", first.title.range(of: "^(feat|fix|test|chore|docs|refactor)(\\([^)]+\\))?: .+", options: .regularExpression) != nil else { throw AuditCLIError.invalidRecord("PR metadata does not bind this branch/base/title") }
        guard try git.status(arguments: ["merge-base", "--is-ancestor", first.baseRefOID, first.headRefOID]) == 0 else { throw AuditCLIError.invalidRecord("PR base is not an ancestor") }
        _ = try git.output(arguments: ["diff", "--name-only", "\(first.baseRefOID)...\(first.headRefOID)"])
        guard first.checks.isEmpty == false, first.checks.allSatisfy({ $0.headSHA == first.headRefOID && $0.conclusion.lowercased() == "success" }) else { throw AuditCLIError.invalidRecord("checks are incomplete or bound to another SHA") }
        guard let approval = first.reviews.last(where: { $0.state.uppercased() == "APPROVED" && $0.commitSHA == first.headRefOID }) else { throw AuditCLIError.invalidRecord("missing current-head approval") }
        let evidenceURL = URL(fileURLWithPath: evidenceDirectory)
        for record in try records.records(at: evidenceURL) {
            do { try record.validate() }
            catch { throw AuditCLIError.invalidRecord("invalid record: \(error)") }
            guard record.auditedSHA == first.headRefOID, record.baseRefOID == first.baseRefOID, record.review == .approved(author: approval.author, commitSHA: approval.commitSHA) else { throw AuditCLIError.invalidRecord("evidence does not bind live PR") }
        }
        let second = try github.pullRequest(head: branch)
        guard second == first else { throw AuditCLIError.invalidRecord("PR changed during audit") }
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
        let record = DynamicRendererGateRecord(schemaVersion: 1, auditedSHA: head, headRefOID: head, baseRefName: "main", baseRefOID: baseOID, cleanCheckout: true, requiredCheckRuns: [.init(name: "local-build-suite", headSHA: head, conclusion: "success")], review: .noReview, commands: results, testInventory: "plans/dynamic-renderers-pr1-test-inventory.json", mutationReport: "tmp/dynamic-renderer-pr1-mutation-report.json", findings: [], recordedAt: clock.recordedAt())
        try record.validate()
        try records.write(record, to: URL(fileURLWithPath: evidenceDirectory, isDirectory: true))
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
