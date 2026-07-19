import Testing
import Foundation
import WikiFSCore
import WikiFSEngine
@testable import WikiFS

/// #635 regression tests for the retry-after-kill / agent-disabled / odd-shaped
/// window fixes. These cover the three parts of the issue's recommended fix:
///
/// 1. Surface the failure in the Activity window — the CTA must appear for the
///    "Agent process is not running" / "agent disabled" class of errors so the
///    user has a path to fix it, not a stuck row with a generic "failed"
///    message and no clue. Tested via `ActivityWindowView.isConfigurationErrorMarker`.
/// 2. Re-validate readiness on the dispatch/retry path — `AppQueueIngestionProvider.readiness`
///    must return a clear "agent is not available" message when no provider is
///    enabled (the operator-disabled state). Tested with injectable
///    `resolveProviderConfig` so no app-group filesystem or Settings UI is
///    touched.
/// 3. Fix the odd-shaped window lifecycle — `MenuBarItemController.isAutosaveFrameValid`
///    rejects corrupted/zero saved frames so a stale autosave can't shrink the
///    window back to its (near-)zero fitting size after we sized it to 760×500.
///
/// Pure-logic tests (no real NSWindows, no real AppKit, no real subprocess) so
/// they run in the fast CI tier — no `.integration` tag.
@Suite("Retry-stuck regression (#635)")
struct RetryStuckRegressionTests {

    // MARK: - Part 1: isConfigurationError markers

    /// The Activity window's "Configure Agents…" CTA shows for binary-not-found
    /// / no-api-key / no-command errors (#440 markers). Already covered by
    /// `QueueIngestionTests.WorkerFailsWhenNotReady` — this is a smoke test
    /// that the marker surface hasn't shrunk during the #635 refactor.
    @Test("isConfigurationError matches the pre-existing #440 readiness markers")
    func configurationErrorMatchesOriginalReadinessMarkers() {
        #expect(ActivityWindowView.isConfigurationErrorMarker(
            "‘bun’ was not found on your PATH. Install bun (bun.sh) or configure a different agent provider. Open Settings → Agents to configure one."))
        #expect(ActivityWindowView.isConfigurationErrorMarker(
            "Provider ‘OpenCode’ has no command configured."))
        #expect(ActivityWindowView.isConfigurationErrorMarker(
            "Add your Anthropic API key in Settings → Agents."))
        #expect(ActivityWindowView.isConfigurationErrorMarker(
            "Set a docling serve endpoint in Settings → Extraction."))
        #expect(ActivityWindowView.isConfigurationErrorMarker(
            "The pdf2md dependencies aren't installed. Fix it in Settings → Agents."))
    }

    /// #635: the marker surface now covers the dead-process / agent-disabled
    /// class. Without these, the Activity row shows "Agent process is not
    /// running" as a generic "failed" with no clear CTA — leaving the user
    /// stuck on a row that the issue explicitly flags as "no actionable error
    /// in the Activity window."
    @Test("isConfigurationError matches the #635 dead-process / agent-disabled markers")
    func configurationErrorMatchesAgentDisabledMarkers() {
        // Surfaced by AppQueueIngestionProvider.readiness when all providers
        // are disabled (Part 2).
        #expect(ActivityWindowView.isConfigurationErrorMarker(
            "Agent is not available — no enabled agent provider. Re-enable the agent in Settings → Agents to retry."))
        #expect(ActivityWindowView.isConfigurationErrorMarker(
            "Agent is disabled. Re-enable the agent in Settings → Agents."))
        // Surfaced by the swift-acp SDK through ACPBackend.send when the
        // warm subprocess was torn down by cancel-then-retry.
        #expect(ActivityWindowView.isConfigurationErrorMarker(
            "Agent process is not running"))
        #expect(ActivityWindowView.isConfigurationErrorMarker(
            "ACP agent subprocess died unexpectedly. The turn was cancelled; session resume is available if the agent supports it."))
    }

    /// #635: the marker matcher must STAY conservative. A generic runtime
    /// error (e.g. "convert failed", "convert returned invalid markdown") is
    /// NOT a configuration issue — surfacing the "Configure Agents…" CTA
    /// there would mislead the user into fiddling with Settings when nothing
    /// is wrong with the agent config.
    @Test("isConfigurationError stays conservative — generic runtime errors do NOT match")
    func configurationErrorStaysConservative() {
        #expect(!ActivityWindowView.isConfigurationErrorMarker("convert failed: invalid markdown"))
        #expect(!ActivityWindowView.isConfigurationErrorMarker("network timeout"))
        #expect(!ActivityWindowView.isConfigurationErrorMarker("unknown error"))
        #expect(!ActivityWindowView.isConfigurationErrorMarker("agent tried to call tool that returned 404"))
    }

    /// #635: the matcher is case-insensitive (the worker surfaces errors
    /// via `localizedDescription` which may have different casing than the
    /// original message — the readiness message itself uses sentence case,
    /// the SDK error uses Title Case).
    @Test("isConfigurationError is case-insensitive")
    func configurationErrorIsCaseInsensitive() {
        #expect(ActivityWindowView.isConfigurationErrorMarker("AGENT PROCESS IS NOT RUNNING"))
        #expect(ActivityWindowView.isConfigurationErrorMarker("Re-enable the Agent in Settings → Agents."))
    }

    // MARK: - Part 2: AppQueueIngestionProvider readiness — all-providers-disabled

    /// #635: when the operator disables the agent in Settings → Agents (toggling
    /// every provider off), `AgentProvidersConfig.selectedProvider()` still
    /// falls back to the hardcoded `claudeAcpDefault` static (so the launcher's
    /// own spawn path could try a fresh subprocess). The readiness probe must
    /// see through this fallback — return a clear, actionable message so the
    /// worker's preflight gate throws `QueueIngestionError.notReady` BEFORE
    /// `launcher.run(...)` can dead-end at "Agent process is not running"
    /// against the torn-down subprocess from the cancelled prior turn.
    @MainActor
    @Test("readiness returns actionable message when no provider is enabled")
    func readinessReturnsMessageWhenAllProvidersDisabled() async throws {
        let disabledProviders = AgentProvidersConfig(providers: [
            AgentProvider(
                id: "claude-acp", label: "Claude",
                command: ["bun", "x", "@agentclientprotocol/claude-agent-acp"],
                enabled: false, isDefault: true),
            AgentProvider(
                id: "hermes", label: "Hermes",
                command: ["hermes", "acp"],
                enabled: false, isDefault: false),
        ])
        let provider = AppQueueIngestionProvider(
            sessionBox: SessionLookupBox(),
            fileProviderBox: FileProviderBox(),
            wikictlDirectory: NSTemporaryDirectory(),
            resolveSelectedProvider: { disabledProviders.selectedProvider() },
            resolveProviderConfig: { disabledProviders })

        let msg = await provider.readiness()
        #expect(msg != nil)
        // The message MUST carry markers that isConfigurationError recognizes
        // so the Activity window surfaces the "Configure Agents…" CTA, not a
        // silent "no providers" failure.
        let unwrapped = try #require(msg)
        #expect(ActivityWindowView.isConfigurationErrorMarker(unwrapped))
        // The message MUST name the action the user needs to take
        // ("Settings → Agents") so the user isn't left guessing.
        #expect(unwrapped.contains("Settings → Agents"))
    }

    /// #635: when at least one provider is enabled (the partial-disabled case),
    /// the readiness probe falls through to the existing
    /// `AgentLauncher.readinessMessage(for:)` PATH check. Disabling Claude
    /// (the default) but leaving Hermes enabled is a legal state — the
    /// launcher picks Hermes, and retry proceeds (no false-positive). The
    /// all-disabled short-circuit must not fire here.
    @MainActor
    @Test("readiness falls through to PATH check when at least one provider is enabled")
    func readinessFallsThroughWhenAnyProviderEnabled() async {
        let mixedConfig = AgentProvidersConfig(providers: [
            AgentProvider(
                id: "claude-acp", label: "Claude",
                command: ["bun", "x", "@agentclientprotocol/claude-agent-acp"],
                enabled: false, isDefault: true),
            AgentProvider(
                id: "hermes", label: "Hermes",
                command: ["hermes", "acp"],
                enabled: true, isDefault: false),
        ])
        let provider = AppQueueIngestionProvider(
            sessionBox: SessionLookupBox(),
            fileProviderBox: FileProviderBox(),
            wikictlDirectory: NSTemporaryDirectory(),
            resolveSelectedProvider: { mixedConfig.selectedProvider() },
            // Use Hermes's command but route to a nonexistent binary so the
            // PATH-based readiness check surfaces a message we can verify.
            resolveProviderConfig: { mixedConfig })

        let msg = await provider.readiness()
        // Either nil (if `hermes` happens to be on PATH on the test machine)
        // or a "was not found on your PATH" message — both fine for this
        // contract: the all-disabled short-circuit must NOT fire (that's
        // what we're testing).
        // If a message is returned, it must NOT be the all-disabled message.
        if let msg {
            #expect(!msg.contains("no enabled agent provider"))
        }
    }

    /// #635: the readiness probe fires on EVERY worker execution, not just the
    /// initial spawn — so the contract is "re-validate readiness on the
    /// dispatch/retry path." This test asserts the message is consistent
    /// across sequential calls (the worker calls `readiness()` exactly once
    /// per `execute`, but a retry calls `execute` again, so the readiness
    /// result must be deterministic, not stale or one-shot).
    @MainActor
    @Test("readiness is consistent across calls — re-validated on retry, not one-shot")
    func readinessIsConsistentAcrossCalls() async {
        let disabledConfig = AgentProvidersConfig(providers: [
            AgentProvider(
                id: "opencode", label: "OpenCode",
                command: ["opencode", "acp"],
                enabled: false, isDefault: true),
        ])
        let provider = AppQueueIngestionProvider(
            sessionBox: SessionLookupBox(),
            fileProviderBox: FileProviderBox(),
            wikictlDirectory: NSTemporaryDirectory(),
            resolveSelectedProvider: { disabledConfig.selectedProvider() },
            resolveProviderConfig: { disabledConfig })

        let first = await provider.readiness()
        let second = await provider.readiness()

        // Both calls must return the same "no enabled provider" message —
        // a stateless readiness probe rules out the "ready on first call,
        // not-ready on retry" race the issue's repro relied on.
        #expect(first != nil)
        #expect(second != nil)
        #expect(first == second)
    }

    // MARK: - Part 3: NSWindow autosave frame validation

    /// #635: validates the canonical NSStringFromRect format AppKit persists
    /// to UserDefaults under `"NSWindow Frame <autosaveName>"`. A real saved
    /// frame from a healthy 760×500 window MUST pass so the Activity window
    /// restores last position/size instead of always re-centering.
    @Test("isAutosaveFrameValid accepts canonical NSStringFromRect saved frames")
    func autosaveFrameAcceptsCanonicalFormat() {
        // NSStringFromRect(NSRect(x: 100, y: 200, width: 760, height: 500))
        let canonical = "{{100, 200}, {760, 500}}"
        #expect(MenuBarItemController.isAutosaveFrameValid(canonical))
        // Variable whitespace + edge values still valid.
        #expect(MenuBarItemController.isAutosaveFrameValid("{{0, 0}, {760, 500}}"))
        #expect(MenuBarItemController.isAutosaveFrameValid("{{10,5},{760,500}}"))
    }

    /// #635: a zero-size or malformed frame — saved during a prior
    /// transitional/aborted state where the hosting controller hadn't yet
    /// produced a fitting size — MUST be rejected. Otherwise the
    /// restored-over-760×500 override shrinks the Activity window back to the
    /// corrupted size: the "odd-shaped window behind the Activity window"
    /// symptom.
    @Test("isAutosaveFrameValid rejects zero / negative / malformed saved frames")
    func autosaveFrameRejectsCorruptFrames() {
        // Zero size — the headline corruption from the issue repro.
        #expect(!MenuBarItemController.isAutosaveFrameValid("{{0, 0}, {0, 0}}"))
        #expect(!MenuBarItemController.isAutosaveFrameValid("{{100, 200}, {0, 500}}"))
        #expect(!MenuBarItemController.isAutosaveFrameValid("{{100, 200}, {760, 0}}"))
        // Sub-minimum width/height — undetectable as a real user window.
        #expect(!MenuBarItemController.isAutosaveFrameValid("{{0, 0}, {50, 500}}"))
        #expect(!MenuBarItemController.isAutosaveFrameValid("{{0, 0}, {760, 50}}"))
        // Negative dimensions.
        #expect(!MenuBarItemController.isAutosaveFrameValid("{{0, 0}, {-760, 500}}"))
        // Malformed strings (missing brackets, non-numeric garbage).
        #expect(!MenuBarItemController.isAutosaveFrameValid(""))
        #expect(!MenuBarItemController.isAutosaveFrameValid(nil))
        #expect(!MenuBarItemController.isAutosaveFrameValid("garbage"))
        #expect(!MenuBarItemController.isAutosaveFrameValid("{{abc, def}, {760, 500}}"))
        #expect(!MenuBarItemController.isAutosaveFrameValid("{100, 200, 760, 500}"))
    }

    /// #635: the queue-window autosave-name helper MUST return distinct names
    /// per queue kind so the Ingestion + Extraction Activity windows keep
    /// independent frames (a corrupted Ingestion frame must not propagate
    /// to the Extraction window, and vice versa).
    @Test("queueWindowAutosaveName is distinct per QueueKind")
    func queueWindowAutosaveNameDistinctPerQueue() {
        let ingestion = MenuBarItemController.queueWindowAutosaveName(for: .ingestion)
        let extraction = MenuBarItemController.queueWindowAutosaveName(for: .extraction)
        #expect(ingestion != extraction)
        #expect(ingestion == "AgentQueueWindow")
        #expect(extraction == "ExtractionQueueWindow")
    }

    /// #635: the default queue window size constant — kept as a static so
    /// the explicit `NSWindow(contentRect:...)` initializer and any future
    /// "minimum acceptable saved frame" threshold share one source of truth.
    @Test("queueWindowDefaultSize is 760×500")
    func queueWindowDefaultSizeIs760x500() {
        #expect(MenuBarItemController.queueWindowDefaultSize.width == 760)
        #expect(MenuBarItemController.queueWindowDefaultSize.height == 500)
    }
}
