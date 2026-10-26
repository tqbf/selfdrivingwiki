import Foundation
import WikiFSTypes

// MARK: - Load result

/// The outcome of reading `lint-pipelines.json` from the App Group container.
public enum LintPipelineLoadResult: Sendable, Equatable {
    /// The file decoded and passed full validation.
    case loaded(LintPipelineDocument)
    /// No file exists — the bundled defaults apply in memory (nothing is
    /// written back; the first explicit save materializes the file).
    case missingDefaults(LintPipelineDocument)
    /// The file exists but is invalid or unsupported. The document on disk is
    /// never replaced with defaults; the problems surface for the user.
    case invalid(document: LintPipelineDocument?, problems: [LintConfigProblem])
}

// MARK: - Loader

/// The lint pipeline configuration reader.
///
/// Reader discipline: the app's lint session is the sole reader in version 1.
/// Loading validates the COMPLETE document (duplicate ids, recipe references,
/// step kinds, prompt/executable presence, limits) before any snapshot is
/// published, so a run never starts against a half-valid file. No writer
/// exists in this version; any future app writer must replace the file
/// atomically, and any future second reader process must adopt the existing
/// config-store locking/notification discipline instead of ad hoc reads.
public enum LintPipelineStore {

    /// Load and fully validate from `directory` (the App Group container).
    public static func load(from directory: URL) -> LintPipelineLoadResult {
        let url = directory.appendingPathComponent(LintPipelineDocument.fileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missingDefaults(.bundledDefaults())
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .invalid(document: nil, problems: [
                .decodeFailed("could not read \(url.lastPathComponent): \(error)"),
            ])
        }
        return Self.decode(data, configurationDirectory: directory)
    }

    private static func decode(
        _ data: Data, configurationDirectory: URL?
    ) -> LintPipelineLoadResult {
        let document: LintPipelineDocument
        do {
            document = try JSONDecoder().decode(LintPipelineDocument.self, from: data)
        } catch {
            return .invalid(document: nil, problems: [
                .decodeFailed(String(describing: error)),
            ])
        }
        let problems = validate(document, configurationDirectory: configurationDirectory)
        guard problems.isEmpty else {
            return .invalid(document: document, problems: problems)
        }
        return .loaded(document)
    }

    /// Full-document validation. Pure — no filesystem access beyond what the
    /// caller supplies; `configurationDirectory` is used only to probe
    /// prompt/executable existence for file references.
    public static func validate(
        _ document: LintPipelineDocument, configurationDirectory: URL?
    ) -> [LintConfigProblem] {
        var problems: [LintConfigProblem] = []
        guard document.version == LintPipelineDocument.currentVersion else {
            return [.unsupportedVersion(document.version)]
        }
        guard !document.checkSteps.isEmpty else { return [.emptyStepList] }

        var stepIDs = Set<String>()
        for step in document.checkSteps {
            guard stepIDs.insert(step.id).inserted else {
                problems.append(.duplicateStepID(step.id))
                continue
            }
            validateExecution(
                step.execution, owner: step.id, configurationDirectory: configurationDirectory,
                into: &problems)
        }

        var recipeIDs = Set<String>()
        for recipe in document.repairRecipes {
            guard recipeIDs.insert(recipe.id).inserted else {
                problems.append(.duplicateRecipeID(recipe.id))
                continue
            }
            validateExecution(
                recipe.execution, owner: recipe.id, configurationDirectory: configurationDirectory,
                into: &problems)
            for validator in recipe.validators {
                validateExecution(
                    validator.execution, owner: "\(recipe.id)/validator/\(validator.id)",
                    configurationDirectory: configurationDirectory, into: &problems)
            }
        }
        return problems
    }

    /// Validate one execution block (check step, producer, or validator).
    public static func validateExecution(
        _ execution: LintStepExecution, owner: String,
        configurationDirectory: URL?, providers: AgentProvidersConfig? = nil,
        into problems: inout [LintConfigProblem]
    ) {
        switch execution.kind {
        case .decision:
            problems.append(.decisionModelsNotSupported(step: owner))
            return
        case .builtin:
            // Producers and validators use typed built-in names; check steps
            // use the analyzer's built-in checks. Both decode as strings and
            // are resolved (and rejected) at execution assembly.
            if let name = execution.builtin, name.isEmpty {
                problems.append(.unknownBuiltinProducer(name))
            }
        case .script:
            validateLimits(execution, owner: owner, into: &problems)
            guard let executable = execution.executable, !executable.isEmpty else {
                problems.append(.missingExecutable(path: "(empty)"))
                return
            }
            let url = resolvePath(executable, from: configurationDirectory)
            if !FileManager.default.fileExists(atPath: url.path) {
                problems.append(.missingExecutable(path: executable))
            }
        case .acp:
            validateLimits(execution, owner: owner, into: &problems)
            guard let prompt = execution.prompt, !prompt.isEmpty else {
                problems.append(.missingPrompt(reference: "(empty)"))
                return
            }
            if prompt.hasPrefix(LintBundledPrompt.prefix) {
                let name = String(prompt.dropFirst(LintBundledPrompt.prefix.count))
                if !LintBundledPrompt.exists(named: name) {
                    problems.append(.missingPrompt(reference: prompt))
                }
            } else {
                let url = resolvePath(prompt, from: configurationDirectory)
                if !FileManager.default.fileExists(atPath: url.path) {
                    problems.append(.missingPrompt(reference: prompt))
                }
            }
            if let providers {
                validateProviderOverride(execution, providers: providers, into: &problems)
            }
        }
    }

    /// Convenience wrapper returning problems for one execution block.
    public static func problems(
        forExecution execution: LintStepExecution, owner: String,
        configurationDirectory: URL?, providers: AgentProvidersConfig? = nil
    ) -> [LintConfigProblem] {
        var problems: [LintConfigProblem] = []
        validateExecution(execution, owner: owner, configurationDirectory: configurationDirectory,
                          providers: providers, into: &problems)
        return problems
    }

    private static func validateLimits(
        _ execution: LintStepExecution, owner: String, into problems: inout [LintConfigProblem]
    ) {
        do { _ = try LintExecutionLimits.validatedTimeout(execution.timeoutSeconds) }
        catch let problem as LintConfigProblem { problems.append(problem) }
        catch { problems.append(.decodeFailed("\(owner): \(error)")) }
        do { _ = try LintExecutionLimits.validatedOutputBytes(execution.maxOutputBytes) }
        catch let problem as LintConfigProblem { problems.append(problem) }
        catch { problems.append(.decodeFailed("\(owner): \(error)")) }
    }

    private static func validateProviderOverride(
        _ execution: LintStepExecution, providers: AgentProvidersConfig,
        into problems: inout [LintConfigProblem]
    ) {
        guard let providerID = execution.providerId else { return }
        guard let provider = providers.provider(id: providerID) else {
            problems.append(.unknownProvider(providerID.rawValue))
            return
        }
        guard provider.enabled else {
            problems.append(.disabledProvider(provider: providerID.rawValue))
            return
        }
        if let modelID = execution.modelId,
           !providers.cachedModels(forProvider: providerID).contains(where: { $0.modelId == modelID }) {
            problems.append(.unknownModel(provider: providerID.rawValue, model: modelID.rawValue))
        }
    }

    /// Resolve a config-relative (or absolute) path, canonicalizing symlinks
    /// so sandbox profiles and existence checks agree on the real location.
    public static func resolvePath(_ raw: String, from configurationDirectory: URL?) -> URL {
        let url: URL
        if raw.hasPrefix("/") {
            url = URL(fileURLWithPath: raw)
        } else {
            url = (configurationDirectory ?? FileManager.default.temporaryDirectory)
                .appendingPathComponent(raw)
        }
        return url.standardizedFileURL
    }
}

// MARK: - Bundled prompt references

/// `bundled:<name>` prompt references resolve to prompts shipped in the app
/// bundle (`prompts/*.md`, synced by `make prompts`).
public enum LintBundledPrompt {
    public static let prefix = "bundled:"

    /// The bundled prompt text for a reference, or nil when unknown.
    public static func text(named name: String) -> String? {
        switch name {
        case "lint-check": return PublicPrompts.lintCheck
        case "lint-repair": return PublicPrompts.lintRepair
        default: return nil
        }
    }

    static func exists(named name: String) -> Bool { text(named: name) != nil }
}
