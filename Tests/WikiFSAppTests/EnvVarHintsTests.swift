#if os(macOS)
import Testing
import Foundation
@testable import WikiFS

/// #738: tests for the per-provider env-var hints catalog surfaced under the
/// env-var editor. The hints are pure data — no SwiftUI rendering needed —
/// so these tests call `EnvVarHints.hints(forProviderID:)` directly.
///
/// The validation computed properties (`duplicateKeys`, `envSectionError`,
/// `canSave`) are private to `ProviderEditorView` and are exercised indirectly
/// via the build + manual validation in `make run`; the catalog coverage here
/// pins the key→hint mapping so a future regression can't silently drop the
/// `CLAUDE_CODE_EXECUTABLE` / `CODEX_PATH` guidance that #733/#737 rely on.
@Suite("EnvVarHints")
struct EnvVarHintsTests {

    // MARK: - Providers with known hints

    @Test func claudeAcpSurfacesClaudeCodeExecutable() {
        // #733: the Claude ACP provider must surface CLAUDE_CODE_EXECUTABLE so
        // users following the "set CLAUDE_CODE_EXECUTABLE" guidance can find
        // the exact key name without guessing.
        let hints = EnvVarHints.hints(forProviderID: "claude-acp")
        #expect(hints != nil)
        #expect(hints?.contains(where: { $0.key == "CLAUDE_CODE_EXECUTABLE" }) == true)
    }

    @Test func codexProviderSurfacesCodexPath() {
        // #737: a Codex provider (id "codex") must surface CODEX_PATH.
        let hints = EnvVarHints.hints(forProviderID: "codex")
        #expect(hints != nil)
        #expect(hints?.contains(where: { $0.key == "CODEX_PATH" }) == true)
    }

    @Test func geminiSurfacesGeminiApiKey() {
        let hints = EnvVarHints.hints(forProviderID: "gemini")
        #expect(hints != nil)
        #expect(hints?.contains(where: { $0.key == "GEMINI_API_KEY" }) == true)
    }

    @Test func gooseSurfacesGooseProvider() {
        let hints = EnvVarHints.hints(forProviderID: "goose")
        #expect(hints != nil)
        #expect(hints?.contains(where: { $0.key == "GOOSE_PROVIDER" }) == true)
    }

    // MARK: - Providers with no known hints

    @Test func hermesHasNoHints() {
        // Hermes has no app-specific env hints yet — nil so the editor shows
        // no hint line (rather than an empty "Common variables" block).
        #expect(EnvVarHints.hints(forProviderID: "hermes") == nil)
    }

    @Test func copilotHasNoHints() {
        #expect(EnvVarHints.hints(forProviderID: "copilot") == nil)
    }

    // MARK: - Custom / unknown providers

    @Test func customProviderHasNoHints() {
        #expect(EnvVarHints.hints(forProviderID: "custom") == nil)
    }

    @Test func unknownProviderHasNoHints() {
        #expect(EnvVarHints.hints(forProviderID: "totally-unknown") == nil)
    }

    // MARK: - Hint shape

    @Test func hintsAreNonEmptyAndHaveDescriptions() {
        // Every hint across every provider that returns non-nil must have a
        // non-empty key + description — an empty hint would render as a blank
        // line in the editor footer.
        let providerIDs = ["claude-acp", "gemini", "codex", "opencode", "goose"]
        for id in providerIDs {
            guard let hints = EnvVarHints.hints(forProviderID: id) else {
                Issue.record("Expected hints for provider \(id)")
                continue
            }
            #expect(!hints.isEmpty, "Hints for \(id) should not be empty")
            for hint in hints {
                #expect(!hint.key.isEmpty, "Hint key should not be empty for \(id)")
                #expect(!hint.description.isEmpty, "Description should not be empty for \(id)/\(hint.key)")
            }
        }
    }
}
#endif // os(macOS)
