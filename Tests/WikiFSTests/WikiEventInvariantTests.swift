import Cordis
import Foundation
import Testing
@testable import WikiFSCore

@Suite("Wiki event invariants")
struct WikiEventInvariantTests {
    @Test("records wrong wiki and non-increasing sequence")
    func recordsWrongWikiAndNonIncreasingSequence() {
        let sink = RecordingInvariantViolationSink()
        let wikiID = WikiID(rawValue: "bus-wiki")
        let observer = WikiEventDiagnosticObserver(busWikiID: wikiID, sink: sink)

        observer.observe(ResourceChangeEvent(
            wikiID: WikiID(rawValue: "wrong-wiki"),
            kind: .page,
            id: "page-1",
            change: .updated,
            seq: 2))
        observer.observe(ResourceChangeEvent(
            wikiID: wikiID,
            kind: .page,
            id: "page-2",
            change: .updated,
            seq: 2))

        #expect(sink.violations().map(\.code) == [
            InvariantCode(rawValue: "wiki.event.wrong-wiki"),
            InvariantCode(rawValue: "wiki.event.sequence"),
        ])
    }

    @Test("bus invokes diagnostics before asynchronous fan-out")
    func busInvokesDiagnosticsAtPublicationSeam() {
        let sink = RecordingInvariantViolationSink()
        let busWikiID = WikiID(rawValue: "bus-wiki")
        let observer = WikiEventDiagnosticObserver(busWikiID: busWikiID, sink: sink)
        let bus = WikiEventBus(wikiID: busWikiID, diagnosticObserver: observer)

        bus.emit(ResourceChangeEvent(
            wikiID: WikiID(rawValue: "wrong-wiki"),
            kind: .source,
            id: "source-1",
            change: .created))

        #expect(sink.violations().map(\.code) == [InvariantCode(rawValue: "wiki.event.wrong-wiki")])
    }

    @Test("older cleanup does not remove a newer observer")
    func diagnosticObserverRemovalUsesInstallationIdentity() {
        let busWikiID = WikiID(rawValue: "bus-wiki")
        let oldSink = RecordingInvariantViolationSink()
        let newSink = RecordingInvariantViolationSink()
        let bus = WikiEventBus(wikiID: busWikiID)
        let oldID = UUID()
        let newID = UUID()

        bus.installDiagnosticObserver(
            WikiEventDiagnosticObserver(busWikiID: busWikiID, sink: oldSink),
            id: oldID)
        bus.installDiagnosticObserver(
            WikiEventDiagnosticObserver(busWikiID: busWikiID, sink: newSink),
            id: newID)
        bus.removeDiagnosticObserver(id: oldID)
        bus.emit(ResourceChangeEvent(
            wikiID: WikiID(rawValue: "wrong-wiki"),
            kind: .source,
            id: "source-1",
            change: .created))

        #expect(oldSink.violations().isEmpty)
        #expect(newSink.violations().map(\.code) == [InvariantCode(rawValue: "wiki.event.wrong-wiki")])
    }
}
