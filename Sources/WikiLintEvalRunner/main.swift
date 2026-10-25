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
    // hard error, and with --live the rollout prerequisites are checked
    // and named — a missing provider access, budget approval, or human
    // rubric blocks the gate instead of pretending.
    guard arguments.contains("--live") else {
        fail("run requires --live — live evaluation spends real provider quota")
    }
    guard arguments.contains("--gate") else {
        fail("usage: run --live --gate --manifest <path> [--budget-file <path>]")
    }
    // Rollout prerequisites (plan §6.14): provider access, an operator
    // budget, a ready daemon, and human rubric review are observable
    // execution prerequisites. This runner is the deterministic harness —
    // the live trials it would drive are gated OFF until the operator
    // confirms provider/model/tier and budget. Report honestly and exit
    // nonzero: the gate has NOT passed.
    out("LIVE GATE BLOCKED: rollout prerequisites are not yet confirmed —")
    out("  1. provider/model and the lowest production effort tier confirmed by the operator")
    out("  2. total evaluation budget approved by the operator")
    out("  3. human rubric reviewers available for judgment fixtures")
    out("No provider calls were made.")
    exit(3)

default:
    fail("unknown command \(command) — expected inspect|replay|manifest|run")
}
