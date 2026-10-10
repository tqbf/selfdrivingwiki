import Foundation
#if canImport(Darwin)
import Darwin
#endif

// pattern: Imperative Shell + typed outcomes
//
// The reviewed YouTube package's caption fallback needs an auxiliary
// JavaScript runtime (Bun) beside its mandatory `uv` launch command. The
// host resolves that runtime through the same login-shell locator as every
// other extractor runtime, then verifies the version against the pinned
// retrieval library's documented minimum before the path may reach a
// package. Everything here is host-owned: no package input names, finds,
// or validates the executable.

/// The auxiliary-runtime policies the host enforces for reviewed packages.
/// The Bun minimum mirrors the pinned yt-dlp release's `BunJsRuntime`
/// supported minimum (1.2.11); the offline contract test pins that both
/// sides agree, so bumping one without the other fails a gate.
public enum AuxiliaryRuntimePolicies {
    public static let bun = AuxiliaryRuntimePolicy(
        name: ExtractorRuntimeName(rawValue: "bun"),
        minimumVersion: RuntimeSemanticVersion(major: 1, minor: 2, patch: 11))
}

/// One auxiliary runtime's resolution policy: the login-shell command name
/// and the minimum accepted version.
public struct AuxiliaryRuntimePolicy: Sendable {
    public let name: ExtractorRuntimeName
    public let minimumVersion: RuntimeSemanticVersion

    init(name: ExtractorRuntimeName?, minimumVersion: RuntimeSemanticVersion) {
        // "bun" is a compile-time constant; an invalid value is a programmer
        // error and crashes at first touch (golden-constant discipline).
        // swiftlint:disable:next force_unwrapping
        self.name = name!
        self.minimumVersion = minimumVersion
    }
}

/// A dotted numeric version with total ordering. Pre-release suffixes
/// ("1.2.11-canary") compare by their numeric core; a shorter tuple pads
/// with zeros, so "1.2" == "1.2.0" and both are < "1.2.1".
public struct RuntimeSemanticVersion: Sendable, Equatable, Comparable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses the leading `MAJOR[.MINOR[.PATCH]]` of one output line.
    /// `nil` when the line does not start with dotted integers.
    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard let major = Self.integer(parts, 0) else { return nil }
        self.init(
            major: major,
            minor: Self.integer(parts, 1) ?? 0,
            patch: Self.integer(parts, 2) ?? 0)
    }

    private static func integer(_ parts: [Substring], _ index: Int) -> Int? {
        guard index < parts.count else { return nil }
        let digits = parts[index].prefix { $0.isNumber }
        guard !digits.isEmpty, let value = Int(digits) else { return nil }
        return value
    }

    public static func < (lhs: RuntimeSemanticVersion, rhs: RuntimeSemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// One auxiliary-runtime resolution: the validated login-shell executable,
/// or a typed unavailable reason. Like the mandatory launch runtime, the
/// outcome is resolved ONCE per prepared operation and retained. (Not
/// Equatable: the resolved payload carries the executable identity fields,
/// which tests compare field-wise.)
public enum AuxiliaryRuntimeOutcome: Sendable {
    case resolved(RuntimeCommandResolution)
    case unavailable(AuxiliaryRuntimeUnavailableReason)
}

/// Why the auxiliary runtime cannot serve the caption fallback. Every
/// reason is a fixed diagnostic category; none carries executable paths or
/// upstream output.
public enum AuxiliaryRuntimeUnavailableReason: Error, Sendable, Equatable {
    /// The login-shell resolution itself failed (absent, unusable, …).
    case resolutionFailed(RuntimeCommandResolutionFailure)
    /// The resolved executable reports a version below the pinned minimum.
    case unsupportedVersion(reported: String, minimum: String)
    /// The version probe could not produce a usable version line.
    case versionProbeFailed
    /// The executable changed after resolution (identity recheck failed).
    case identityRecheckFailed
}

/// The seam a prepared operation uses to verify one resolved runtime's
/// version. Injectable for tests; the production implementation runs
/// `<executable> --version` through the race-free process-group runner.
public protocol AuxiliaryRuntimeVersionProbing: Sendable {
    func probe(executableURL: URL) async -> RuntimeVersionProbeOutcome
}

/// The outcome of one version probe: the parsed version, or a typed failure.
public enum RuntimeVersionProbeOutcome: Sendable, Equatable {
    case version(RuntimeSemanticVersion)
    case failed
}

/// Named bounds for the version probe subprocess.
public enum AuxiliaryRuntimeProbeLimits {
    /// How long the executable may take to print its version.
    public static let timeout: Duration = .seconds(10)
    /// A version line is short; anything longer is refused.
    public static let maximumOutputByteCount = 1_024
}

/// Production version probe: `<executable> --version` with an empty
/// environment, bounded output, and a startup timeout. The probe never
/// follows a PATH and never passes arguments beside `--version`.
public struct AuxiliaryRuntimeVersionProbe: AuxiliaryRuntimeVersionProbing, Sendable {
    public init() {}

    public func probe(executableURL: URL) async -> RuntimeVersionProbeOutcome {
        let handle: RaceFreeProcessGroupHandle
        do {
            handle = try RaceFreeProcessGroupRunner.launch(.init(
                executableURL: executableURL,
                arguments: ["--version"],
                environment: [:],
                currentDirectoryURL: nil,
                standardInput: Data(),
                stdoutLimit: AuxiliaryRuntimeProbeLimits.maximumOutputByteCount,
                stderrLimit: AuxiliaryRuntimeProbeLimits.maximumOutputByteCount))
        } catch {
            return .failed
        }
        let execution: ProcessGroupExecutionResult
        do {
            execution = try await handle.result(
                timeout: AuxiliaryRuntimeProbeLimits.timeout)
        } catch {
            return .failed
        }
        guard case .exited(code: 0) = execution.terminationCause else {
            return .failed
        }
        guard let version = RuntimeSemanticVersion(
            parsing: String(decoding: execution.stdout, as: UTF8.self)) else {
            return .failed
        }
        return .version(version)
    }
}
