import Foundation
import WikiFSCore

#if canImport(Darwin)
import Darwin
#endif

// MARK: - Script protocol

/// The versioned request/response contract between the host and a configured
/// lint script step. The host writes ONE bounded request JSON file into its
/// private scratch and passes its path as a FIXED argument; the script writes
/// ONE bounded JSON envelope to stdout. Stderr is diagnostic only.
public enum LintScriptProtocol {
    public static let version = 1
    /// The fixed argument carrying the request file URL.
    public static let requestArgument = "--request"

    /// The request the host hands the script. `task` distinguishes a check
    /// (report findings) from a repair (produce one option's patch).
    public struct Request: Codable, Equatable, Sendable {
        public var protocolVersion: Int
        public var run: String
        public var page: String
        public var title: String
        public var body: String
        public var strategy: String
        /// Repair tasks carry the selected finding + recipe instruction.
        public var repair: RepairTask?
        /// Check tasks carry the available recipe ids (echo contract).
        public var availableRecipes: [String]?

        public struct RepairTask: Codable, Equatable, Sendable {
            public var findingID: String
            public var optionID: String
            public var recipeID: String
            public var instruction: String
            public var findingMessage: String
            /// The selected finding's ranges as [start, end] byte pairs.
            public var findingRanges: [[Int]]

            enum CodingKeys: String, CodingKey {
                case findingID = "finding_id"
                case optionID = "option_id"
                case recipeID = "recipe_id"
                case instruction
                case findingMessage = "finding_message"
                case findingRanges = "finding_ranges"
            }
        }

        enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol_version"
            case run, page, title, body, strategy, repair
            case availableRecipes = "available_recipes"
        }
    }
}

// MARK: - Runner errors

public enum LintScriptError: Error, Equatable, Sendable, LocalizedError {
    /// The script is not executable or does not exist (validated at config
    /// load too — this is the launch-time re-check).
    case scriptNotExecutable(URL)
    /// The request body exceeded the input cap.
    case requestTooLarge(bytes: Int, limit: Int)
    case timedOut(seconds: Int)
    case nonzeroExit(status: Int32, stderrTail: String)
    case emptyOutput
    case oversizedOutput(bytes: Int, limit: Int)
    /// The scratch world could not be created — launch is refused.
    case scratchUnavailable(String)
    /// The seatbelt front-end is unusable — fail closed, never unsandboxed.
    case sandboxUnavailable

    public var errorDescription: String? {
        switch self {
        case .scriptNotExecutable(let url):
            return "Lint script is not an executable file: \(url.path)"
        case .requestTooLarge(let bytes, let limit):
            return "Lint script request exceeded the input cap (\(bytes) > \(limit) bytes)."
        case .timedOut(let seconds):
            return "Lint script timed out after \(seconds)s."
        case .nonzeroExit(let status, let tail):
            return "Lint script exited \(status): \(tail)"
        case .emptyOutput:
            return "Lint script produced no output."
        case .oversizedOutput(let bytes, let limit):
            return "Lint script output exceeded the size cap (\(bytes) > \(limit) bytes)."
        case .scratchUnavailable(let detail):
            return "Lint script scratch could not be created: \(detail)"
        case .sandboxUnavailable:
            return "Sandbox is unavailable — refusing to launch the lint script unsandboxed."
        }
    }
}

// MARK: - Sandbox profile

/// The seatbelt profile for one lint script launch. Extractor-grade write
/// fencing with three lint-specific denies appended AFTER the allowances
/// (last-match-wins): the wiki database, the daemon socket, and the network.
public enum LintScriptSandbox {

    /// Profile text for one launch. Pure.
    static func generate(
        scratchDir: String,
        wikiDBPath: String?,
        daemonSocketPath: String?
    ) -> String {
        var lines: [String] = [
            "(version 1)",
            "(allow default)",
            "(deny file-write*)",
            "(allow file-write* (subpath (param \"SCRATCH_DIR\")))",
            // Interpreter basics (mirrors the extractor profile).
            "(allow file-write-data (literal \"/dev/null\"))",
            "(allow file-write-data (subpath \"/dev/fd\"))",
        ]
        // Lint-specific fences, LAST so no allowance can shadow them.
        if let wikiDBPath, !wikiDBPath.isEmpty {
            lines.append("(deny file-read* (subpath (param \"WIKI_DB\")))")
        }
        if let daemonSocketPath, !daemonSocketPath.isEmpty {
            lines.append("(deny network* (remote unix-socket (param \"DAEMON_SOCKET\")))")
            lines.append("(deny file-read* (subpath (param \"DAEMON_SOCKET\")))")
            lines.append("(deny file-write* (subpath (param \"DAEMON_SOCKET\")))")
        }
        lines.append("(deny network*)")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Build the resolved invocation. Every root is canonicalized with
    /// realpath first so symlinked components cannot silently break a
    /// matcher.
    public static func invocation(
        scratchDir: URL,
        wikiDBPath: String?,
        daemonSocketPath: String?
    ) -> SandboxProfile.SandboxInvocation {
        let canonicalScratch = SandboxProfile.canonical(scratchDir.path)
        var profile = generate(
            scratchDir: canonicalScratch,
            wikiDBPath: wikiDBPath,
            daemonSocketPath: daemonSocketPath)
        var defines: [(String, String)] = [
            ("SCRATCH_DIR", canonicalScratch),
        ]
        if let wikiDBPath, !wikiDBPath.isEmpty {
            let canonical = SandboxProfile.canonical(wikiDBPath)
            profile += "\n;; WIKI_DB deny define present\n"
            defines.append(("WIKI_DB", canonical))
        }
        if let daemonSocketPath, !daemonSocketPath.isEmpty {
            defines.append(("DAEMON_SOCKET", SandboxProfile.canonical(daemonSocketPath)))
        }
        return SandboxProfile.SandboxInvocation(profile: profile, defines: defines)
    }

    /// The minimal environment: no provider secrets, no wiki location, no
    /// daemon endpoint. TMPDIR points at the scratch-local temp leaf.
    public static func environment(scratch: LLMSandboxScratch) -> [String: String] {
        [
            "TMPDIR": scratch.tempDirectoryURL.path,
            "HOME": scratch.directoryURL.path,
            "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
            "LANG": "en_US.UTF-8",
        ]
    }
}

// MARK: - Runner

/// Executes one configured lint script step: builds the scratch world,
/// writes the bounded request, launches the script under the sandbox with a
/// timeout and output caps, and returns the raw stdout envelope text for the
/// caller's decoder.
///
/// Containment notes (documented contract, enforced by test):
/// - Descendant processes inherit the seatbelt — a lingering child can write
///   only inside the scratch and cannot reach the network, the wiki DB, or
///   the daemon socket even if it outlives its parent.
/// - Sandbox unavailability prevents launch entirely (fail closed).
/// - A script can never save wiki content: its only output is the envelope
///   the host validates and turns into a proposal the user previews.
public struct LintScriptRunner: Sendable {

    /// Inputs for one launch.
    public struct Launch: Sendable {
        public let scriptURL: URL
        public let arguments: [String]
        public let request: LintScriptProtocol.Request
        public let timeoutSeconds: Int
        public let maxOutputBytes: Int
        public let wikiDBPath: String?
        public let daemonSocketPath: String?

        public init(
            scriptURL: URL, arguments: [String], request: LintScriptProtocol.Request,
            timeoutSeconds: Int, maxOutputBytes: Int,
            wikiDBPath: String?, daemonSocketPath: String?
        ) {
            self.scriptURL = scriptURL
            self.arguments = arguments
            self.request = request
            self.timeoutSeconds = timeoutSeconds
            self.maxOutputBytes = maxOutputBytes
            self.wikiDBPath = wikiDBPath
            self.daemonSocketPath = daemonSocketPath
        }
    }

    /// One run's outcome: the stdout text (envelope input) plus the owned
    /// scratch the CALLER removes after consuming the result.
    public struct Outcome: Sendable {
        public let stdout: String
        public let stderrTail: String
        public let scratch: LLMSandboxScratch
    }

    public init() {}

    /// Cap on the request file (the page body rides inside it).
    public static let maxRequestBytes = 4 * 1024 * 1024

    public func run(_ launch: Launch) async throws -> Outcome {
        // Launch-time executable re-check (config load checks too).
        var isDirectory: ObjCBool = false
        let resolved = launch.scriptURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: resolved.path) else {
            throw LintScriptError.scriptNotExecutable(launch.scriptURL)
        }
        // Sandbox availability gates the launch (fail closed).
        guard ACPBackend.sandboxExecutableIsUsable(
            at: SandboxProfile.sandboxExecutablePath) else {
            throw LintScriptError.sandboxUnavailable
        }
        // Scratch world.
        let scratch: LLMSandboxScratch
        do {
            scratch = try LLMSandboxScratch.make(namePrefix: "lint-script", strict: false)
        } catch {
            throw LintScriptError.scratchUnavailable(String(describing: error))
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let requestData = try encoder.encode(launch.request)
            let requestBytes = requestData.count
            guard requestBytes <= Self.maxRequestBytes else {
                throw LintScriptError.requestTooLarge(
                    bytes: requestBytes, limit: Self.maxRequestBytes)
            }
            let requestURL = scratch.directoryURL.appendingPathComponent("request.json")
            try requestData.write(to: requestURL, options: .atomic)

            let invocation = LintScriptSandbox.invocation(
                scratchDir: scratch.directoryURL,
                wikiDBPath: launch.wikiDBPath,
                daemonSocketPath: launch.daemonSocketPath)
            let argv = SandboxProfile.wrappedArguments(
                executablePath: resolved.path,
                arguments: launch.arguments + [LintScriptProtocol.requestArgument, requestURL.path],
                invocation: invocation)

            let request = AsyncProcessRequest(
                executableURL: URL(fileURLWithPath: argv[0]),
                arguments: Array(argv.dropFirst()),
                environment: LintScriptSandbox.environment(scratch: scratch),
                currentDirectoryURL: scratch.directoryURL,
                outputMode: .separate)

            // Race the process against the timeout. Cancellation terminates
            // the child (AsyncProcessRunner's graceful-cancel path); the
            // sandbox confines any descendant that ignores the signal.
            let result: AsyncProcessResult = try await withThrowingTaskGroup(
                of: AsyncProcessResult.self) { group in
                group.addTask { try await AsyncProcessRunner.run(request) }
                group.addTask {
                    try await Task.sleep(for: .seconds(launch.timeoutSeconds))
                    throw LintScriptError.timedOut(seconds: launch.timeoutSeconds)
                }
                guard let first = try await group.next() else {
                    throw LintScriptError.timedOut(seconds: launch.timeoutSeconds)
                }
                group.cancelAll()
                return first
            }

            let stderrTail = String(
                decoding: result.stderrData.prefix(2000), as: UTF8.self)
            guard result.terminationStatus == 0 else {
                throw LintScriptError.nonzeroExit(
                    status: result.terminationStatus, stderrTail: stderrTail)
            }
            let stdoutBytes = result.stdoutData.count
            guard stdoutBytes > 0 else { throw LintScriptError.emptyOutput }
            guard stdoutBytes <= launch.maxOutputBytes else {
                throw LintScriptError.oversizedOutput(
                    bytes: stdoutBytes, limit: launch.maxOutputBytes)
            }
            return Outcome(
                stdout: String(decoding: result.stdoutData, as: UTF8.self),
                stderrTail: stderrTail,
                scratch: scratch)
        } catch {
            // Every failure path cleans the scratch before surfacing.
            scratch.remove()
            throw error
        }
    }
}
