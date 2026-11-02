#if os(macOS)
import Testing
import Foundation
import ACPModel
import WikiFSCore
@testable import WikiFSEngine

/// Round-5 confirm-or-fall-back (#1481 review): whether a RESUMED session can
/// be trusted to run on the chat's pinned model after
/// `ACPBackend.applyModelIfNeeded`. Pure decision table — no live agent
/// subprocess. The launcher wiring itself is only reachable with a live ACP
/// agent (`ACPBackend` is an actor: no subclass seam; the `FakeAgentBackend`
/// harness is not an `ACPBackend`), a gap documented in the progress file.
@Suite struct ACPResumeModelConfirmationTests {

    // MARK: - resumedSessionModelConfirmed (the decision table)

    /// nil requested = agent-default is the chat's selection: confirmed, and
    /// the reported current model is irrelevant.
    @Test func nilRequestedIsConfirmed() {
        #expect(ACPBackend.resumedSessionModelConfirmed(
            requestedModelId: nil,
            currentModelId: nil,
            appliedConfigOptionValue: nil))
        #expect(ACPBackend.resumedSessionModelConfirmed(
            requestedModelId: nil,
            currentModelId: "some-other-model",
            appliedConfigOptionValue: nil))
    }

    /// Empty requested behaves like nil (mirrors the resolvers' no-selection
    /// posture): agent-default, confirmed.
    @Test func emptyRequestedIsConfirmed() {
        #expect(ACPBackend.resumedSessionModelConfirmed(
            requestedModelId: "",
            currentModelId: nil,
            appliedConfigOptionValue: nil))
    }

    /// A non-nil requested with NO reported model state is NOT confirmed: an
    /// agent that reports no model state cannot be trusted to have switched.
    @Test func nilCurrentWithRequestedIsNotConfirmed() {
        #expect(ACPBackend.resumedSessionModelConfirmed(
            requestedModelId: "fake-model",
            currentModelId: nil,
            appliedConfigOptionValue: nil) == false)
    }

    /// The setModel path's outcome: a refreshed `modelsInfo.currentModelId`
    /// equal to the requested id confirms the switch.
    @Test func equalCurrentIsConfirmed() {
        #expect(ACPBackend.resumedSessionModelConfirmed(
            requestedModelId: "fake-model",
            currentModelId: "fake-model",
            appliedConfigOptionValue: nil))
    }

    /// A stale current (the old model still reported) is NOT confirmed — the
    /// HIGH finding this round fixes: a no-op apply leaves the session on the
    /// old model, and the daemon keeps the resume id on model-only switches.
    @Test func differentCurrentIsNotConfirmed() {
        #expect(ACPBackend.resumedSessionModelConfirmed(
            requestedModelId: "fake-model",
            currentModelId: "old-model",
            appliedConfigOptionValue: nil) == false)
    }

    /// The #834 config-option path's outcome: a patched `"model"` select
    /// confirms even when `modelsInfo` is absent (config-option agents may not
    /// advertise ModelsInfo at all).
    @Test func configOptionOutcomeConfirmsWithoutModelsInfo() {
        #expect(ACPBackend.resumedSessionModelConfirmed(
            requestedModelId: "fake-model",
            currentModelId: nil,
            appliedConfigOptionValue: "fake-model"))
        #expect(ACPBackend.resumedSessionModelConfirmed(
            requestedModelId: "fake-model",
            currentModelId: nil,
            appliedConfigOptionValue: "other-value") == false)
    }

    // MARK: - Effort-variant normalization (round 6)

    /// The config-option resolver normalizes effort variants: a picker pin
    /// like `gpt-5.6-luna[high]` may validly apply as the base
    /// `gpt-5.6-luna` when the agent advertises only the base. The outcome
    /// must confirm so the resumed session (and its context) is kept.
    @Test func normalizedConfigOptionApplyIsConfirmed() {
        #expect(ACPBackend.resumedSessionModelConfirmed(
            requestedModelId: "gpt-5.6-luna[high]",
            currentModelId: nil,
            appliedConfigOptionValue: "gpt-5.6-luna"))
    }

    /// Already-current-base: the agent already runs the base of the pin, so
    /// the apply was a legitimate no-op — the modelsInfo record confirms.
    @Test func alreadyCurrentBaseOutcomeIsConfirmed() {
        #expect(ACPBackend.resumedSessionModelConfirmed(
            requestedModelId: "gpt-5.6-luna[high]",
            currentModelId: "gpt-5.6-luna",
            appliedConfigOptionValue: nil))
    }

    /// An exactly-advertised variant still confirms by exact id.
    @Test func exactVariantOutcomeIsConfirmed() {
        #expect(ACPBackend.resumedSessionModelConfirmed(
            requestedModelId: "gpt-5.6-luna[high]",
            currentModelId: "gpt-5.6-luna[high]",
            appliedConfigOptionValue: nil))
        #expect(ACPBackend.resumedSessionModelConfirmed(
            requestedModelId: "gpt-5.6-luna[high]",
            currentModelId: nil,
            appliedConfigOptionValue: "gpt-5.6-luna[high]"))
    }

    /// A DIFFERENT base id never confirms — normalization must not accept an
    /// unrelated model as the pin's outcome.
    @Test func differentBaseStaysNotConfirmed() {
        #expect(ACPBackend.resumedSessionModelConfirmed(
            requestedModelId: "gpt-5.6-luna[high]",
            currentModelId: "gpt-5.6-codex",
            appliedConfigOptionValue: nil) == false)
        #expect(ACPBackend.resumedSessionModelConfirmed(
            requestedModelId: "gpt-5.6-luna[high]",
            currentModelId: nil,
            appliedConfigOptionValue: "gpt-5.6-codex") == false)
    }

    // MARK: - modelConfigOptionCurrentValue (the config-option evidence read)

    /// The `"model"` select's patched currentValue is surfaced for the
    /// confirmation check (mirrors `resolveConfigOptionModel`'s id match).
    @Test func modelConfigOptionValueIsExtracted() {
        let options = [
            SessionConfigOption(
                id: SessionConfigId("model"),
                name: "Model",
                description: nil,
                category: nil,
                kind: .select(SessionConfigSelect(
                    currentValue: SessionConfigValueId("fake-model"),
                    options: .ungrouped([]))),
                _meta: nil),
            SessionConfigOption(
                id: SessionConfigId("thought_level"),
                name: "Thinking",
                description: nil,
                category: nil,
                kind: .select(SessionConfigSelect(
                    currentValue: SessionConfigValueId("high"),
                    options: .ungrouped([]))),
                _meta: nil),
        ]
        #expect(ACPBackend.modelConfigOptionCurrentValue(in: options) == "fake-model")
        #expect(ACPBackend.modelConfigOptionCurrentValue(in: []) == nil)
    }
}
#endif
