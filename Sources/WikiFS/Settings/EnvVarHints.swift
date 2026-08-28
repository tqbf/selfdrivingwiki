import WikiFSCore

/// #738: per-provider "common env vars" hints surfaced under the env-var editor
/// so users configuring env-based fixes (e.g. `CLAUDE_CODE_EXECUTABLE` per #733,
/// `CODEX_PATH` per #737) don't have to guess exact key names.
///
/// A muted-hint approach (not autocomplete) — the issue explicitly calls a
/// simple muted list acceptable when autocomplete would be too heavy. The list
/// is deliberately short and provider-specific; generic browser-style env vars
/// (PATH, HOME) are NOT listed because the app already injects/manages those
/// (`ACPBackend.buildAgentEnv` owns WIKI_DB / WIKICTL / PATH).
///
/// #1159: API-key variables are NO LONGER suggested here. Known secret
/// variables (`ProviderSecretEnvironmentVariable`) are rejected by the env-var
/// editor and surface through the provider credential controls instead — an
/// env hint must never invite plaintext secret entry.
///
/// PURE + Sendable so it is unit-testable without rendering.
struct EnvVarHints {

    /// A single suggested key + a short one-line description of what it does.
    struct Hint: Sendable, Equatable {
        let key: String
        let description: String
    }

    /// Returns the suggested env-var hints for the given provider id, or `nil`
    /// when there are no known hints (the editor renders no hint line). The
    /// provider id follows `AgentProvider.id` / `KnownACPAgent.id` — e.g.
    /// "claude-acp", "gemini", "hermes", "codex", "custom".
    ///
    /// Every returned key is guaranteed non-secret: the factory filters out
    /// `ProviderSecretEnvironmentVariable` names so a future edit cannot
    /// re-introduce an API-key suggestion by accident.
    static func hints(forProviderID id: String) -> [Hint]? {
        let suggestions: [Hint]?
        switch id {
        case "claude-acp":
            suggestions = [
                .init(key: "CLAUDE_CODE_EXECUTABLE",
                      description: "Path to the `claude` binary when it is not on PATH."),
            ]
        case "gemini":
            suggestions = [
                .init(key: "GOOGLE_GENAI_USE_VERTEXAI",
                      description: "Set to \"1\" to use Vertex AI instead of the Gemini API."),
            ]
        case "codex":
            suggestions = [
                .init(key: "CODEX_PATH",
                      description: "Path to the `codex` binary when it is not on PATH."),
            ]
        case "goose":
            suggestions = [
                .init(key: "GOOSE_PROVIDER",
                      description: "The model provider Goose should use (e.g. \"anthropic\", \"openai\")."),
                .init(key: "GOOSE_MODEL",
                      description: "The model id Goose should use."),
            ]
        case "hermes", "copilot", "kimi", "cursor", "kiro", "grok",
             "codewhale", "kilo":
            // Known catalogs with no app-specific env hints yet — return nil so
            // the editor shows the generic guidance line instead.
            suggestions = nil
        default:
            // Custom / unknown provider ids: no provider-specific hints.
            suggestions = nil
        }
        // Contract: hints never suggest a known secret variable.
        return suggestions?.filter { !ProviderSecretEnvironmentVariable.isKnownSecret($0.key) }
    }
}
