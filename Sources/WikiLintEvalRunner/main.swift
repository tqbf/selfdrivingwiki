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
    fail("usage: WikiLintEvalRunner inspect|replay|run ...")
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
    fail("unknown command \(command) — expected inspect|replay|run")
}
