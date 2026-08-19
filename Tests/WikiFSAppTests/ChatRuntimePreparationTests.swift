#if os(macOS)
import Foundation
import Testing
@testable import WikiFSEngine
import WikiFSCore

@Suite struct ChatRuntimePreparationTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var callsValue: [String] = []
        private var diagnosticsValue: [String] = []
        private var optionValue = ThinkingEffortOption(
            configId: "reasoning_mode",
            currentValue: "low",
            choices: [
                .init(value: "low", label: "Low"),
                .init(value: "high", label: "High"),
            ])

        func snapshot() -> ThinkingEffortOption {
            lock.withLock {
                callsValue.append("config-snapshot:\(optionValue.currentValue)")
                return optionValue
            }
        }

        func apply(_ optionID: ChatConfigurationOptionID, _ valueID: ChatConfigurationValueID) {
            lock.withLock {
                callsValue.append("thinking-set:\(optionID.rawValue)=\(valueID.rawValue)")
                optionValue = optionValue.withCurrentValue(valueID.rawValue)
            }
        }

        func reject(_ optionID: ChatConfigurationOptionID, _ valueID: ChatConfigurationValueID) throws {
            lock.withLock {
                callsValue.append("thinking-set:\(optionID.rawValue)=\(valueID.rawValue)")
            }
            throw PreparationError.rejected
        }

        func submit() { lock.withLock { callsValue.append("provider-submit") } }
        func diagnose(_ message: String) { lock.withLock { diagnosticsValue.append(message) } }
        var state: (calls: [String], diagnostics: [String]) {
            lock.withLock { (callsValue, diagnosticsValue) }
        }
    }

    private enum PreparationError: Error { case rejected }

    private let request = ResolvedThinkingConfiguration(
        optionID: ChatConfigurationOptionID(rawValue: "reasoning_mode"),
        desiredValueID: ChatConfigurationValueID(rawValue: "high"),
        priorEffectiveValueID: ChatConfigurationValueID(rawValue: "low"))

    @Test func firstTurnOrdersSnapshotThenThinkingThenSubmit() async {
        let recorder = Recorder()
        let confirmed = await AgentLauncher.resolveAndApplyThinkingConfiguration(
            request,
            snapshot: { recorder.snapshot() },
            apply: { optionID, valueID in recorder.apply(optionID, valueID) },
            diagnostic: { recorder.diagnose($0) })
        recorder.submit()

        #expect(confirmed == ChatConfigurationValueID(rawValue: "high"))
        #expect(recorder.state.calls == [
            "config-snapshot:low",
            "thinking-set:reasoning_mode=high",
            "config-snapshot:high",
            "provider-submit",
        ])
        #expect(recorder.state.diagnostics.isEmpty)
    }

    @Test func modelVariantChangesModelWithoutThinkingConfigCall() async {
        let recorder = Recorder()
        let request = ResolvedThinkingConfiguration(
            modelID: ModelID(rawValue: "gpt[high]"),
            desiredValueID: ChatConfigurationValueID(rawValue: "high"),
            priorEffectiveValueID: ChatConfigurationValueID(rawValue: "low"))
        let confirmed = await AgentLauncher.resolveAndApplyThinkingConfiguration(
            request,
            snapshot: { nil },
            apply: { optionID, valueID in recorder.apply(optionID, valueID) },
            diagnostic: { recorder.diagnose($0) })
        #expect(confirmed == ChatConfigurationValueID(rawValue: "high"))
        #expect(recorder.state.calls.isEmpty)
        #expect(recorder.state.diagnostics.isEmpty)
    }

    @Test func postModelLiveACPOverridesAdapterMechanism() async {
        let recorder = Recorder()
        let request = ResolvedThinkingConfiguration(
            modelID: ModelID(rawValue: "gpt[high]"),
            desiredValueID: ChatConfigurationValueID(rawValue: "high"),
            priorEffectiveValueID: ChatConfigurationValueID(rawValue: "low"))
        let confirmed = await AgentLauncher.resolveAndApplyThinkingConfiguration(
            request,
            snapshot: { recorder.snapshot() },
            apply: { optionID, valueID in recorder.apply(optionID, valueID) },
            diagnostic: { recorder.diagnose($0) })
        #expect(confirmed == ChatConfigurationValueID(rawValue: "high"))
        #expect(recorder.state.calls == [
            "config-snapshot:low",
            "thinking-set:reasoning_mode=high",
            "config-snapshot:high",
        ])
    }

    @Test func rejectionPreservesPriorEffectiveAndRecordsDiagnostic() async {
        let recorder = Recorder()
        let confirmed = await AgentLauncher.resolveAndApplyThinkingConfiguration(
            request,
            snapshot: { recorder.snapshot() },
            apply: { optionID, valueID in try recorder.reject(optionID, valueID) },
            diagnostic: { recorder.diagnose($0) })

        #expect(confirmed == ChatConfigurationValueID(rawValue: "low"))
        #expect(recorder.state.calls == [
            "config-snapshot:low",
            "thinking-set:reasoning_mode=high",
        ])
        #expect(recorder.state.diagnostics.contains { $0.contains("rejected") })
    }
}
#endif
