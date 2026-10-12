import Foundation

/// The package-runner launch commands the adapter upgrade manager understands.
/// These are the runners whose argv carries the package and version inline,
/// so an exact pin can be read back out of (and written into) a stored
/// command.
public enum ACPPackageRunnerKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// `npx <pkg@version> [args…]`
    case npx
    /// `npm exec <pkg@version> [args…]` (the `--` separator form parses too)
    case npmExec = "npm-exec"
    /// `bun x <pkg@version> [args…]` and `bunx <pkg@version> [args…]`
    case bun
    /// `uvx <pkg==version> [args…]` (PyPI `==` pin)
    case uvx

    /// The runner's bare executable name (`command[0]`).
    public var executableName: String {
        switch self {
        case .npx: return "npx"
        case .npmExec: return "npm"
        case .bun: return "bun"
        case .uvx: return "uvx"
        }
    }
}

/// A package-runner command parsed into its typed parts. `version` is `nil`
/// for a floating command (`bun x pkg`, `npx pkg@latest`, `npx pkg@^1.2`) —
/// a floating command is never an ADOPTABLE target, but it can be the
/// from-state of an adoption (the upgrade manager pins it).
public struct ACPParsedPackageCommand: Hashable, Codable, Sendable {
    public let runner: ACPPackageRunnerKind
    public let package: String
    public let version: ACPAgentVersion?
    public let trailingArguments: [String]

    public init(
        runner: ACPPackageRunnerKind,
        package: String,
        version: ACPAgentVersion?,
        trailingArguments: [String] = []
    ) {
        self.runner = runner
        self.package = package
        self.version = version
        self.trailingArguments = trailingArguments
    }

    /// Rebuild the launch argv for this parsed command. The inverse of the
    /// canonical parse (npm-runner forms always re-emit the bare form).
    public var launchCommand: [String] {
        var command: [String]
        switch runner {
        case .npx: command = ["npx", pinnedToken]
        case .npmExec: command = ["npm", "exec", pinnedToken]
        case .bun: command = ["bun", "x", pinnedToken]
        case .uvx: command = ["uvx", pinnedToken]
        }
        command.append(contentsOf: trailingArguments)
        return command
    }

    /// The command shape with the version pin stripped: runner executables +
    /// bare package + trailing arguments. Two commands with the same shape
    /// differ only in which version they pin.
    public var shapeCommand: [String] {
        ACPParsedPackageCommand(
            runner: runner,
            package: package,
            version: nil,
            trailingArguments: trailingArguments).launchCommand
    }

    /// The package token with its version pin (`pkg@1.2.3` / `pkg==1.2.3`),
    /// or the bare package name when the command is floating.
    private var pinnedToken: String {
        guard let version else { return package }
        return runner == .uvx ? "\(package)==\(version.rawValue)" : "\(package)@\(version.rawValue)"
    }
}

/// An EXACT-pinned package command — the only shape the upgrade manager may
/// adopt or compare against. The ACP identity a candidate reports is NOT
/// derived here: registry ids (`codex-acp`), distribution package names
/// (`@agentclientprotocol/codex-acp`), and reported `agentInfo` identities
/// are three different namespaces. Identity verification goes through the
/// verified contract table (`ACPAdapterCompatibility`), never through the
/// package name.
public struct ACPPackageSpec: Hashable, Codable, Sendable {
    public let runner: ACPPackageRunnerKind
    public let package: String
    public let version: ACPAgentVersion
    public let trailingArguments: [String]

    /// The launch argv that runs exactly this pinned package.
    public var launchCommand: [String] {
        ACPParsedPackageCommand(
            runner: runner,
            package: package,
            version: version,
            trailingArguments: trailingArguments).launchCommand
    }

    /// Construct an exact spec from parts. Prefer `ACPPackageCommandParser`
    /// at text boundaries; this init exists for typed call sites (adoption
    /// records, tests) that already hold validated parts.
    public init(
        runner: ACPPackageRunnerKind,
        package: String,
        version: ACPAgentVersion,
        trailingArguments: [String] = []
    ) {
        self.runner = runner
        self.package = package
        self.version = version
        self.trailingArguments = trailingArguments
    }
}

// MARK: - Parsing

public enum ACPPackageCommandParser {
    /// Parse a stored (or registry) launch argv into its typed package shape.
    /// Returns `nil` when the command is not a package-runner launch (a plain
    /// binary such as `gemini --acp`) or the runner form is unrecognizable.
    /// A package-runner command whose version is missing or NOT an exact pin
    /// (`@latest`, `@^1.2`, `@~1.2`, `@1.x`, `@*`, `@1`) still parses — with
    /// `version == nil` — so callers can distinguish "user-owned plain
    /// binary" from "package command that floats".
    public static func parse(_ command: [String]?) -> ACPParsedPackageCommand? {
        guard let command, let first = command.first else { return nil }
        let rest = Array(command.dropFirst())
        switch first {
        case "npx":
            return parseToken(rest.first, runner: .npx, trailing: Array(rest.dropFirst()))
        case "npm":
            // `npm exec <pkg@ver> …` or `npm exec -- <pkg@ver> …`.
            guard rest.first == "exec" else { return nil }
            let afterExec = Array(rest.dropFirst())
            let args = afterExec.first == "--" ? Array(afterExec.dropFirst()) : afterExec
            return parseToken(args.first, runner: .npmExec, trailing: Array(args.dropFirst()))
        case "bun":
            guard rest.first == "x" else { return nil }
            return parseToken(rest.dropFirst().first, runner: .bun, trailing: Array(rest.dropFirst(2)))
        case "bunx":
            return parseToken(rest.first, runner: .bun, trailing: Array(rest.dropFirst()))
        case "uvx":
            return parseToken(rest.first, runner: .uvx, trailing: Array(rest.dropFirst()))
        default:
            return nil
        }
    }

    /// Extract the exact spec from a parsed command. `nil` when the command
    /// is floating — the ONLY guard between a floating tag and an adoption.
    public static func exactSpec(
        _ parsed: ACPParsedPackageCommand
    ) -> ACPPackageSpec? {
        guard let version = parsed.version else { return nil }
        return ACPPackageSpec(
            runner: parsed.runner,
            package: parsed.package,
            version: version,
            trailingArguments: parsed.trailingArguments)
    }

    /// The version-stripped shape of a command, or `nil` when the command is
    /// not a parseable package-runner launch. Two commands share a shape when
    /// they launch the same package the same way and differ only in pin.
    public static func shape(_ command: [String]?) -> [String]? {
        parse(command)?.shapeCommand
    }

    private static func parseToken(
        _ token: String?, runner: ACPPackageRunnerKind, trailing: [String]
    ) -> ACPParsedPackageCommand? {
        guard let token, !token.isEmpty, !token.hasPrefix("-") else { return nil }
        switch runner {
        case .uvx:
            return parseUVToken(token, trailing: trailing)
        case .npx, .npmExec, .bun:
            return parseNPMPrefixToken(token, runner: runner, trailing: trailing)
        }
    }

    /// npm-style `name[@version]` — split on the LAST `@` so scoped packages
    /// (`@scope/name@1.2.3`) split correctly. A missing or non-exact version
    /// yields `version == nil` (floating).
    private static func parseNPMPrefixToken(
        _ token: String, runner: ACPPackageRunnerKind, trailing: [String]
    ) -> ACPParsedPackageCommand? {
        guard let atIndex = token.lastIndex(of: "@"), atIndex != token.startIndex else {
            // No version `@` at all. A leading `@` is a scoped package's
            // scope marker (`@scope/name`) — floating. A token that is ONLY
            // a version (`@1.2.3`, no name) is malformed.
            if token.hasPrefix("@") && !token.contains("/") { return nil }
            return ACPParsedPackageCommand(
                runner: runner, package: token, version: nil, trailingArguments: trailing)
        }
        // The character after `@` must not be empty — `pkg@` is malformed.
        guard token.index(after: atIndex) != token.endIndex else { return nil }
        let package = String(token[..<atIndex])
        let versionToken = String(token[token.index(after: atIndex)...])
        guard !package.isEmpty else { return nil }
        return ACPParsedPackageCommand(
            runner: runner,
            package: package,
            version: exactVersion(fromNPMSpec: versionToken),
            trailingArguments: trailing)
    }

    /// PyPI-style `name==version` (uvx). `name@version` is not valid uv tool
    /// syntax and is NOT accepted. A missing or non-exact spec yields
    /// `version == nil` (floating).
    private static func parseUVToken(
        _ token: String, trailing: [String]
    ) -> ACPParsedPackageCommand? {
        guard let pinRange = token.range(of: "==") else {
            // No `==` pin (or malformed) — floating; keep the token as the
            // package name so the shape is still inspectable.
            return ACPParsedPackageCommand(
                runner: .uvx, package: token, version: nil, trailingArguments: trailing)
        }
        let package = String(token[..<pinRange.lowerBound])
        let versionToken = String(token[pinRange.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        guard !package.isEmpty, SemanticAgentVersion(versionToken) != nil else {
            return ACPParsedPackageCommand(
                runner: .uvx, package: token, version: nil, trailingArguments: trailing)
        }
        return ACPParsedPackageCommand(
            runner: .uvx,
            package: package,
            version: ACPAgentVersion(rawValue: versionToken),
            trailingArguments: trailing)
    }

    /// The exact-version part of an npm spec token. Accepts plain semantic
    /// versions (`1.2.3`, `1.2`). Rejects tags (`latest`, `next`) and every
    /// range syntax (`^`, `~`, `>=`, `x`/`*` wildcards, shorthand major-only
    /// specs) — those are floating, so `nil`.
    private static func exactVersion(fromNPMSpec spec: String) -> ACPAgentVersion? {
        guard !spec.isEmpty else { return nil }
        let disallowed: Set<Character> = ["^", "~", ">", "<", "=", "*", "x", "X", " ", "|", "-", "/"]
        guard !spec.contains(where: disallowed.contains) else { return nil }
        guard SemanticAgentVersion(spec) != nil else { return nil }
        return ACPAgentVersion(rawValue: spec)
    }
}

// MARK: - Compatibility contracts

/// One verified adapter contract: the distribution package this app build
/// knows, the `agentInfo.name` identity a compliant candidate of that
/// package reports, and the version range this build can interpret.
/// The table is deliberately SMALL — an entry exists only after the reported
/// identity has been verified against real agent output. Packages without a
/// contract never auto-adopt (fail closed).
public struct ACPAdapterContract: Hashable, Codable, Sendable {
    /// The distribution package name (the join key between a parsed command
    /// and this contract).
    public let package: String
    /// The exact `InitializeResponse.agentInfo.name` a compliant candidate
    /// reports.
    public let reportedIdentity: ACPAgentIdentity
    /// The version range this build can interpret. `nil` = the contract
    /// verifies identity only; every exact version of the package is then
    /// probe-gated rather than version-gated.
    public let versions: ACPAgentVersionPredicate?

    public init(
        package: String,
        reportedIdentity: ACPAgentIdentity,
        versions: ACPAgentVersionPredicate? = nil
    ) {
        self.package = package
        self.reportedIdentity = reportedIdentity
        self.versions = versions
    }
}

/// The verified adapter contracts this app build carries, plus the support
/// classification derived from them.
public enum ACPAdapterCompatibility {
    /// The verified contract for the Codex ACP adapter: identity and version
    /// range come from the same constants the thinking-capability interpreter
    /// enforces, so adoption can never drift from interpretation.
    public static let contracts: [ACPAdapterContract] = [
        ACPAdapterContract(
            package: "@agentclientprotocol/codex-acp",
            reportedIdentity: CodexThinkingCapabilityAdapter.identity,
            versions: CodexThinkingCapabilityAdapter.supportedVersions)
    ]

    /// The contract for `package`, or `nil` when this build has none (the
    /// package is then unverified: visible, never auto-adopted).
    public static func contract(forPackage package: String) -> ACPAdapterContract? {
        contracts.first { $0.package == package }
    }

    /// The support class of an exact candidate spec:
    /// - `.knownSupported` — a verified contract exists and its version
    ///   predicate admits the version. Eligible for probe + auto-adoption.
    /// - `.unsupported` — a verified contract exists and its predicate
    ///   rejects the version (a future major). Visible, never auto-adopted.
    /// - `.unverified` — no contract for the package. Fail closed: visible,
    ///   never auto-adopted, until an app build ships the verified contract.
    public static func support(of candidate: ACPPackageSpec) -> ACPAdapterSupport {
        guard let contract = contract(forPackage: candidate.package) else { return .unverified }
        guard let versions = contract.versions else { return .knownSupported }
        return versions.contains(candidate.version) ? .knownSupported : .unsupported
    }
}

/// Whether this app build can interpret a candidate adapter version, and so
/// whether the candidate is eligible for automatic adoption.
public enum ACPAdapterSupport: Codable, Hashable, Sendable {
    /// A verified contract exists and admits the version.
    case knownSupported
    /// A verified contract exists and its predicate rejects the version —
    /// visible in Settings, never auto-adopted (the app update that widens
    /// the predicate unlocks adoption).
    case unsupported
    /// No verified contract for the package. Fail closed: visible, never
    /// auto-adopted.
    case unverified

    /// Whether automatic adoption may proceed for this support class.
    public var isAutoAdoptable: Bool {
        self == .knownSupported
    }
}

// MARK: - Decision

/// The upgrade decision for one stored provider against one registry entry.
/// PURE — `decide` performs no I/O and no spawning, so the whole table is
/// unit-tested without network or subprocess. Persisted as a provider's
/// recorded finding, hence `Codable`.
public enum ACPAdapterUpgradeDecision: Hashable, Codable, Sendable {
    /// The registry spec equals the stored spec (same shape, same exact
    /// version).
    case upToDate
    /// Nothing adoptable: the registry entry is missing, either command is
    /// not a package-runner launch (a plain binary such as `gemini --acp` is
    /// user-owned), the registry entry itself floats, or the package changed
    /// under the same agent id. The stored command is never touched.
    case notApplicable
    /// The registry publishes a strictly newer exact pin for the same
    /// package. `support` separates auto-adoptable from visible-only.
    case updateAvailable(target: ACPPackageSpec, support: ACPAdapterSupport)

    /// Decide for one provider. Inputs:
    /// - `storedCommand`: the provider's persisted spawn argv.
    /// - `registryCommand`: the registry entry's spawn argv for the SAME
    ///   agent id (nil when the registry has no entry — offline or unknown
    ///   agent → `.notApplicable`).
    ///
    /// Comparison rules (mirroring the plan + Paseo's no-silent-downgrade
    /// contract):
    /// - The registry side must parse as an EXACT pin; a floating registry
    ///   entry is never adoptable (no launch command is ever a floating tag).
    /// - A floating STORED package command (the legacy seeded shape) is
    ///   strictly less informed than any exact pin, so any exact registry pin
    ///   for the same package is "newer".
    /// - An exact stored spec that is NEWER than the registry keeps its
    ///   newer pin (`.upToDate` — no silent downgrades). An older or
    ///   malformed registry pin never replaces the stored command.
    public static func decide(
        storedCommand: [String]?,
        registryCommand: [String]?
    ) -> ACPAdapterUpgradeDecision {
        // Registry side: missing entry or unparseable command → no-op.
        guard let registryParsed = ACPPackageCommandParser.parse(registryCommand),
              let target = ACPPackageCommandParser.exactSpec(registryParsed) else {
            return .notApplicable
        }
        // Stored side: not a package-runner launch → user-owned plain binary.
        guard let storedParsed = ACPPackageCommandParser.parse(storedCommand) else {
            return .notApplicable
        }
        // A different package under the same agent id is a rename or fork —
        // never auto-swapped under the user.
        guard storedParsed.package == target.package else { return .notApplicable }

        guard let storedVersion = storedParsed.version else {
            // Floating stored command: any exact pin is an upgrade.
            return .updateAvailable(target: target, support: ACPAdapterCompatibility.support(of: target))
        }
        guard let storedSpec = ACPPackageCommandParser.exactSpec(storedParsed) else {
            // Unreachable: a parsed command with a version always yields a spec.
            return .notApplicable
        }
        // Identical pins (including trailing arguments) → nothing to do.
        if storedSpec == target { return .upToDate }
        // Same package, differing pins: only a strictly NEWER registry pin
        // counts. An older or semantically incomparable registry pin keeps
        // the stored (newer) command — no silent downgrades, fail closed on
        // incomparable pins.
        guard let storedSemantic = SemanticAgentVersion(storedVersion.rawValue),
              let targetSemantic = SemanticAgentVersion(target.version.rawValue),
              storedSemantic < targetSemantic else {
            return .upToDate
        }
        return .updateAvailable(target: target, support: ACPAdapterCompatibility.support(of: target))
    }
}
