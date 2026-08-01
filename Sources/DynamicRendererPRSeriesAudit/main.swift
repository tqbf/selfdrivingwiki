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

private protocol GitRepositoryQuerying {
    func output(arguments: [String]) throws -> String
    func status(arguments: [String]) throws -> Int32
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

private enum DynamicRendererPRSeriesAuditMain {
    static func run(arguments: [String]) throws {
        guard let subcommand = arguments.first else { throw AuditCLIError.usage }
        let options = Dictionary(uniqueKeysWithValues: stride(from: 1, to: arguments.count - 1, by: 2).map { (arguments[$0], arguments[$0 + 1]) })
        switch subcommand {
        case "verify":
            guard let series = options["--series"], let evidence = options["--evidence"] else { throw AuditCLIError.usage }
            try verify(seriesPath: series, evidenceDirectory: evidence)
        case "build-suite":
            guard let head = options["--head"], let evidence = options["--evidence"], DynamicRendererAuditValidation.isSHA(head) else { throw AuditCLIError.usage }
            try buildSuite(head: head, evidenceDirectory: evidence)
        default: throw AuditCLIError.usage
        }
    }

    private static func verify(seriesPath: String, evidenceDirectory: String) throws {
        _ = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: seriesPath)))
        let git = ProcessGitRepositoryQuery()
        guard try git.output(arguments: ["status", "--porcelain"]).isEmpty else { throw DynamicRendererAuditError.dirtyCheckout }
        let evidenceURL = URL(fileURLWithPath: evidenceDirectory)
        let records = try FileManager.default.contentsOfDirectory(at: evidenceURL, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        for url in records {
            let record = try JSONDecoder().decode(DynamicRendererGateRecord.self, from: Data(contentsOf: url))
            do { try record.validate() }
            catch { throw AuditCLIError.invalidRecord("\(url.lastPathComponent): \(error)") }
        }
    }

    private static func buildSuite(head: String, evidenceDirectory: String) throws {
        let git = ProcessGitRepositoryQuery()
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
        let record = DynamicRendererGateRecord(schemaVersion: 1, auditedSHA: head, headRefOID: head, baseRefName: "main", baseRefOID: baseOID, cleanCheckout: true, commands: results, testInventory: "plans/dynamic-renderers-pr1-test-inventory.json", mutationReport: nil, findings: [], recordedAt: ISO8601DateFormatter().string(from: Date()))
        try record.validate()
        let directory = URL(fileURLWithPath: evidenceDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(head).json")
        try JSONEncoder.gateEncoder.encode(record).write(to: destination, options: .atomic)
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
