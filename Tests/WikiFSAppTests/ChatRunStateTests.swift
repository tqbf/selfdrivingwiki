import Testing
@testable import WikiFS

/// Exhaustive tests for `ChatRunState.from(...)` — the factory that maps the
/// daemon's three flat boolean flags into a single exclusive state — and for
/// the two derived predicates the UI keys off.
///
/// The `from(...)` table is the whole point of this type: the previous version
/// lost information twice (see `ChatRunState`'s doc comment), so every one of
/// the eight boolean combinations is pinned here rather than sampled.
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

    @Test func from_warm_whenOnlyRunning() {
        // REGRESSION: this combination was mapped to `.thinking`. For an
        // interactive chat it is the ONLY way to spell "session alive, no turn
        // in flight" — `isGenerating` is set at turn start, so a real thinking
        // phase always has `isGenerating == true`. Calling it `.thinking` is
        // what taught the sidebar to badge a warm session as "responding…".
        #expect(ChatRunState.from(
            isRunning: true, isGenerating: false, isAwaitingSlot: false) == .warm)
    }

    @Test func from_queued_whenRunningAndAwaiting() {
        // REGRESSION: `isRunning` used to be tested BEFORE `isAwaitingSlot`, so
        // this combination — the actual shape of a queued turn, whose process
        // is alive while it waits for the gate — was reported as `.thinking`
        // and `isAwaitingGenerationSlot` read false exactly when it was true.
        #expect(ChatRunState.from(
            isRunning: true, isGenerating: false, isAwaitingSlot: true) == .queued)
    }

    @Test func from_answering_whenOnlyGenerating() {
        #expect(ChatRunState.from(
            isRunning: false, isGenerating: true, isAwaitingSlot: false) == .answering)
    }

    @Test func from_answering_whenGeneratingAndRunning() {
        // The ordinary in-flight turn: process alive + turn in flight.
        #expect(ChatRunState.from(
            isRunning: true, isGenerating: true, isAwaitingSlot: false) == .answering)
    }

    @Test func from_answering_whenGeneratingAndAwaiting() {
        #expect(ChatRunState.from(
            isRunning: false, isGenerating: true, isAwaitingSlot: true) == .answering)
    }

    @Test func from_answering_whenAllTrue() {
        // Narrowest claim wins.
        #expect(ChatRunState.from(
            isRunning: true, isGenerating: true, isAwaitingSlot: true) == .answering)
    }

    // MARK: - isLive — "render the streaming mirror, not the persisted rows"

    @Test func isLive_falseOnlyForIdle() {
        #expect(ChatRunState.idle.isLive == false)
        #expect(ChatRunState.queued.isLive == true)
        #expect(ChatRunState.warm.isLive == true)
        #expect(ChatRunState.answering.isLive == true)
    }

    // MARK: - isAnswering — "responding…", spinners, Stop

    @Test func isAnswering_trueOnlyForAnswering() {
        #expect(ChatRunState.idle.isAnswering == false)
        #expect(ChatRunState.queued.isAnswering == false)
        #expect(ChatRunState.warm.isAnswering == false)
        #expect(ChatRunState.answering.isAnswering == true)
    }

    @Test func isLiveAndIsAnswering_areDistinctForWarm() {
        // The invariant the whole enum exists to protect: a session can be live
        // without answering. Any code that uses one where it means the other
        // reintroduces the badge bug.
        #expect(ChatRunState.warm.isLive == true)
        #expect(ChatRunState.warm.isAnswering == false)
    }
}
