import Foundation
import WikiFSTypes
#if canImport(Darwin)
import Darwin
#endif

/// Where a runtime executable was resolved from. The login shell is the only
/// extractor runtime resolution source: it applies the user's own shell
/// configuration, whatever manages their tools.
public enum ExtractorRuntimeSource: String, Sendable {
    case loginShell = "login-shell"
}

/// The pinned file identity of a resolved runtime executable. Captured after
/// validation at resolution time and compared immediately before spawn, so a
/// replaced or rewritten executable fails closed instead of launching.
public struct RuntimeExecutableIdentity: Sendable, Equatable {
    public let device: UInt64
    public let inode: UInt64
    public let mode: UInt32
    public let size: Int64

    public init(device: UInt64, inode: UInt64, mode: UInt32, size: Int64) {
        self.device = device
        self.inode = inode
        self.mode = mode
        self.size = size
    }
}

/// A bounded, redacted description of the resolved executable path for
/// diagnostics. The absolute URL itself stays inside trusted launch code.
public struct RuntimePathDescription: Sendable, Equatable {
    /// The path with the home directory prefix replaced by `~`.
    public let redactedPath: String
    /// The executable's basename, e.g. `bun`.
    public let basename: String
    /// A short fingerprint for correlating log lines.
    public let fingerprint: String
}

/// One validated runtime resolution, retained by a prepared operation and
/// consumed by both readiness and launch. Nothing here re-searches a PATH.
public struct RuntimeCommandResolution: Sendable {
    /// The runtime name the manifest asked for.
    public let command: ExtractorRuntimeName
    /// How the executable was selected.
    public let source: ExtractorRuntimeSource
    /// The absolute executable URL exactly as the login shell reported it
    /// (lexically standardized; symlinks are NOT resolved away).
    public let executableURL: URL
    /// The pinned identity of the executable behind the URL.
    public let identity: RuntimeExecutableIdentity
    /// Safe diagnostics description of the executable.
    public let description: RuntimePathDescription
}

/// Typed resolution failures. Every stage of the login-shell query is
/// distinguishable (AC.6): the account record, the shell family, the launch,
/// the startup timeout, the shell's exit, command absence, unusable shell
/// output, and an unusable executable target.
public enum RuntimeCommandResolutionFailure: Error, Sendable, Equatable {
    /// The account record has no login shell, or the shell is not an
    /// absolute path.
    case accountShellUnavailable
    /// The configured login shell is not one of the supported families.
    case unsupportedShellFamily(shellName: String)
    /// The login-shell process could not be launched.
    case loginShellLaunchFailure
    /// The login shell did not finish startup within the timeout. The shell
    /// process group is terminated and reaped.
    case loginShellStartupTimeout
    /// The login shell exited nonzero with real stderr output.
    case loginShellNonzeroExit(exitCode: Int32, stderrTail: String)
    /// The login shell completed and reports the command is not installed.
    case commandAbsent
    /// The shell printed zero, multiple, or malformed output lines.
    case invalidShellOutput(ShellOutputInvalidity)
    /// The shell named a target that is not a usable host executable.
    case unusableExecutable(UnusableExecutableReason)

    public enum ShellOutputInvalidity: Error, Sendable, Equatable {
        case emptyOutput
        case multipleLines(lineCount: Int)
        case relativePath
        case notAPath
    }

    public enum UnusableExecutableReason: Error, Sendable, Equatable {
        case probeFailed
        case notRegularFile
        case multipleLinks
        case notExecutable
        case notReadable
    }

    /// The diagnostic category name for one-line Console events.
    public var diagnosticCategory: String {
        switch self {
        case .accountShellUnavailable: "account-shell"
        case .unsupportedShellFamily: "unsupported-shell"
        case .loginShellLaunchFailure: "launch"
        case .loginShellStartupTimeout: "timeout"
        case .loginShellNonzeroExit: "exit"
        case .commandAbsent: "absent"
        case .invalidShellOutput: "invalid-output"
        case .unusableExecutable: "unusable-executable"
        }
    }
}

/// The result of one runtime resolution attempt: a validated executable, or
/// a typed failure. A prepared operation retains this once; readiness and
/// launch both consume the retained value.
public enum RuntimeCommandOutcome: Sendable {
    case resolved(RuntimeCommandResolution)
    case failed(RuntimeCommandResolutionFailure)
}

/// Named bounds for the login-shell resolution subprocess.
public enum RuntimeResolutionLimits {
    /// How long shell startup may take before the query is abandoned and the
    /// shell process group is terminated and reaped.
    public static let shellStartupTimeout: Duration = .seconds(10)
    /// Shell stdout bound (the expected result is one short path).
    public static let maximumShellOutputByteCount = 16 * 1_024
    /// Shell stderr bound.
    public static let maximumShellErrorByteCount = 16 * 1_024
    /// Bounded stderr tail carried on a nonzero-exit failure.
    public static let maximumStderrTailLength = 240
}

/// The account's configured login shell from the system account record.
public struct AccountShellRecord: Sendable, Equatable {
    /// The absolute login-shell path from `getpwuid_r`.
    public let shellPath: String

    public init(shellPath: String) {
        self.shellPath = shellPath
    }
}

/// Reads the account's login shell from the system account record.
public enum AccountShell {
    /// Returns the record only when `getpwuid_r` reports a shell that is an
    /// absolute path. A missing record or a non-absolute shell is unusable.
    public static func currentRecord() -> AccountShellRecord? {
        var password = passwd()
        var buffer = [CChar](repeating: 0, count: 4_096)
        var result: UnsafeMutablePointer<passwd>? = nil
        let status = getpwuid_r(
            getuid(), &password, &buffer, buffer.count, &result)
        guard status == 0,
              result != nil,
              let shellPointer = result?.pointee.pw_shell else {
            return nil
        }
        let path = String(cString: shellPointer)
        guard path.hasPrefix("/") else { return nil }
        return AccountShellRecord(shellPath: path)
    }
}

/// The closed set of supported login-shell families. Each adapter pins one
/// external-command query and one positional convention; the runtime name is
/// passed as a positional argument, never as shell source.
public enum LoginShellFamily: String, Sendable, CaseIterable, Equatable {
    case zsh
    case bash
    case fish

    /// The fixed `$0` placeholder zsh and bash pass before the runtime name.
    /// Its value is irrelevant to the query; only its position is fixed.
    public static let positionalPlaceholder = "wiki-extractor-runtime"

    init?(shellPath: String) {
        let basename = (shellPath as NSString).lastPathComponent
        // macOS installs the shells as `zsh`, `bash`, and `fish`; tolerate a
        // versioned basename such as `zsh-5.9`.
        let stem = basename.split(separator: "-").first.map(String.init) ?? basename
        self.init(rawValue: stem.lowercased())
    }

    /// The fixed external-command query string. It is passed as the `-c`
    /// payload and is identical for every runtime name.
    public var querySource: String {
        switch self {
        case .zsh: #"whence -p -- "$1""#
        case .bash: #"type -P -- "$1""#
        case .fish: "command -v $argv[1]"
        }
    }

    /// The exact argument vector for one resolution query. Zsh and bash
    /// receive the `$0` placeholder before the runtime name; fish receives
    /// the runtime name as `$argv[1]`. The runtime name is always the LAST
    /// argument and is never interpolated into the command source.
    public func launchArguments(for command: ExtractorRuntimeName) -> [String] {
        switch self {
        case .zsh, .bash:
            ["-lic", querySource, Self.positionalPlaceholder, command.rawValue]
        case .fish:
            ["-lic", querySource, command.rawValue]
        }
    }
}

/// The raw result of one login-shell query subprocess.
public struct ShellQueryOutcome: Sendable {
    public let terminationCause: ProcessTerminationCause
    public let stdout: Data
    public let stderr: Data

    public init(
        terminationCause: ProcessTerminationCause,
        stdout: Data,
        stderr: Data
    ) {
        self.terminationCause = terminationCause
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Launches one login-shell query. Injectable for tests; the production
/// implementation runs the shell through the race-free process-group runner
/// with empty stdin, bounded output, and a startup timeout. On timeout the
/// runner terminates and reaps the shell process group.
public typealias ShellQueryLaunching = @Sendable (
    _ executableURL: URL,
    _ arguments: [String],
    _ environmentOverrides: [String: String],
    _ timeout: Duration
) async throws -> ShellQueryOutcome

/// Production login-shell query through the race-free runner.
enum RaceFreeShellQuery {
    static func launch(
        executableURL: URL,
        arguments: [String],
        environmentOverrides: [String: String],
        timeout: Duration
    ) async throws -> ShellQueryOutcome {
        // The shell-resolution subprocess inherits the host process
        // environment so shell startup works normally; overrides can point
        // shell configuration roots at test fixtures. This is NOT the
        // managed extractor environment — that allowlist is separate.
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in environmentOverrides {
            environment[key] = value
        }
        let handle = try RaceFreeProcessGroupRunner.launch(.init(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            currentDirectoryURL: nil,
            standardInput: Data(),
            stdoutLimit: RuntimeResolutionLimits.maximumShellOutputByteCount,
            stderrLimit: RuntimeResolutionLimits.maximumShellErrorByteCount))
        let execution = try await handle.result(timeout: timeout)
        return ShellQueryOutcome(
            terminationCause: execution.terminationCause,
            stdout: execution.stdout,
            stderr: execution.stderr)
    }
}

/// The outcome of one executable identity probe.
public enum RuntimeExecutableProbeOutcome: Sendable, Equatable {
    case identity(RuntimeExecutableIdentity)
    case unusable(RuntimeCommandResolutionFailure.UnusableExecutableReason)
}

/// Identity probe for host runtime executables. Uses `stat` — the host may
/// reach a real tool through a symlink (a tool-manager shim, a Homebrew
/// link) — but the launch URL stays exactly as the shell reported it.
/// The single-link rule is a deliberate fail-closed policy: a target with
/// multiple hard links is rejected.
public enum RuntimeFileProbe {
    public static func probe(_ url: URL) -> RuntimeExecutableProbeOutcome {
        var status = stat()
        guard stat(url.path, &status) == 0 else { return .unusable(.probeFailed) }
        guard status.st_mode & S_IFMT == S_IFREG else {
            return .unusable(.notRegularFile)
        }
        guard status.st_nlink == 1 else { return .unusable(.multipleLinks) }
        guard status.st_mode & S_IXUSR != 0 else {
            return .unusable(.notExecutable)
        }
        // Readability is required at resolution so the pre-spawn
        // revalidation rule and the resolution rule agree.
        guard status.st_mode & S_IRUSR != 0 else {
            return .unusable(.notReadable)
        }
        return .identity(RuntimeExecutableIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            mode: UInt32(status.st_mode),
            size: Int64(status.st_size)))
    }
}

/// The seam a prepared operation uses to resolve one runtime command. The
/// production implementation is `RuntimeCommandLocator`; provider tests
/// inject a spy to observe resolution counts and retained results.
public protocol ExtractorRuntimeLocating: Sendable {
    func locate(_ command: ExtractorRuntimeName) async -> RuntimeCommandOutcome
}

/// Resolves a validated runtime command name to the one absolute executable
/// the user's login shell selects for it.
///
/// The login shell is the authority: it applies the user's own shell
/// configuration, so runtimes managed by any tool work without the host
/// knowing about any tool manager. The host performs no directory search and
/// no process-PATH fallback; a failed query is a typed failure. Failures are
/// never cached — each prepared operation resolves once, so a runtime
/// installed after a failure works from the next preparation without an app
/// restart.
public struct RuntimeCommandLocator: ExtractorRuntimeLocating, Sendable {
    private let accountShell: @Sendable () -> AccountShellRecord?
    private let launchShellQuery: ShellQueryLaunching
    private let environmentOverrides: [String: String]
    private let probe: @Sendable (URL) -> RuntimeExecutableProbeOutcome
    private let shellStartupTimeout: Duration
    private let diagnostics: any ExtractorDiagnosticsSink

    /// The production locator. Stateless: nothing is cached between calls.
    public init(
        environmentOverrides: [String: String] = [:],
        shellStartupTimeout: Duration = RuntimeResolutionLimits.shellStartupTimeout,
        diagnostics: (any ExtractorDiagnosticsSink)? = nil
    ) {
        self.init(
            accountShell: AccountShell.currentRecord,
            launchShellQuery: RaceFreeShellQuery.launch,
            environmentOverrides: environmentOverrides,
            probe: RuntimeFileProbe.probe,
            shellStartupTimeout: shellStartupTimeout,
            diagnostics: diagnostics ?? DebugLogExtractorDiagnosticsSink())
    }

    /// Fully injected initializer for deterministic tests.
    init(
        accountShell: @escaping @Sendable () -> AccountShellRecord?,
        launchShellQuery: @escaping ShellQueryLaunching,
        environmentOverrides: [String: String],
        probe: @escaping @Sendable (URL) -> RuntimeExecutableProbeOutcome,
        shellStartupTimeout: Duration,
        diagnostics: any ExtractorDiagnosticsSink
    ) {
        self.accountShell = accountShell
        self.launchShellQuery = launchShellQuery
        self.environmentOverrides = environmentOverrides
        self.probe = probe
        self.shellStartupTimeout = shellStartupTimeout
        self.diagnostics = diagnostics
    }

    public func locate(_ command: ExtractorRuntimeName) async -> RuntimeCommandOutcome {
        guard let record = accountShell() else {
            return fail(command, .accountShellUnavailable, "no usable account shell record")
        }
        // The record is unusable unless it names an absolute shell path.
        guard record.shellPath.hasPrefix("/") else {
            return fail(command, .accountShellUnavailable, "account shell is not an absolute path")
        }
        guard let family = LoginShellFamily(shellPath: record.shellPath) else {
            let shellName = (record.shellPath as NSString).lastPathComponent
            return fail(
                command,
                .unsupportedShellFamily(shellName: shellName),
                "configured shell \(shellName)")
        }
        let arguments = family.launchArguments(for: command)
        let query: ShellQueryOutcome
        do {
            query = try await launchShellQuery(
                URL(fileURLWithPath: record.shellPath),
                arguments,
                environmentOverrides,
                shellStartupTimeout)
        } catch RaceFreeProcessGroupError.timedOut {
            return fail(command, .loginShellStartupTimeout, "shell startup exceeded \(shellStartupTimeout)")
        } catch {
            return fail(
                command,
                .loginShellLaunchFailure,
                ManagedExtractorDiagnostics.sanitize(
                    String(describing: error),
                    limit: ManagedExtractorDiagnostics.maximumDetailLength))
        }
        switch query.terminationCause {
        case .exited(code: 0):
            break
        case .exited(let code):
            // A nonzero exit with empty stdout and empty (or known-noise)
            // stderr means the shell answered "not installed". Anything else
            // is a real shell error.
            if query.stdout.isEmpty, Self.stderrIsAbsentOrKnownNoise(query.stderr) {
                return fail(command, .commandAbsent, "exit \(code)")
            }
            return fail(
                command,
                .loginShellNonzeroExit(
                    exitCode: code,
                    stderrTail: ManagedExtractorDiagnostics.singleLineTail(
                        query.stderr,
                        displayLimit: RuntimeResolutionLimits.maximumStderrTailLength)),
                "exit \(code)")
        case .signaled(let signal):
            return fail(
                command,
                .loginShellNonzeroExit(
                    exitCode: -signal,
                    stderrTail: ManagedExtractorDiagnostics.singleLineTail(
                        query.stderr,
                        displayLimit: RuntimeResolutionLimits.maximumStderrTailLength)),
                "signaled \(signal)")
        }
        switch Self.singleOutputLine(query.stdout) {
        case .failure(let invalidity):
            return fail(command, .invalidShellOutput(invalidity), "unexpected shell startup output")
        case .success(let line):
            return resolveTarget(command, line: line)
        }
    }

    private func resolveTarget(
        _ command: ExtractorRuntimeName,
        line: String
    ) -> RuntimeCommandOutcome {
        // Lexical normalization only: the host launches exactly the path the
        // shell reported. Symlinks are followed only by the identity probe.
        let url = URL(fileURLWithPath: line).standardizedFileURL
        switch probe(url) {
        case .identity(let identity):
            let description = RuntimePathDescription(
                redactedPath: ManagedExtractorDiagnostics.redactedPath(for: url),
                basename: url.lastPathComponent,
                fingerprint: ManagedExtractorDiagnostics.pathFingerprint(for: url))
            let resolution = RuntimeCommandResolution(
                command: command,
                source: .loginShell,
                executableURL: url,
                identity: identity,
                description: description)
            diagnostics.send(ManagedExtractorDiagnostics.Event.runtimeResolved(
                command: command.rawValue,
                source: resolution.source.rawValue,
                path: description.redactedPath,
                identity: ManagedExtractorDiagnostics.identityFingerprint(
                    for: identity)).consoleLine)
            return .resolved(resolution)
        case .unusable(let reason):
            return fail(
                command,
                .unusableExecutable(reason),
                ManagedExtractorDiagnostics.redactedPath(for: url))
        }
    }

    private func fail(
        _ command: ExtractorRuntimeName,
        _ failure: RuntimeCommandResolutionFailure,
        _ detail: String
    ) -> RuntimeCommandOutcome {
        diagnostics.send(ManagedExtractorDiagnostics.Event.runtimeResolutionFailed(
            command: command.rawValue,
            category: failure.diagnosticCategory,
            detail: ManagedExtractorDiagnostics.sanitize(
                detail,
                limit: ManagedExtractorDiagnostics.maximumDetailLength)).consoleLine)
        return .failed(failure)
    }

    /// Exactly one nonempty, absolute output line. A trailing newline is
    /// tolerated; banners, motds, and multi-line startup noise are not.
    static func singleOutputLine(
        _ data: Data
    ) -> Result<String, RuntimeCommandResolutionFailure.ShellOutputInvalidity> {
        typealias Invalidity = RuntimeCommandResolutionFailure.ShellOutputInvalidity
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard lines.count == 1, let first = lines.first else {
            let invalidity: Invalidity = lines.isEmpty
                ? .emptyOutput
                : .multipleLines(lineCount: lines.count)
            return .failure(invalidity)
        }
        let line = first.trimmingCharacters(in: .whitespaces)
        guard line.isEmpty == false else {
            return .failure(.emptyOutput)
        }
        guard line.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else {
            return .failure(.notAPath)
        }
        guard line.hasPrefix("/") else {
            let invalidity: Invalidity = line.contains("/")
                ? .relativePath
                : .notAPath
            return .failure(invalidity)
        }
        return .success(line)
    }

    /// True when stderr is empty or contains only known interactive-shell
    /// startup noise (job-control warnings from shells without a TTY).
    private static let knownNoiseMarkers = [
        "no job control",
        "cannot set terminal process group",
        "couldn't get a file descriptor",
        "inappropriate ioctl for device",
    ]

    static func stderrIsAbsentOrKnownNoise(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(
            separator: "\n", omittingEmptySubsequences: true)
        return lines.allSatisfy { line in
            knownNoiseMarkers.contains {
                line.localizedCaseInsensitiveContains($0)
            }
        }
    }
}
