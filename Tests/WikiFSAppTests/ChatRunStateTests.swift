import Testing
@testable import WikiFS

/// Exhaustive tests for `ChatRunState.from(...)` — the factory that maps the
/// daemon's three flat boolean flags into a single exclusive state, and for
/// `isActive`.
struct ChatRunStateTests {

    // MARK: - from(...) — all 8 boolean combinations

    @Test func from_idle_whenAllFalse() {
        #expect(ChatRunState.from(
            isRunning: false, isGenerating: false, isAwaitingSlot: false) == .idle)
    }

    @Test func from_queued_whenOnlyAwaiting() {
        #expect(ChatRunState.from(
            isRunning: false, isGenerating: false, isAwaitingSlot: true) == .queued)
    }

    @Test func from_thinking_whenOnlyRunning() {
        #expect(ChatRunState.from(
            isRunning: true, isGenerating: false, isAwaitingSlot: false) == .thinking)
    }

    @Test func from_thinking_whenRunningAndAwaiting() {
        // running wins over awaiting
        #expect(ChatRunState.from(
            isRunning: true, isGenerating: false, isAwaitingSlot: true) == .thinking)
    }

    @Test func from_generating_whenOnlyGenerating() {
        #expect(ChatRunState.from(
            isRunning: false, isGenerating: true, isAwaitingSlot: false) == .generating)
    }

    @Test func from_generating_whenGeneratingAndRunning() {
        // most-specific wins
        #expect(ChatRunState.from(
            isRunning: true, isGenerating: true, isAwaitingSlot: false) == .generating)
    }

    @Test func from_generating_whenAllTrue() {
        #expect(ChatRunState.from(
            isRunning: true, isGenerating: true, isAwaitingSlot: true) == .generating)
    }

    @Test func from_generating_whenGeneratingAndAwaiting() {
        #expect(ChatRunState.from(
            isRunning: false, isGenerating: true, isAwaitingSlot: true) == .generating)
    }

    // MARK: - isActive

    @Test func isActive_falseForIdleAndQueued() {
        #expect(ChatRunState.idle.isActive == false)
        #expect(ChatRunState.queued.isActive == false)
    }

    @Test func isActive_trueForThinkingAndGenerating() {
        #expect(ChatRunState.thinking.isActive == true)
        #expect(ChatRunState.generating.isActive == true)
    }
}
