import Foundation
import WikiFSCore
import WikiStrategyEval

// WikiStrategyEvalRunner — the opt-in entry point for the LIVE semantic
// evaluation harness (plan Phase 5.3-5.4, AC.7).
//
//   WikiStrategyEvalRunner inspect
//   WikiStrategyEvalRunner run --live \
//     --provider-config-dir ~/Library/Group\ Containers/<your-group-id> \
//     [--scenario characterHistoryAcrossSources|supersededRepositoryDecision|sameEvidenceDifferentDocumentationStrategy|all] \
//     [--output tmp/wiki-strategy-eval/<run>] \
//     [--budget-seconds 1200] [--max-tokens 4000000] [--max-cost 5] \
//     [--keep-fixtures]
//
// `inspect` validates and prints the fixture plan without contacting any
// provider (its output is labeled dryRun). `run --live` executes the real
// configured provider against disposable fixture databases under the output
// directory; without `--live` it refuses, so a live run is always an explicit
// choice. Exit codes: 0 all structural checks passed, 1 at least one failed,
// 2 usage or configuration error.

let standardError = FileHandle.standardError
// Real CLI stdout — the documented AGENTS.md exception for command output.
// Written through FileHandle (mirroring the standardError seam below) rather
// than `print` so the diagnostic_print gate stays meaningful in this target.
let standardOutput = FileHandle.standardOutput

func output(_ line: String) {
    standardOutput.write(Data((line + "\n").utf8))
}

func failUsage(_ message: String) -> Never {
    standardError.write(Data("WikiStrategyEvalRunner: \(message)\n".utf8))
    exit(2)
}

struct Options {
    var live = false
    var providerConfigDirectory: String?
    var scenarios: [String] = []
    var outputDirectory: String?
    var budgetSeconds: Double = 1200
    var maxTokens: Int = 4_000_000
    var maxCost: Double = 5
    var keepFixtures = false
}

func parseArguments(_ argv: [String]) -> Options {
    var options = Options()
    // argv[0] is the command ("run"/"inspect"); flags start at index 1.
    var index = 1
    func value(for flag: String) -> String {
        index += 1
        guard index < argv.count, !argv[index].hasPrefix("--") else {
            failUsage("\(flag) requires a value")
        }
        return argv[index]
    }
    while index < argv.count {
        let argument = argv[index]
        switch argument {
        case "--live": options.live = true
        case "--provider-config-dir": options.providerConfigDirectory = value(for: argument)
        case "--scenario": options.scenarios.append(value(for: argument))
        case "--output": options.outputDirectory = value(for: argument)
        case "--budget-seconds":
            guard let seconds = Double(value(for: argument)), seconds.isFinite, seconds > 0 else {
                failUsage("--budget-seconds needs a positive number")
            }
            options.budgetSeconds = seconds
        case "--max-tokens":
            guard let tokens = Int(value(for: argument)), tokens > 0 else {
                failUsage("--max-tokens needs a positive integer")
            }
            options.maxTokens = tokens
        case "--max-cost":
            guard let cost = Double(value(for: argument)), cost.isFinite, cost > 0 else {
                failUsage("--max-cost needs a positive number")
            }
            options.maxCost = cost
        case "--keep-fixtures": options.keepFixtures = true
        default:
            failUsage("unknown argument \(argument.debugDescription)")
        }
        index += 1
    }
    return options
}

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first
let options = parseArguments(arguments)

switch command {
case "inspect":
    inspectFixtures()
case "run":
    guard options.live else {
        failUsage(
            "refusing to run without --live — a live evaluation contacts your configured provider and spends quota. Pass --live to confirm.")
    }
    guard let providerDirectory = options.providerConfigDirectory else {
        failUsage("--provider-config-dir is required for a live run (your App Group container holding agent-providers.json)")
    }
    await runLive(options: options, providerDirectory: providerDirectory)
default:
    failUsage("usage: WikiStrategyEvalRunner (inspect | run --live --provider-config-dir <dir> [options])")
}

// MARK: - Inspect (dry run: no provider, no database, no process)

func inspectFixtures() -> Never {
    output("WikiStrategyEvalRunner inspect — run kind: dryRun (no provider will be contacted)\n")
    var allValid = true
    for scenario in EvaluationFixtures.all {
        let problems = scenario.validationProblems
        output("Scenario: \(scenario.id.rawValue)")
        output("  Strategy: \(scenario.strategy.name)")
        output("  Batches: \(scenario.batches.map { $0.map(\.filename) })")
        output("  Second leg strategy: \(scenario.secondLegStrategy?.name ?? "(none)")")
        output("  Structural checks: \(scenario.checks.count)")
        output("  Rubric questions: \(scenario.rubric.count)")
        if problems.isEmpty {
            output("  Fixture: valid")
        } else {
            allValid = false
            output("  Fixture: INVALID — \(problems.joined(separator: "; "))")
        }
        output("")
    }
    exit(allValid ? 0 : 2)
}

// MARK: - Live run

func runLive(options: Options, providerDirectory: String) async -> Never {
    #if canImport(WikiFSEngine) && os(macOS)
    let scenarioIDs = resolveScenarioIDs(options.scenarios)
    let outputDirectory = resolveOutputDirectory(options.outputDirectory)
    let configuration = LiveEvaluationConfiguration(
        providerConfigDirectory: URL(fileURLWithPath: providerDirectory.replacingOccurrences(of: "\\ ", with: " "), isDirectory: true),
        outputDirectory: outputDirectory,
        budget: EvaluationBudget(
            maxDuration: .seconds(options.budgetSeconds),
            maxTotalTokens: options.maxTokens,
            maxCost: options.maxCost),
        scenarioIDs: scenarioIDs,
        keepFixtureDirectories: options.keepFixtures)

    let harness = LiveEvaluationHarness(configuration: configuration)
    do {
        let results = try await harness.run()
        output("Run kind: \(results.runKind.rawValue)")
        output("Output: \(outputDirectory.path)")
        for record in results.results {
            let failed = record.evaluation.failedChecks
            output(
                "\(record.metadata.scenarioID.rawValue): \(record.evaluation.passed ? "PASS" : "FAIL")" +
                (record.metadata.error.map { " (run error: \($0))" } ?? "") +
                (failed.isEmpty ? "" : " — \(failed.count) failed check(s)"))
        }
        exit(results.allPassed ? 0 : 1)
    } catch {
        standardError.write(Data("WikiStrategyEvalRunner: live run failed: \(error.localizedDescription)\n".utf8))
        exit(2)
    }
    #else
    failUsage("live evaluation requires macOS (the ACP backend is macOS-only)")
    #endif
}

func resolveScenarioIDs(_ names: [String]) -> [EvaluationScenarioID] {
    guard !names.isEmpty else { return EvaluationScenarioID.allCases }
    var ids: [EvaluationScenarioID] = []
    for name in names {
        if name == "all" { return EvaluationScenarioID.allCases }
        guard let id = EvaluationScenarioID(rawValue: name) else {
            failUsage("unknown scenario \(name.debugDescription) — expected one of \(EvaluationScenarioID.allCases.map(\.rawValue).joined(separator: ", ")) or all")
        }
        ids.append(id)
    }
    return ids
}

func resolveOutputDirectory(_ explicit: String?) -> URL {
    if let explicit {
        return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath, isDirectory: true)
    }
    let stamp = ISO8601DateFormatter()
    stamp.formatOptions = [.withInternetDateTime]
    let name = stamp.string(from: Date()).replacingOccurrences(of: ":", with: "")
    // Default under the project's gitignored tmp/ (the caller normally runs
    // from the repository root; scratch files belong there, not in /tmp).
    return URL(fileURLWithPath: "tmp/wiki-strategy-eval/\(name)", isDirectory: true)
}
