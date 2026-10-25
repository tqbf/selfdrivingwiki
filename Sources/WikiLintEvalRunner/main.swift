import Foundation
import WikiFSCore
import WikiLintEval

// WikiLintEvalRunner — the opt-in CLI over the lint evaluation harness
// (plan phase 6). NEVER wired into CI: `run --live` spends real provider
// quota and is refused without the explicit flag.
//
//   inspect   --manifest <path>
//       Decode the manifest, print the group/split shape and the canonical
//       digest the shipped gate resource must freeze.
//   replay    --manifest <path> --recorded <run.json>
//       Deterministic scoring of a RECORDED run (observed outcomes +
//       applied hunks) — no provider calls, CI-safe.
//   manifest [--approval id=..,provider=..,model=..,effort=..[,revision=..]]...
//            [--report-sha256 <hex> --rubric-reviewer <name>
//             --decided-at <ISO-8601> --bail-trials <text>]
//            [--output tmp/<file>.json]
//       Mint a candidate shipped approval manifest (LintAcceptance/
//       manifest.json). The pipeline block is computed from THIS build.
//       Approvals require all four evidence flags; "enabled" under the W5a
//       ladder is simply whether approval rows exist — unevaluated
//       configurations run as staged proposals, so there is no --enable
//       flag. Prints to stdout, or writes to an explicit path under tmp/ —
//       never the app bundle or App Group. The operator reviews the
//       candidate and commits it.
//   run --live --gate --manifest <path> ...
//       The live acceptance gate. Refuses without --live; with --live it
//      still reports the rollout prerequisites that are missing (provider
//      access, operator budget, human rubric) instead of pretending.

// Output through FileHandle (mirroring WikiStrategyEvalRunner's seams)
// rather than `print` so the diagnostic_print gate stays meaningful in
// this target.
let standardOutput = FileHandle.standardOutput
let standardError = FileHandle.standardError

func out(_ line: String) {
    standardOutput.write(Data((line + "\n").utf8))
}

func fail(_ message: String) -> Never {
    standardError.write(Data("wikictl-eval: \(message)\n".utf8))
    exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("usage: WikiLintEvalRunner inspect|replay|manifest|run ...")
}

/// The `wikid` host-mode argv head. A STATIC (lazily initialized) value on a
/// type — a top-level `let` declared after the dispatch switch reads as ""
/// when the switch runs before the declaration executes.
private enum LiveGateHostMode {
    static let driver = "lint-eval-driver"
}

func loadManifest(path: String) -> LintEvalFixtureManifest {
    guard let data = FileManager.default.contents(atPath: path) else {
        fail("manifest not readable at \(path)")
    }
    do {
        return try LintEvalFixtureManifest.load(from: data)
    } catch {
        fail("manifest decode failed: \(error)")
    }
}

/// Every value following `flag` (repeatable flags).
func values(of flag: String, in arguments: [String]) -> [String] {
    var found: [String] = []
    for (index, argument) in arguments.enumerated() where argument == flag {
        guard arguments.indices.contains(index + 1) else { fail("\(flag) needs a value") }
        found.append(arguments[index + 1])
    }
    return found
}

/// The single value following `flag`, or nil when absent.
func value(of flag: String, in arguments: [String]) -> String? {
    let found = values(of: flag, in: arguments)
    guard found.count <= 1 else { fail("\(flag) given more than once") }
    return found.first
}

/// The `manifest` subcommand: assemble, validate, and emit a candidate.
func emitAcceptanceManifest(arguments: [String]) {
    let known: Set<String> = [
        "--approval", "--report-sha256", "--rubric-reviewer", "--decided-at",
        "--bail-trials", "--output",
    ]
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        guard known.contains(argument) else { fail("manifest: unknown argument \(argument)") }
        index += 2
    }

    let pipeline: LintAcceptanceManifest.Pipeline
    do {
        pipeline = try LintAcceptanceManifest.Pipeline.live()
    } catch {
        fail("manifest: cannot compute the build pipeline: \(error)")
    }

    let approvals = values(of: "--approval", in: arguments).map { spec in
        approvalRow(spec: spec, pipeline: pipeline)
    }

    let evidenceFlags = [
        value(of: "--report-sha256", in: arguments),
        value(of: "--rubric-reviewer", in: arguments),
        value(of: "--decided-at", in: arguments),
        value(of: "--bail-trials", in: arguments),
    ]
    let evidence: LintAcceptanceManifest.Evidence?
    if evidenceFlags.allSatisfy({ $0 == nil }) {
        evidence = nil
    } else {
        guard let report = evidenceFlags[0], let reviewer = evidenceFlags[1],
              let decided = evidenceFlags[2], let bail = evidenceFlags[3] else {
            fail("manifest: evidence needs all of --report-sha256 --rubric-reviewer --decided-at --bail-trials")
        }
        guard report.count == 64, report.allSatisfy(\.isHexDigit) else {
            fail("manifest: --report-sha256 must be a 64-character hex digest")
        }
        guard reviewer.trimmingCharacters(in: .whitespaces).isEmpty == false else {
            fail("manifest: --rubric-reviewer must not be blank")
        }
        guard let decidedAt = ISO8601DateFormatter().date(from: decided) else {
            fail("manifest: --decided-at must be ISO-8601 (e.g. 2026-10-24T12:00:00Z)")
        }
        evidence = LintAcceptanceManifest.Evidence(
            reportSHA256: report.lowercased(), rubricReviewer: reviewer,
            decidedAt: decidedAt, bailTrials: bail)
    }

    let manifest = LintAcceptanceManifest(
        pipeline: pipeline, evidence: evidence, approvals: approvals)
    if let problem = manifest.structuralProblem {
        fail("manifest: candidate is invalid: \(problem)")
    }
    let data: Data
    do {
        data = try manifest.encoded() + Data("\n".utf8)
    } catch {
        fail("manifest: encode failed: \(error)")
    }

    guard let output = value(of: "--output", in: arguments) else {
        standardOutput.write(data)
        return
    }
    let target = tmpOutputURL(output)
    do {
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    } catch {
        fail("manifest: write to \(target.path) failed: \(error)")
    }
    out("wrote candidate manifest to \(target.path)")
    out("review it, then copy it to Sources/WikiFSCore/Resources/LintAcceptance/manifest.json and commit")
}

/// Parse one `id=..,provider=..,model=..,effort=..[,revision=..]` row and
/// stamp it with the full acceptance key for traceability.
func approvalRow(
    spec: String, pipeline: LintAcceptanceManifest.Pipeline
) -> LintAcceptanceManifest.Approval {
    var fields: [String: String] = [:]
    for pair in spec.split(separator: ",") {
        let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[1].isEmpty == false else {
            fail("--approval: malformed field \(pair) in \(spec)")
        }
        guard ["id", "provider", "model", "effort", "revision"].contains(parts[0]) else {
            fail("--approval: unknown field \(parts[0]) in \(spec)")
        }
        guard fields[parts[0]] == nil else { fail("--approval: duplicate field \(parts[0]) in \(spec)") }
        fields[parts[0]] = parts[1]
    }
    guard let id = fields["id"], let provider = fields["provider"],
          let model = fields["model"], let effort = fields["effort"] else {
        fail("--approval needs id, provider, model, and effort: \(spec)")
    }
    let revision = fields["revision"]
    let key = LintAcceptanceKey.digest(LintAcceptanceKey.Components(
        provider: provider, model: model, modelRevision: revision, effort: effort,
        promptSHA256: pipeline.promptSHA256,
        detectorRevision: pipeline.detectorRevision,
        fixtureDigest: pipeline.fixtureDigest))
    return LintAcceptanceManifest.Approval(
        id: id, provider: provider, model: model, effort: effort,
        evaluatedRevision: revision, acceptanceKeySHA256: key)
}

/// Resolve `--output` and refuse anything outside `<cwd>/tmp/` — the
/// runner never writes into the app bundle or the App Group.
func tmpOutputURL(_ path: String) -> URL {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let tmp = cwd.appendingPathComponent("tmp", isDirectory: true)
        .standardizedFileURL.resolvingSymlinksInPath()
    let target = URL(fileURLWithPath: path, relativeTo: cwd)
        .standardizedFileURL.resolvingSymlinksInPath()
    guard target.path.hasPrefix(tmp.path + "/") else {
        fail("--output must be a path under \(tmp.path)/ (got \(target.path))")
    }
    return target
}

switch command {
case "inspect":
    let pathIndex = arguments.firstIndex(of: "--manifest").flatMap { arguments.index(after: $0) }
    guard let pathIndex, arguments.indices.contains(pathIndex) else {
        fail("usage: inspect --manifest <path>")
    }
    let manifest = loadManifest(path: arguments[pathIndex])
    let digest = try! manifest.digest() // swiftlint:disable:this force_try
    out("manifest version \(manifest.manifestVersion)")
    out("tuning fixtures: \(manifest.tuning.count)")
    for fixture in manifest.tuning {
        out("  - \(fixture.id) [\(fixture.kind)] seeds: \(fixture.seededDefects.map(\.defectClass).joined(separator: ","))")
    }
    out("held-out fixtures: \(manifest.heldOut.count)")
    for fixture in manifest.heldOut {
        out("  - \(fixture.id) [\(fixture.kind)] seeds: \(fixture.seededDefects.map(\.defectClass).joined(separator: ","))")
    }
    out("canonical digest: \(digest)")
    out("freeze this digest into the shipped LintGateFixtureManifest.json")

case "replay":
    let manifestIndex = arguments.firstIndex(of: "--manifest").flatMap { arguments.index(after: $0) }
    let recordedIndex = arguments.firstIndex(of: "--recorded").flatMap { arguments.index(after: $0) }
    guard let manifestIndex, arguments.indices.contains(manifestIndex),
          let recordedIndex, arguments.indices.contains(recordedIndex) else {
        fail("usage: replay --manifest <path> --recorded <run.json>")
    }
    let manifest = loadManifest(path: arguments[manifestIndex])
    guard let runData = FileManager.default.contents(atPath: arguments[recordedIndex]) else {
        fail("recorded run not readable at \(arguments[recordedIndex])")
    }
    // The recorded-run shape mirrors ObservedRun per fixture id.
    struct RecordedRun: Decodable {
        struct Entry: Decodable {
            let fixtureID: String
            let confirmedClasses: [String]
            let unresolvedClasses: [String]
            let validAsWrittenClasses: [String]
            let repairedClasses: [String]
            let coverageFailed: Bool
        }
        let entries: [Entry]
    }
    let recorded: RecordedRun
    do {
        recorded = try JSONDecoder().decode(RecordedRun.self, from: runData)
    } catch {
        fail("recorded run decode failed: \(error)")
    }
    var failures = 0
    for entry in recorded.entries {
        guard let fixture = (manifest.tuning + manifest.heldOut).first(where: { $0.id == entry.fixtureID }) else {
            fail("recorded entry names unknown fixture \(entry.fixtureID)")
        }
        let observed = LintEvalScoring.ObservedRun(
            confirmedClasses: Set(entry.confirmedClasses),
            unresolvedClasses: Set(entry.unresolvedClasses),
            validAsWrittenClasses: Set(entry.validAsWrittenClasses),
            repairedClasses: Set(entry.repairedClasses),
            coverageFailed: entry.coverageFailed)
        let score = LintEvalScoring.score(fixture: fixture, run: observed)
        let status = score.passed ? "PASS" : "FAIL"
        out("\(status) \(fixture.id)")
        for reason in score.failureReasons { out("      - \(reason)") }
        if !score.passed { failures += 1 }
    }
    out("\(failures) failing fixture(s)")
    exit(failures == 0 ? 0 : 1)

case "manifest":
    emitAcceptanceManifest(arguments: Array(arguments.dropFirst()))

case "run":
    // The live gate. Refusal is the DEFAULT: without --live this is a
    // hard error. With --live --gate the driver resolves the evaluated
    // configuration from the operator's provider configuration and runs
    // the canonical fixture suite through the REAL coordinator path;
    // every missing prerequisite is NAMED and the run stops before any
    // provider call.
    guard arguments.contains("--live") else {
        fail("run requires --live — live evaluation spends real provider quota")
    }
    guard arguments.contains("--gate") else {
        fail("usage: run --live --gate --manifest <path> [--provider <id>] [--model <id>] [--eval-group <id>] [--bail-trials <n>] [--group-runs <n>] [--output tmp/<dir>]")
    }
    #if canImport(WikiFSEngine) && os(macOS)
    await runLiveGate(arguments: Array(arguments.dropFirst()))
    #else
    fail("the live gate requires macOS (the ACP backend is macOS-only)")
    #endif

default:
    fail("unknown command \(command) — expected inspect|replay|manifest|run")
}

// MARK: - The live gate (W3)

#if canImport(WikiFSEngine) && os(macOS)
/// The wikid binary that hosts the eval driver: `LINT_EVAL_HOST_BIN` (a
/// testing override), then siblings of THIS executable (the same SwiftPM
/// products directory), then the common .build layouts.
func wikidBinaryPath() -> String? {
    if let override = ProcessInfo.processInfo.environment["LINT_EVAL_HOST_BIN"],
       FileManager.default.isExecutableFile(atPath: override) {
        return override
    }
    var candidates: [URL] = []
    if let selfURL = Bundle.main.executableURL {
        candidates.append(selfURL.deletingLastPathComponent()
            .appendingPathComponent("wikid", isDirectory: false))
    }
    for relative in [
        ".build/debug/wikid",
        ".build/out/Products/Debug/wikid",
        ".build/arm64-apple-macosx/debug/wikid",
    ] {
        candidates.append(URL(fileURLWithPath: relative, relativeTo: URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)))
    }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }?.path
}

/// Resolve the live-gate arguments, spawn `wikid lint-eval-driver` (the only
/// process that can boot the eval daemon substrate), poll the gate report it
/// writes, and exit with the AC.13 gate verdict (0 PASSED / 1 FAILED / 2
/// usage error / 3 blocked prerequisite).
func runLiveGate(arguments rawArguments: [String]) async -> Never {
    // `--live` / `--gate` are the boolean consent flags; every other flag
    // takes a value.
    let arguments = rawArguments.filter { $0 != "--live" && $0 != "--gate" }
    let known: Set<String> = [
        "--manifest", "--provider", "--model", "--provider-config-dir",
        "--eval-group", "--bail-trials", "--group-runs", "--output",
        "--wall-clock-hours",
    ]
    var index = 0
    while index < arguments.count {
        guard known.contains(arguments[index]) else {
            fail("run: unknown argument \(arguments[index])")
        }
        guard arguments.indices.contains(index + 1) else {
            fail("\(arguments[index]) needs a value")
        }
        index += 2
    }
    func value(_ flag: String) -> String? {
        guard let at = arguments.firstIndex(of: flag),
              arguments.indices.contains(at + 1) else { return nil }
        return arguments[at + 1]
    }

    // The canonical manifest is baked into this target; --manifest (when
    // given) must decode to the SAME canonical digest — the gate runs the
    // frozen fixtures or nothing.
    let canonical = try! LintEvalCanonicalFixtures.loadGateManifest() // swiftlint:disable:this force_try
    let canonicalDigest = try! canonical.digest() // swiftlint:disable:this force_try
    if let manifestPath = value("--manifest") {
        let supplied = loadManifest(path: manifestPath)
        guard try! supplied.digest() == canonicalDigest else { // swiftlint:disable:this force_try
            fail("--manifest does not match this build's canonical gate fixtures")
        }
    }

    // The operator's REAL provider-config directory: the running daemon's
    // App Group container by default (read-only), overridable for tooling.
    let providerConfigDirectory: URL
    if let dir = value("--provider-config-dir") {
        providerConfigDirectory = URL(
            fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    } else {
        do {
            providerConfigDirectory = try DatabaseLocation.appGroupContainerDirectory()
        } catch {
            fail("provider config: cannot resolve the App Group container: \(error)")
        }
    }

    // The eval container is a DEDICATED App Group directory — disposable
    // wikis live only there, never beside operator wikis.
    let evalGroupID = value("--eval-group") ?? "group.eval.selfdrivingwiki.lintgate"
    let outputDirectory: URL
    if let output = value("--output") {
        outputDirectory = tmpOutputURL(output)
    } else {
        let stamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        outputDirectory = tmpOutputURL("tmp/wiki-lint-eval/\(stamp)")
    }
    let wallClockHours = value("--wall-clock-hours").flatMap { Double($0) } ?? 8

    let childArguments = [
        LiveGateHostMode.driver,
        "--provider", value("--provider") ?? "zai",
        "--model", value("--model") ?? "GLM 5.3 Flash",
        "--provider-config-dir", providerConfigDirectory.path,
        "--eval-group", evalGroupID,
        "--output", outputDirectory.path,
        "--bail-trials", value("--bail-trials") ?? "20",
        "--group-runs", value("--group-runs") ?? "3",
        "--wall-clock-hours", String(wallClockHours),
    ]

    out("live gate: provider '\(value("--provider") ?? "zai")' model '\(value("--model") ?? "GLM 5.3 Flash")' @ lowest advertised effort")
    out("live gate: provider config (read-only): \(providerConfigDirectory.path)")
    out("live gate: eval container: \(evalGroupID)")
    out("live gate: artifacts: \(outputDirectory.path)")

    guard let wikidPath = wikidBinaryPath() else {
        fail("live gate: cannot locate the wikid binary — build it first (make build)")
    }
    out("live gate: driver host: \(wikidPath)")
    do {
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true)
    } catch {
        fail("live gate: cannot create the output directory \(outputDirectory.path): \(error)")
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: wikidPath)
    process.arguments = childArguments
    // The child must resolve its App Group to the EVAL container from
    // process start (static identifier resolution happens at first access).
    // Set leg 1 in THIS process; the child inherits it. (An explicit
    // `process.environment` replacement triggered the system's
    // "An XPC Service cannot be run directly." refusal — inherited env
    // does not.)
    setenv("WIKI_APP_GROUP_ID", evalGroupID, 1)
    // The child's stdout/stderr ARE the operator's progress trail and
    // preflight verdicts — inherit this terminal; no pipe to drain.
    do {
        try process.run()
    } catch {
        fail("live gate: could not launch the driver host at \(wikidPath): \(error)")
    }

    // Non-blocking wait (repo rule: never waitUntilExit): termination
    // handler + continuation, raced against a generous wall clock (the
    // child enforces its own ceiling; this adds a 1-hour grace).
    let reportURL = outputDirectory.appendingPathComponent("gate-report.json")
    let waitTask = Task {
        try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
                    if !process.isRunning {
                        cont.resume(returning: process.terminationStatus)
                        return
                    }
                    process.terminationHandler = { handler in
                        cont.resume(returning: handler.terminationStatus)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(wallClockHours * 3600 + 3600))
                throw LiveGateTimeout()
            }
            let status: Int32
            if let next = try await group.next() {
                status = next
            } else {
                throw LiveGateTimeout()
            }
            group.cancelAll()
            return status
        }
    }

    // Progress trail: the report's executed-trial count while the child runs.
    while !Task.isCancelled, process.isRunning {
        // A cancelled poll sleep ends the loop on the next check; nothing
        // to report.
        // swiftlint:disable:next silent_try_optional
        try? await Task.sleep(for: .seconds(30))
        guard process.isRunning, let data = FileManager.default.contents(atPath: reportURL.path),
              let trialCount = liveGateExecutedTrials(from: data) else { continue }
        standardOutput.write(Data("live gate: \(trialCount) trial(s) recorded…\n".utf8))
    }
    var exitStatus = process.terminationStatus
    let result = await waitTask.result
    // A wait-task failure (timeout race lost) falls back to the observed
    // termination status.
    // swiftlint:disable:next silent_try_optional
    exitStatus = (try? result.get()) ?? exitStatus

    // The child streams the verdict; print the report summary from disk.
    if let data = FileManager.default.contents(atPath: reportURL.path) {
        printLiveGateSummary(data)
    }
    exit(exitStatus)
}

struct LiveGateTimeout: Error {}

/// Pull `executedTrials` out of a partially-written gate report (the child
/// rewrites the file after every trial). A partially-written file reads as
/// "no count yet" — the poll simply tries again.
func liveGateExecutedTrials(from data: Data) -> Int? {
    // swiftlint:disable:next silent_try_optional
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let count = json["executedTrials"] as? Int else { return nil }
    return count
}

/// Print the gate report summary from the JSON the driver wrote.
func printLiveGateSummary(_ data: Data) {
    let json: [String: Any]
    do {
        guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            out("gate report: JSON is not an object at the output directory")
            return
        }
        json = parsed
    } catch {
        out("gate report: unreadable JSON at the output directory (\(error))")
        return
    }
    out("")
    out("GATE VERDICT: \(json["verdict"] as? String ?? "unknown")")
    if let reasons = json["blockingReasons"] as? [String], !reasons.isEmpty {
        for reason in reasons { out("  - \(reason)") }
    }
    if let executed = json["executedTrials"] as? Int,
       let planned = json["plannedTrials"] as? Int {
        out("trials: \(executed)/\(planned) executed; wall clock \(json["wallClockConsumedSeconds"] as? Double ?? 0)s; rate-limit retries \(json["rateLimitRetries"] as? Int ?? 0)")
    }
    if let groups = json["groups"] as? [[String: Any]] {
        for group in groups {
            out("  \(group["fixtureID"] as? String ?? "?"): \(group["passed"] as? Int ?? 0)/\(group["trials"] as? Int ?? 0) passed")
        }
    }
    if let classScores = json["classScores"] as? [[String: Any]] {
        for line in classScores {
            let seeded = line["seeded"] as? Int ?? 0
            let hits = line["hits"] as? Int ?? 0
            let recall = seeded == 0 ? 0 : Double(hits) / Double(seeded)
            out("  class \(line["defectClass"] as? String ?? "?"): seeded \(seeded), hits \(hits), false confirmed \(line["falseConfirmed"] as? Int ?? 0), recall \(String(format: "%.2f", recall))")
        }
    }
    out("human rubric judgment: \(json["humanRubricSections"] as? String ?? "PENDING OPERATOR")")
    if let metadata = json["metadata"] as? [String: Any],
       let acceptanceKey = metadata["acceptanceKeySHA256"] as? String {
        out("acceptance key: \(acceptanceKey)")
    }
}
#endif
