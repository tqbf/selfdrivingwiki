#if os(macOS)
import Foundation
import WikiFSCore

/// The ACP extraction backend: delegates PDF→Markdown to a user-configured ACP
/// provider instead of making direct vendor-specific HTTP calls.
///
/// **Why this exists (issue #453):** The app migrated to an ACP-only
/// multi-provider architecture — every agent operation goes through
/// `ACPBackend` with a provider configured in Settings → Providers. But PDF
/// extraction was left behind with two hardcoded HTTP clients
/// (`AnthropicExtractionClient` / `GeminiExtractionClient`), each with its own
/// Keychain entry and config. This backend replaces those with a single path
/// that delegates to whichever ACP provider the user already configured.
///
/// **How it works:** The PDF is written to a unique staging directory, then an
/// `ACPBackend` session is started with the selected provider's spawn config +
/// Keychain API key (reused from `ACPCredentialStore`). The extraction prompt
/// references the staged file path; the ACP agent reads it using its native
/// file-reading capability and returns markdown. The text response is
/// collected from the `AgentEvent` stream. This works with ANY ACP provider —
/// Claude, Gemini, Hermes, Copilot, etc. — with zero new HTTP client code.
///
/// **Sandboxed (issue #1276):** the staging directory doubles as the seatbelt
/// scratch (`LLMSandboxScratch`), and the spawn runs read-only behind
/// `/usr/bin/sandbox-exec` — writes confined to the staging subtree, no wiki
/// database allowance. An unusable sandbox front-end fails closed: the start
/// error surfaces as `Error.spawnFailed` and nothing runs.
///
/// **No second secret:** the provider's API key is read from
/// `ACPCredentialStore`, the same Keychain store the chat/ingest path uses.
/// There is no `ExtractionCredentialStore` entry for the ACP backend — one
/// key, one config, one provider system.
///
/// The extraction system prompt (`ExtractionPrompts.system`) is passed as the
/// ACP session's system prompt (delivered via CLAUDE.md/AGENTS.md in the cwd
/// + first-turn injection). The extraction instruction + file path is the
/// single user turn.
public struct ACPExtractionClient: MarkdownExtractor {
    public enum Error: LocalizedError, Equatable {
        case noProviderConfigured
        case providerCommandMissing(String)
        case providerNotFound(String)
        case spawnFailed(String)
        case turnFailed(String)
        case emptyOutput
        case tooLarge(byteCount: Int)

        public var errorDescription: String? {
            switch self {
            case .noProviderConfigured:
                return "No ACP provider is configured. Set one up in Settings → Providers."
            case .providerCommandMissing(let label):
                return "Provider '\(label)' has no command configured. Fix it in Settings → Providers."
            case .providerNotFound(let id):
                return "Extraction provider '\(id)' not found. Check Settings → Providers."
            case .spawnFailed(let msg):
                return "Couldn't start the ACP agent for extraction: \(msg)"
            case .turnFailed(let msg):
                return "The ACP agent failed during extraction: \(msg)"
            case .emptyOutput:
                return "The ACP agent returned no markdown for this PDF."
            case .tooLarge(let n):
                return "PDF is too large for ACP extraction (\(n / 1_000_000) MB; the limit is 50 MB). Use Local pdf2md or Docling Serve."
            }
        }
    }

    /// PDFs above this size are rejected — the ACP prompt + file path add overhead,
    /// and agents have context limits. 50 MB matches Gemini's cap.
    public static let maxPDFBytes: Int = 48 * 1024 * 1024

    /// The resolved provider to use for extraction.
    public let provider: AgentProvider
    /// The resolved ACP spawn command (PATH-resolved executable + args).
    public let resolvedCommand: [String]
    /// The Keychain-backed API key for the provider (nil if none configured).
    public let apiKey: String?
    /// The user's per-provider model selection (nil = use provider default).
    public let selectedModelId: String?
    /// The permission policy (default: bypass — extraction is a one-shot
    /// transcription; the agent has no wiki to write to).
    public let permissionPolicy: PermissionPolicy
    /// The container directory (for config loads — unused here but kept for
    /// future use, e.g. per-wiki extraction config).
    public let containerDirectory: URL
    /// The backend factory for the one-shot extraction session. Injectable so
    /// tests can drive `convert` end-to-end with a fake backend or a failing
    /// start (issue #1276 error-mapping coverage); production uses
    /// `AgentBackendFactory`. Throws surface as `Error.spawnFailed`.
    public let backendFactory: @Sendable (PermissionPolicy) throws -> any AgentBackend

    public init(
        provider: AgentProvider,
        resolvedCommand: [String],
        apiKey: String?,
        selectedModelId: String? = nil,
        permissionPolicy: PermissionPolicy = .bypass,
        containerDirectory: URL,
        backendFactory: @escaping @Sendable (PermissionPolicy) throws -> any AgentBackend =
            { AgentBackendFactory.makeBackend(policy: $0) }
    ) {
        self.provider = provider
        self.resolvedCommand = resolvedCommand
        self.apiKey = apiKey
        self.selectedModelId = selectedModelId
        self.permissionPolicy = permissionPolicy
        self.containerDirectory = containerDirectory
        self.backendFactory = backendFactory
    }

    public var displayName: String {
        if let selectedModelId, !selectedModelId.isEmpty {
            return "\(provider.label) (\(selectedModelId))"
        }
        return provider.label
    }

    public func readiness() async -> ExtractionReadiness {
        guard !resolvedCommand.isEmpty else {
            return .needsSetup("Provider '\(provider.label)' has no command configured. Fix it in Settings → Providers.")
        }
        // A nil API key is NOT a hard blocker — many ACP agents (Hermes via
        // ~/.hermes, Claude via OAuth) self-authenticate without a
        // client-provided key. Let the spawn attempt and surface any error.
        return .ready
    }

    public func convert(
        pdfData: Data,
        filename: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> String {
        guard pdfData.count <= Self.maxPDFBytes else {
            throw Error.tooLarge(byteCount: pdfData.count)
        }

        // Write the PDF to a staging file the ACP agent can read from disk.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("wiki-extraction-\(UUID().uuidString)", isDirectory: true)
        // Issue #1276: the staging directory IS the sandbox scratch. The child
        // may write ONLY inside it (its `.tmp` temp root included); adoption
        // creates the `.tmp` leaf BEFORE the child starts and builds the
        // read-only invocation — no `WIKI_DB` define, no global temp allow.
        let scratch = try LLMSandboxScratch.adopt(directory: staging)
        let pdfPath = scratch.directoryURL.appendingPathComponent(filename)
        // Deferred cleanup after backend cancellation: `convert` returns only
        // after `backend.cancel(session)` has terminated the one-shot session,
        // so removing the tree here cannot race a live child.
        defer { scratch.remove() }

        do {
            try pdfData.write(to: pdfPath, options: .atomic)
        } catch {
            throw Error.spawnFailed("Could not stage the PDF for the agent: \(error.localizedDescription)")
        }

        onProgress?("Sending \(filename) (\(pdfData.count / 1024) KB) to \(provider.label)…\n")

        // Build the provider hints + backend profile (mirrors the launcher's
        // resolveACPProviderSpawn → AgentBackendFactory.providerHints pipeline).
        let hints = AgentBackendFactory.providerHints(
            provider: provider,
            resolvedCommand: resolvedCommand,
            apiKey: apiKey,
            selectedModelId: selectedModelId)
        let profile = Self.makeProfile(providerHints: hints, scratch: scratch)

        // Start a one-shot ACP session with the extraction system prompt. A
        // factory or start failure — including the fail-closed
        // `ACPBackendError.sandboxUnavailable` — surfaces as `.spawnFailed`.
        let backend: any AgentBackend
        let session: SessionHandle
        do {
            backend = try backendFactory(permissionPolicy)
            session = try await backend.start(
                profile: profile,
                systemPrompt: ExtractionPrompts.system,
                onExit: { _ in })
        } catch {
            throw Error.spawnFailed(error.localizedDescription)
        }

        // Send the extraction turn — the prompt references the temp PDF path.
        // The ACP agent reads the file using its native capability and returns
        // markdown. We collect all .assistantText / .result text from the
        // stream, then cancel the session.
        let promptText = """
        \(ExtractionPrompts.instruction)

        The PDF file is at: \(pdfPath.path)

        Read this PDF file and convert it to markdown following the system instructions above. \
        Output ONLY the markdown — no commentary, no code fences.
        """

        var collectedText = ""
        var turnError: String?
        let stream = await backend.send(TurnInput(userText: promptText), into: session)
        for await event in stream {
            switch event {
            case .assistantText(let text):
                collectedText += text
            case .assistantTextDelta(let text):
                collectedText += text
            case .result(let isError, let text):
                if isError {
                    turnError = text
                } else {
                    // The final result text may carry the full markdown (some
                    // agents emit everything in .result instead of streaming
                    // .assistantText). Append if we haven't already collected it.
                    if collectedText.isEmpty {
                        collectedText = text
                    }
                }
            case .turnFailed(let reason):
                turnError = reason.description
            default:
                break
            }
        }

        // Always cancel the session — it was a one-shot extraction.
        await backend.cancel(session)

        if let turnError {
            throw Error.turnFailed(turnError)
        }

        guard !collectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.emptyOutput
        }

        onProgress?("Done — \(collectedText.count) chars of markdown.\n")
        return collectedText
    }

    // MARK: - Provider resolution (pure, no side effects)

    /// The extraction spawn profile (issue #1276): read-only, sandboxed to the
    /// staging scratch, and NO wiki database — the extraction agent reads the
    /// staged PDF and returns Markdown; it never writes the wiki. Internal +
    /// pure so tests can pin the exact scratch/sandbox pairing without
    /// spawning a child.
    static func makeProfile(
        providerHints: [String: String],
        scratch: LLMSandboxScratch
    ) -> BackendProfile {
        BackendProfile(
            providerHints: providerHints,
            scratchDirectory: scratch.directoryURL,
            isReadOnly: true,
            sandbox: scratch.sandbox)
    }

    /// Resolve the ACP provider + spawn config for extraction from the user's
    /// `AgentProvidersConfig` + `ExtractionConfig`. If `extractionConfig.
    /// acpProviderId` is set, use that provider; otherwise fall back to the
    /// app's default provider. Returns nil if no enabled provider is available
    /// or the command can't be resolved on PATH.
    ///
    /// PURE + injectable (the `resolveCommand` closure) so the provider
    /// resolution + PATH preflight is unit-testable without spawning a
    /// subprocess or a login-shell hop. Mirrors `AgentLauncher.
    /// resolveACPProviderSpawn` but as a standalone function.
    public static func resolveProvider(
        containerDirectory: URL,
        acpProviderId: String? = nil,
        acpCredentialStore: any ACPCredentialStore = KeychainACPCredentialStore(),
        searchPath: String? = nil,
        resolveCommand: ((AgentProvider) -> [String]?)? = nil
    ) -> ACPExtractionClient? {
        let config = AgentProvidersConfig.loadOrSeed(from: containerDirectory)
        let commandResolver = resolveCommand ?? { provider in
            AgentLauncher.resolveCommand(for: provider, searchPath: searchPath)
        }

        // Use the explicitly-configured extraction provider if set + valid;
        // otherwise fall back to the app's selected (default) provider.
        let provider: AgentProvider
        if let id = acpProviderId, let p = config.provider(id: ProviderID(rawValue: id)), p.enabled {
            provider = p
        } else {
            provider = config.selectedProvider()
        }

        guard let resolvedCommand = commandResolver(provider) else {
            return nil
        }

        let apiKey = acpCredentialStore.apiKey(forProvider: provider.id.rawValue)
        let selectedModelId = config.selectedModelId(forProvider: provider.id)

        return ACPExtractionClient(
            provider: provider,
            resolvedCommand: resolvedCommand,
            apiKey: apiKey,
            selectedModelId: selectedModelId?.rawValue,
            containerDirectory: containerDirectory)
    }
}
#endif
