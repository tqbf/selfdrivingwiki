import Testing
@testable import WikiFS

/// Tests for the mermaid injection in `AgentTranscriptWebView.Coordinator.shellHTML`.
///
/// `MermaidAsset.js` is `""` under `swift test` (no `.app` bundle), so the runtime
/// body cannot be asserted here. What CAN be asserted are the static structural
/// parts of the shell that were added for mermaid support.
///
/// `shellHTML` is `internal` (default access) on `Coordinator`; `@testable import`
/// makes it reachable without widening its visibility.
@MainActor
struct AgentTranscriptShellTests {

    private typealias Coordinator = AgentTranscriptWebView.Coordinator

    /// The shell always carries a `mermaid.initialize` call so the runtime is
    /// configured on first load (before any rows arrive via `appendRows`).
    @Test func shellContainsMermaidInitialize() {
        #expect(Coordinator.shellHTML.contains("mermaid.initialize("))
    }

    /// `securityLevel: 'strict'` is mandatory — prevents mermaid's historical XSS
    /// vector even for semi-trusted (agent-authored) diagram source.
    @Test func shellEnforcesStrictSecurityLevel() {
        #expect(Coordinator.shellHTML.contains("securityLevel: 'strict'"))
    }

    /// `appendRows` must call `mermaid.run` on unprocessed nodes after inserting
    /// new HTML, so diagrams in streamed rows render without re-rendering the
    /// already-rendered portion of the feed.
    @Test func shellRunsOnlyUnprocessedNodes() {
        #expect(Coordinator.shellHTML.contains("mermaid.run({ querySelector: '.mermaid:not([data-processed=\"true\"])' })"))
    }

    /// Every mermaid call is guarded by `if (window.mermaid)` so the transcript
    /// JavaScript does not throw when the runtime is absent (dev/test environments
    /// where `MermaidAsset.js` returns `""`).
    @Test func shellGuardsMermaidCalls() {
        #expect(Coordinator.shellHTML.contains("if (window.mermaid)"))
    }

    /// The runtime `<script>` tag must precede the init block so that classic-script
    /// execution order guarantees `window.mermaid` is defined before the initializer
    /// runs. Check that the tag is present in the shell.
    @Test func shellInjectsRuntimeScriptTag() {
        #expect(Coordinator.shellHTML.contains("<script>\(MermaidAsset.js)</script>"))
    }

    /// `window.scrollTo` must remain in `appendRows` (unchanged from before the
    /// mermaid wiring) so the feed still auto-scrolls after each append.
    @Test func shellPreservesScrollBehavior() {
        #expect(Coordinator.shellHTML.contains("window.scrollTo(0, document.body.scrollHeight)"))
    }
}
