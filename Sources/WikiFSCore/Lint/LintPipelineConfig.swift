import Foundation
import WikiFSTypes

// MARK: - Configuration document (lint-pipelines.json)

/// The versioned pipeline configuration file stored beside
/// `agent-providers.json` in the App Group container. Version 1: an ordered
/// check-step array plus named repair recipes.
///
/// Load semantics (see `LintPipelineStore`): a missing file yields the bundled
/// defaults in memory; an invalid or unsupported-version file is NEVER
/// overwritten with defaults — the errors surface for the user to fix.
public struct LintPipelineDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let fileName = "lint-pipelines.json"

    public var version: Int
    public var checkSteps: [LintCheckStepConfig]
    public var repairRecipes: [LintRecipeConfig]

    public init(version: Int = LintPipelineDocument.currentVersion,
                checkSteps: [LintCheckStepConfig],
                repairRecipes: [LintRecipeConfig]) {
        self.version = version
        self.checkSteps = checkSteps
        self.repairRecipes = repairRecipes
    }

    enum CodingKeys: String, CodingKey {
        case version, checkSteps, repairRecipes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? LintPipelineDocument.currentVersion
        checkSteps = try c.decodeIfPresent([LintCheckStepConfig].self, forKey: .checkSteps) ?? []
        repairRecipes = try c.decodeIfPresent([LintRecipeConfig].self, forKey: .repairRecipes) ?? []
    }
}

// MARK: - Step/recipe kinds

/// How a check step or repair producer executes. `decision` decodes but
/// validates as an explicit error — typed decision models are deferred until
/// the provider contract exposes them (the operator-approved deferral).
public enum LintStepKind: String, Codable, Sendable {
    case builtin = "built-in"
    case script
    case acp
    case decision
}

/// A producer's implementation name for `kind == .built-in` recipes.
public enum LintBuiltinProducer: String, Codable, Sendable {
    /// Exact wiki-link bracket correction for the selected finding.
    case bracketCorrection = "bracket-correction"
    /// One markdownlint `fixInfo` edit for the selected cosmetic finding.
    case cosmeticIndividualFix = "cosmetic-individual-fix"
    /// Remove a broken link while keeping its readable text.
    case removeBrokenLink = "remove-broken-link"
    /// Replace a broken link with a verified existing target.
    case verifiedReplacement = "verified-replacement"
    /// Delete a redundant footnote definition (identical label + bytes to
    /// the retained definition) for the selected footnote finding.
    case redundantFootnoteDeletion = "redundant-footnote-deletion"
    /// Canonicalize a uniquely-resolving source name to its typed id,
    /// preserving pin, fragment, alias, and visible text.
    case sourceCanonicalization = "source-canonicalization"
    /// The encoding-only quote edit for a verified citation correspondence.
    case citationEncodingFix = "citation-encoding-fix"
}

/// A built-in validator implementation name.
public enum LintBuiltinValidator: String, Codable, Sendable {
    /// All replacements validate (bounds, boundaries, expected old text).
    case replacementBounds = "replacement-bounds"
    /// Passage repairs stay inside the finding's approved ranges.
    case passageScope = "passage-scope"
    /// Fenced-code integrity: no replacement touches bytes inside a fence.
    case fenceIntegrity = "fence-integrity"
}

// MARK: - Step configuration

/// One executable unit shared by check steps, repair producers, and
/// validators: a built-in name, a script invocation, or an ACP model pass.
public struct LintStepExecution: Codable, Equatable, Sendable {
    public var kind: LintStepKind
    /// `kind == .builtin`: the closed built-in implementation name.
    public var builtin: String?
    /// `kind == .script`: executable URL. Relative paths resolve against the
    /// configuration directory; never interpolated shell text.
    public var executable: String?
    /// `kind == .script`: fixed argument array passed verbatim.
    public var arguments: [String]?
    /// `kind == .acp`: the prompt reference — `bundled:<name>` for a bundled
    /// prompt, otherwise a path relative to the configuration directory.
    public var prompt: String?
    /// `kind == .acp`: explicit provider override. nil = the legacy `lint`
    /// pin, then the global default provider chain.
    public var providerId: ProviderID?
    /// `kind == .acp`: explicit model override. nil = the provider's
    /// configured/default model.
    public var modelId: ModelID?
    /// Wall-clock budget. Falls back to `LintExecutionLimits.defaults`.
    public var timeoutSeconds: Int?
    /// Hard cap on collected output bytes (stdout / ACP text).
    public var maxOutputBytes: Int?

    enum CodingKeys: String, CodingKey {
        case kind, builtin, executable, arguments, prompt
        case providerId, modelId, timeoutSeconds, maxOutputBytes
    }

    public init(
        kind: LintStepKind,
        builtin: String? = nil,
        executable: String? = nil,
        arguments: [String]? = nil,
        prompt: String? = nil,
        providerId: ProviderID? = nil,
        modelId: ModelID? = nil,
        timeoutSeconds: Int? = nil,
        maxOutputBytes: Int? = nil
    ) {
        self.kind = kind
        self.builtin = builtin
        self.executable = executable
        self.arguments = arguments
        self.prompt = prompt
        self.providerId = providerId
        self.modelId = modelId
        self.timeoutSeconds = timeoutSeconds
        self.maxOutputBytes = maxOutputBytes
    }
}

/// One entry in the ordered check-step array.
public struct LintCheckStepConfig: Codable, Equatable, Sendable {
    public var id: String
    public var enabled: Bool
    public var execution: LintStepExecution

    enum CodingKeys: String, CodingKey {
        case id, enabled
        case kind, builtin, executable, arguments, prompt
        case providerId, modelId, timeoutSeconds, maxOutputBytes
    }

    public init(id: String, enabled: Bool = true, execution: LintStepExecution) {
        self.id = id
        self.enabled = enabled
        self.execution = execution
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        execution = try LintStepExecution(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(enabled, forKey: .enabled)
        try execution.encode(to: encoder)
    }
}

/// One optional validator on a repair recipe. Validators inspect the
/// candidate and may approve, reject, or report uncertainty; they can never
/// broaden or rewrite the repair. `required` validators block Apply on
/// failure; optional failures are recorded visibly.
public struct LintValidatorConfig: Codable, Equatable, Sendable {
    public var id: String
    public var required: Bool
    public var execution: LintStepExecution

    enum CodingKeys: String, CodingKey {
        case id, required
        case kind, builtin, executable, arguments, prompt
        case providerId, modelId, timeoutSeconds, maxOutputBytes
    }

    public init(id: String, required: Bool = true, execution: LintStepExecution) {
        self.id = id
        self.required = required
        self.execution = execution
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? true
        execution = try LintStepExecution(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(required, forKey: .required)
        try execution.encode(to: encoder)
    }
}

/// One named repair recipe: what the user picks, the instruction the producer
/// receives, one proposal producer, and ordered optional validators.
public struct LintRecipeConfig: Codable, Equatable, Sendable {
    public var id: String
    /// User-facing option label shown on findings.
    public var label: String
    /// The specific instruction template the producer receives for this repair.
    public var instruction: String
    public var execution: LintStepExecution
    public var validators: [LintValidatorConfig]

    enum CodingKeys: String, CodingKey {
        case id, label, instruction
        case kind, builtin, executable, arguments, prompt
        case providerId, modelId, timeoutSeconds, maxOutputBytes
        case validators
    }

    public init(
        id: String,
        label: String,
        instruction: String,
        execution: LintStepExecution,
        validators: [LintValidatorConfig] = []
    ) {
        self.id = id
        self.label = label
        self.instruction = instruction
        self.execution = execution
        self.validators = validators
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        instruction = try c.decodeIfPresent(String.self, forKey: .instruction) ?? ""
        execution = try LintStepExecution(from: decoder)
        validators = try c.decodeIfPresent([LintValidatorConfig].self, forKey: .validators) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(instruction, forKey: .instruction)
        try execution.encode(to: encoder)
        try c.encode(validators, forKey: .validators)
    }
}

// MARK: - Execution limits

/// Typed execution budgets. Every step's configured values are validated
/// against these bounds before launch.
public enum LintExecutionLimits {
    public static let minTimeoutSeconds = 1
    public static let maxTimeoutSeconds = 1800
    public static let defaultTimeoutSeconds = 300
    public static let minOutputBytes = 64
    public static let maxOutputBytes = 4 * 1024 * 1024
    public static let defaultOutputBytes = 256 * 1024
    /// Cap on findings one step may report (oversized output is a failure).
    public static let maxFindingsPerStep = 200

    public static func validatedTimeout(_ raw: Int?) throws -> Int {
        let value = raw ?? defaultTimeoutSeconds
        guard value >= minTimeoutSeconds, value <= maxTimeoutSeconds else {
            throw LintConfigProblem.invalidLimit(
                name: "timeoutSeconds", value: value,
                allowed: minTimeoutSeconds...maxTimeoutSeconds)
        }
        return value
    }

    public static func validatedOutputBytes(_ raw: Int?) throws -> Int {
        let value = raw ?? defaultOutputBytes
        guard value >= minOutputBytes, value <= maxOutputBytes else {
            throw LintConfigProblem.invalidLimit(
                name: "maxOutputBytes", value: value,
                allowed: minOutputBytes...maxOutputBytes)
        }
        return value
    }
}

// MARK: - Configuration problems

/// The typed, user-actionable validation errors for a pipeline document.
public enum LintConfigProblem: Error, Equatable, Sendable, LocalizedError {
    case unsupportedVersion(Int)
    case duplicateStepID(String)
    case duplicateRecipeID(String)
    case missingRecipe(referenced: String, by: String)
    case unsupportedStepKind(String)
    case unknownBuiltinProducer(String)
    case unknownBuiltinValidator(String)
    case missingPrompt(reference: String)
    case missingExecutable(path: String)
    case invalidLimit(name: String, value: Int, allowed: ClosedRange<Int>)
    case unknownProvider(String)
    case unknownModel(provider: String, model: String)
    case disabledProvider(provider: String)
    /// Decision-model steps decode but never run: the current provider
    /// contract exposes text streams, not typed decisions.
    case decisionModelsNotSupported(step: String)
    case decodeFailed(String)
    case emptyStepList

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v):
            return "lint-pipelines.json: unsupported version \(v) (supported: \(LintPipelineDocument.currentVersion)). Fix or remove the file; it is never overwritten automatically."
        case .duplicateStepID(let id):
            return "lint-pipelines.json: duplicate check step id '\(id)'."
        case .duplicateRecipeID(let id):
            return "lint-pipelines.json: duplicate repair recipe id '\(id)'."
        case .missingRecipe(let referenced, let by):
            return "lint-pipelines.json: step '\(by)' references missing repair recipe '\(referenced)'."
        case .unsupportedStepKind(let kind):
            return "lint-pipelines.json: unsupported step kind '\(kind)'."
        case .unknownBuiltinProducer(let name):
            return "lint-pipelines.json: unknown built-in producer '\(name)'."
        case .unknownBuiltinValidator(let name):
            return "lint-pipelines.json: unknown built-in validator '\(name)'."
        case .missingPrompt(let reference):
            return "lint-pipelines.json: prompt '\(reference)' not found (relative paths resolve from the configuration directory)."
        case .missingExecutable(let path):
            return "lint-pipelines.json: executable '\(path)' not found (relative paths resolve from the configuration directory)."
        case .invalidLimit(let name, let value, let allowed):
            return "lint-pipelines.json: \(name) = \(value) outside allowed range \(allowed.lowerBound)…\(allowed.upperBound)."
        case .unknownProvider(let id):
            return "lint-pipelines.json: provider '\(id)' is not configured."
        case .unknownModel(let provider, let model):
            return "lint-pipelines.json: model '\(model)' is not in provider '\(provider)' catalog."
        case .disabledProvider(let id):
            return "lint-pipelines.json: provider '\(id)' is configured but disabled. Enable it in Settings or remove the override."
        case .decisionModelsNotSupported(let step):
            return "lint-pipelines.json: step '\(step)' uses kind 'decision', which this version does not support. Use kind 'acp'."
        case .decodeFailed(let detail):
            return "lint-pipelines.json: \(detail)"
        case .emptyStepList:
            return "lint-pipelines.json: no check steps configured."
        }
    }
}

// MARK: - Bundled defaults

public extension LintPipelineDocument {
    /// The in-memory defaults when no configuration file exists. Mirrors the
    /// documented schema; never written back to disk by the lint session.
    static func bundledDefaults() -> LintPipelineDocument {
        LintPipelineDocument(
            checkSteps: [
                LintCheckStepConfig(
                    id: "builtin-wiki-links",
                    execution: LintStepExecution(kind: .builtin, builtin: "wiki-links")),
                LintCheckStepConfig(
                    id: "builtin-markdown-cosmetics",
                    execution: LintStepExecution(kind: .builtin, builtin: "markdown-cosmetics")),
                LintCheckStepConfig(
                    id: "builtin-truncation",
                    execution: LintStepExecution(kind: .builtin, builtin: "truncated-output")),
                LintCheckStepConfig(
                    id: "builtin-citations",
                    execution: LintStepExecution(kind: .builtin, builtin: "wiki-citations")),
                LintCheckStepConfig(
                    id: "builtin-footnotes",
                    execution: LintStepExecution(kind: .builtin, builtin: "footnotes")),
                LintCheckStepConfig(
                    id: "builtin-table-structure",
                    execution: LintStepExecution(kind: .builtin, builtin: "table-structure")),
                LintCheckStepConfig(
                    id: "builtin-history",
                    execution: LintStepExecution(kind: .builtin, builtin: "history")),
                LintCheckStepConfig(
                    id: "model-page-review",
                    enabled: true,
                    execution: LintStepExecution(
                        kind: .acp, prompt: "bundled:lint-check",
                        timeoutSeconds: LintExecutionLimits.defaultTimeoutSeconds,
                        maxOutputBytes: LintExecutionLimits.defaultOutputBytes)),
            ],
            repairRecipes: [
                LintRecipeConfig(
                    id: "bracket-correction",
                    label: "Fix bracket syntax",
                    instruction: "Apply the exact wiki-link bracket correction for the selected finding.",
                    execution: LintStepExecution(kind: .builtin, builtin: "bracket-correction"),
                    validators: [
                        LintValidatorConfig(id: "bounds", execution: LintStepExecution(kind: .builtin, builtin: "replacement-bounds")),
                        LintValidatorConfig(id: "scope", execution: LintStepExecution(kind: .builtin, builtin: "passage-scope")),
                        LintValidatorConfig(id: "fences", execution: LintStepExecution(kind: .builtin, builtin: "fence-integrity")),
                    ]),
                LintRecipeConfig(
                    id: "cosmetic-fix",
                    label: "Apply cosmetic fix",
                    instruction: "Apply the exact cosmetic markdown edit for the selected finding.",
                    execution: LintStepExecution(kind: .builtin, builtin: "cosmetic-individual-fix"),
                    validators: [
                        LintValidatorConfig(id: "bounds", execution: LintStepExecution(kind: .builtin, builtin: "replacement-bounds")),
                        LintValidatorConfig(id: "scope", execution: LintStepExecution(kind: .builtin, builtin: "passage-scope")),
                    ]),
                LintRecipeConfig(
                    id: "remove-broken-link",
                    label: "Remove broken link (keep text)",
                    instruction: "Remove the broken link markup, retaining the readable display text.",
                    execution: LintStepExecution(kind: .builtin, builtin: "remove-broken-link"),
                    validators: [
                        LintValidatorConfig(id: "bounds", execution: LintStepExecution(kind: .builtin, builtin: "replacement-bounds")),
                        LintValidatorConfig(id: "fences", execution: LintStepExecution(kind: .builtin, builtin: "fence-integrity")),
                    ]),
                LintRecipeConfig(
                    id: "verified-replacement",
                    label: "Replace with verified target",
                    instruction: "Replace the broken link with a link to the verified existing target named in the selected option.",
                    execution: LintStepExecution(kind: .builtin, builtin: "verified-replacement"),
                    validators: [
                        LintValidatorConfig(id: "bounds", execution: LintStepExecution(kind: .builtin, builtin: "replacement-bounds")),
                        LintValidatorConfig(id: "fences", execution: LintStepExecution(kind: .builtin, builtin: "fence-integrity")),
                    ]),
                LintRecipeConfig(
                    id: "redundant-footnote-deletion",
                    label: "Remove redundant footnote",
                    instruction: "Delete the redundant footnote definition exactly as the "
                        + "selected finding's validated range names it. Its content is "
                        + "byte-identical to the retained definition.",
                    execution: LintStepExecution(kind: .builtin, builtin: "redundant-footnote-deletion"),
                    validators: [
                        LintValidatorConfig(id: "bounds", execution: LintStepExecution(kind: .builtin, builtin: "replacement-bounds")),
                        LintValidatorConfig(id: "fences", execution: LintStepExecution(kind: .builtin, builtin: "fence-integrity")),
                    ]),
                LintRecipeConfig(
                    id: "source-canonicalization",
                    label: "Canonicalize to source id",
                    instruction: "Replace the citation's name target with the source's typed "
                        + "id exactly as the selected finding's validated range names it. "
                        + "Preserve the pin, fragment, alias, and visible text.",
                    execution: LintStepExecution(kind: .builtin, builtin: "source-canonicalization"),
                    validators: [
                        LintValidatorConfig(id: "bounds", execution: LintStepExecution(kind: .builtin, builtin: "replacement-bounds")),
                        LintValidatorConfig(id: "fences", execution: LintStepExecution(kind: .builtin, builtin: "fence-integrity")),
                    ]),
                LintRecipeConfig(
                    id: "citation-encoding-fix",
                    label: "Fix quote encoding",
                    instruction: "Apply the encoding-only quote edit for the selected finding: "
                        + "replace the quote text with its verified resolvable form. Change no "
                        + "wording, source identity, or pin.",
                    execution: LintStepExecution(kind: .builtin, builtin: "citation-encoding-fix"),
                    validators: [
                        LintValidatorConfig(id: "bounds", execution: LintStepExecution(kind: .builtin, builtin: "replacement-bounds")),
                        LintValidatorConfig(id: "scope", execution: LintStepExecution(kind: .builtin, builtin: "passage-scope")),
                        LintValidatorConfig(id: "fences", execution: LintStepExecution(kind: .builtin, builtin: "fence-integrity")),
                    ]),
                LintRecipeConfig(
                    id: "model-repair",
                    label: "Repair with model",
                    instruction: "Produce a patch for exactly the selected option. Change nothing else.",
                    execution: LintStepExecution(
                        kind: .acp, prompt: "bundled:lint-repair",
                        timeoutSeconds: LintExecutionLimits.defaultTimeoutSeconds,
                        maxOutputBytes: LintExecutionLimits.defaultOutputBytes),
                    validators: [
                        LintValidatorConfig(id: "bounds", execution: LintStepExecution(kind: .builtin, builtin: "replacement-bounds")),
                        LintValidatorConfig(id: "scope", execution: LintStepExecution(kind: .builtin, builtin: "passage-scope")),
                        LintValidatorConfig(id: "fences", execution: LintStepExecution(kind: .builtin, builtin: "fence-integrity")),
                    ]),
            ])
    }
}
