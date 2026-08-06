// pattern: Imperative Shell
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct LocalGit: GitRepositoryQuerying {
    func currentHead() async throws -> String { try await text("git rev-parse HEAD") }
    func currentBranch() async throws -> String { try await text("git branch --show-current") }
    func isClean() async throws -> Bool { try await text("git status --porcelain").isEmpty }
    func isAncestor(_ ancestor: String, _ descendant: String) async throws -> Bool { (try await run("git merge-base --is-ancestor \(ancestor) \(descendant)", environment: [:])).exitStatus == 0 }
    func run(_ command: String, environment: [String: String]) async throws -> AuditCommandResult { let status = try await status(command, environment: environment); return AuditCommandResult(command: command, exitStatus: status) }
    private func text(_ command: String) async throws -> String { let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/zsh"); process.arguments = ["-lc", command]; let output = Pipe(); process.standardOutput = output; try process.run(); let status = try await wait(process); guard status == 0 else { throw DynamicRendererAuditError.commandFailed(command) }; return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    private func status(_ command: String, environment: [String: String]) async throws -> Int32 { let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/zsh"); process.arguments = ["-lc", command]; process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }; try process.run(); return try await wait(process) }
    private func wait(_ process: Process) async throws -> Int32 { try await withCheckedThrowingContinuation { continuation in process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) } } }
}
struct GitHubCLI: GitHubPullRequestQuerying {
    private struct Response: Decodable { let title: String; let headRefName: String; let headRefOid: String; let baseRefName: String; let baseRefOid: String; let reviews: [Review]; let statusCheckRollup: [Check]?
        struct Review: Decodable { let state: String; let commit: Commit?; struct Commit: Decodable { let oid: String } }
        struct Check: Decodable { let name: String }
    }
    func pullRequest(headRefName: String) async throws -> PullRequestSnapshot {
        let text = try await output("gh pr view \(headRefName) --json title,headRefName,headRefOid,baseRefName,baseRefOid,reviews,statusCheckRollup")
        let response = try JSONDecoder().decode(Response.self, from: Data(text.utf8))
        let approvals = response.reviews.filter { $0.state == "APPROVED" }.compactMap { $0.commit?.oid }
        return PullRequestSnapshot(title: response.title, headRefName: response.headRefName, headRefOid: response.headRefOid, baseRefName: response.baseRefName, baseRefOid: response.baseRefOid, requiredCheckNames: response.statusCheckRollup?.map(\.name) ?? [], checkRunHeadOIDs: (response.statusCheckRollup ?? []).map { _ in response.headRefOid }, approvalCommitOIDs: approvals)
    }
    private func output(_ command: String) async throws -> String { let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/zsh"); process.arguments = ["-lc", command]; let pipe = Pipe(); process.standardOutput = pipe; try process.run(); let status = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) } }; guard status == 0 else { throw DynamicRendererAuditError.githubDrift }; return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) }
}

enum Main { static func main() async { do { let arguments = Array(CommandLine.arguments.dropFirst()); guard let command = arguments.first else { throw DynamicRendererAuditError.invalidArguments }; let evidence = URL(fileURLWithPath: value("--evidence", in: arguments) ?? ""); let git = LocalGit(); let store = FileGateRecordStore(); let auditor = DynamicRendererPRSeriesAuditor(git: git, github: GitHubCLI(), reader: store, writer: store, clock: SystemAuditClock()); switch command { case "verify": let seriesURL = URL(fileURLWithPath: value("--series", in: arguments) ?? ""); let series = try JSONDecoder().decode(PRSeries.self, from: Data(contentsOf: seriesURL)); try GateRecordSchemaValidator.validateSchema(at: URL(fileURLWithPath: "plans/dynamic-renderer-gate-record.schema.json")); try await auditor.verify(series: series, head: try await git.currentHead(), evidenceDirectory: evidence); case "build-suite": guard let head = value("--head", in: arguments) else { throw DynamicRendererAuditError.invalidArguments }; try await auditor.buildSuite(head: head, evidenceDirectory: evidence, inventoryPath: "plans/dynamic-renderers-phase5-webview-test-inventory.json"); default: throw DynamicRendererAuditError.invalidArguments }; } catch { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1) } } }

Task { await Main.main() }
dispatchMain()
private func value(_ flag: String, in arguments: [String]) -> String? { guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }; return arguments[index + 1] }
