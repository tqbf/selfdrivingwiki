import Cordis
import Testing

@Suite("Invariant violation sinks")
struct InvariantViolationSinkTests {
    @Test("records stable attributed violations")
    func recordsStableAttributedViolations() async {
        let sink = RecordingInvariantViolationSink()
        let violation = InvariantViolation(
            code: "wiki.identity.mismatch",
            owner: InvariantOwners.wikiIdentity,
            message: "The session wiki ID differs from the scope wiki ID.")

        sink.record(violation)

        #expect(sink.violations() == [violation])
    }

    @Test("production sink accepts nonthrowing delivery")
    func productionSinkUsesDebugLogSeam() async {
        let sink: any InvariantViolationSink = DebugLogInvariantViolationSink()
        sink.record(InvariantViolation(
            code: "scope.parent.invalid",
            owner: InvariantOwners.scopeLifecycle,
            message: "A wiki context does not have a process parent."))
    }
}
