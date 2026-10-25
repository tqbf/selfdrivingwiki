import Foundation
import WikiDaemonContract
import WikiFSCore
import WikiFSEngine
import WikiLintEval

/// The `wikid lint-eval-driver …` host mode: the ONLY process that can boot
/// the eval daemon substrate (the daemon components are internal to this
/// module and must never cross a wire). The runner executable resolves this
/// binary, spawns it with the gate flags, and reads the gate report the
/// driver writes under the output directory.
///
/// The host boots the substrate over the EVAL container, runs the driver
/// engine to completion (per-trial disposable wikis, REAL coordinator
/// dispatch, capture, gate report), and exits with the AC.13 verdict code
/// (0 PASSED / 1 FAILED / 2 usage error / 3 blocked prerequisite).
public enum LintEvalDriverHost {

    public static let modeArgument = "lint-eval-driver"

    /// Returns the process exit code when `arguments` requests the driver
    /// mode, or `nil` when this is an ordinary daemon launch.
    public static func runIfRequested(
        arguments: [String]
    ) async -> Int32? {
        guard arguments.first == modeArgument else { return nil }
        do {
            let configuration = try parseConfiguration(Array(arguments.dropFirst()))
            // The eval container id must be in this process's environment
            // BEFORE anything resolves a container path (the breaker state,
            // the substrate, and the sandboxed child's wikictl all inherit
            // it).
            setenv("WIKI_APP_GROUP_ID", configuration.evalAppGroupID, 1)
            let substrate = try LintEvalDaemonSubstrate(
                containerDirectory: configuration.evalContainerDirectory)
            defer { substrate.stop() }
            // The daemon host owns the reserved constructions (store, store
            // model, launcher) and injects them into the driver engine —
            // the CORDIS boundary keeps them out of harness code.
            let factories = LintLiveGateFactories(
                buildStore: { try GRDBWikiStore(databaseURL: $0) },
                buildStoreModel: { WikiStoreModel(store: $0) },
                buildLauncher: { services, leaseManager, effort, quotaStateURL in
                    let launcher = AgentLauncher(providerServices: services)
                    launcher.scopedRunLeaseManager = leaseManager
                    launcher.oneShotThinkingOverride = effort
                    launcher.makeQuotaFallbackCoordinator = {
                        QuotaFallbackCoordinator(quotaStateURL: quotaStateURL)
                    }
                    return launcher
                })
            var driver = LintLiveGateDriver(configuration: configuration)
            let report = try await driver.run(
                substrate: LintEvalSubstrateHandle(
                    leaseManager: substrate.leaseManager,
                    stop: { substrate.stop() }),
                factories: factories)
            FileHandle.standardOutput.write(Data(
                "GATE VERDICT: \(report.verdict)\n".utf8))
            return report.verdict == "PASSED" ? 0 : 1
        } catch let error as LintLiveGateError {
            FileHandle.standardOutput.write(Data(
                "LIVE GATE BLOCKED: \(error.localizedDescription)\n".utf8))
            FileHandle.standardOutput.write(Data("No provider calls were made.\n".utf8))
            return 3
        } catch {
            FileHandle.standardError.write(Data(
                "lint-eval-driver: \(error)\n".utf8))
            return 2
        }
    }

    /// The same flags the runner documents: `--provider <id> --model <id>
    /// --provider-config-dir <dir> --eval-group <id> --output <dir>
    /// [--bail-trials <n>] [--group-runs <n>] [--wall-clock-hours <n>]`.
    static func parseConfiguration(_ arguments: [String]) throws -> LintLiveGateConfiguration {
        func value(_ flag: String) throws -> String {
            guard let at = arguments.firstIndex(of: flag),
                  arguments.indices.contains(at + 1) else {
                throw LintEvalHostError.missingFlag(flag)
            }
            return arguments[at + 1]
        }
        /// The flag's value when present, else nil (never throws — for
        /// optional flags).
        func optionalValue(_ flag: String, in arguments: [String]) -> String? {
            guard let at = arguments.firstIndex(of: flag),
                  arguments.indices.contains(at + 1) else { return nil }
            return arguments[at + 1]
        }
        var index = 0
        let known: Set<String> = [
            "--provider", "--model", "--provider-config-dir", "--eval-group",
            "--output", "--bail-trials", "--group-runs", "--wall-clock-hours",
        ]
        while index < arguments.count {
            guard known.contains(arguments[index]) else {
                throw LintEvalHostError.unknownArgument(arguments[index])
            }
            index += 2
        }
        let evalGroupID = try value("--eval-group")
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Group Containers", isDirectory: true)
            .appendingPathComponent(evalGroupID, isDirectory: true)
        var configuration = LintLiveGateConfiguration(
            providerConfigDirectory: URL(
                fileURLWithPath: (try value("--provider-config-dir") as NSString).expandingTildeInPath,
                isDirectory: true),
            evalContainerDirectory: container,
            evalAppGroupID: evalGroupID,
            outputDirectory: URL(
                fileURLWithPath: (try value("--output") as NSString).expandingTildeInPath,
                isDirectory: true),
            providerID: try value("--provider"),
            modelID: try value("--model"),
            bailTrials: LintLiveGateConfiguration.defaultBailTrials,
            groupRuns: LintLiveGateConfiguration.defaultGroupRuns,
            wallClockCeiling: LintLiveGateConfiguration.defaultWallClockCeiling)
        if let bail = optionalValue("--bail-trials", in: arguments), let count = Int(bail), count >= 1 {
            configuration.bailTrials = count
        }
        if let group = optionalValue("--group-runs", in: arguments), let count = Int(group), count >= 1 {
            configuration.groupRuns = count
        }
        if let hours = optionalValue("--wall-clock-hours", in: arguments),
           let hoursValue = Double(hours), hoursValue > 0 {
            configuration.wallClockCeiling = .seconds(hoursValue * 3600)
        }
        return configuration
    }

    enum LintEvalHostError: Error, CustomStringConvertible {
        case missingFlag(String)
        case unknownArgument(String)

        var description: String {
            switch self {
            case .missingFlag(let flag): "missing required flag \(flag)"
            case .unknownArgument(let flag): "unknown argument \(flag)"
            }
        }
    }
}
