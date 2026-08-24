import Foundation
import Cordis

// The private lock protects all mutable sequence state. Sink calls occur after the lock is released.
// swiftlint:disable:next unchecked_sendable
public final class WikiEventDiagnosticObserver: @unchecked Sendable {
    private let busWikiID: WikiID
    private let owner: InvariantOwner
    private let sink: any InvariantViolationSink
    private let lock = NSLock()
    private var lastSequence: UInt64?

    public init(
        busWikiID: WikiID,
        owner: InvariantOwner = InvariantOwners.wikiEvents,
        sink: any InvariantViolationSink
    ) {
        self.busWikiID = busWikiID
        self.owner = owner
        self.sink = sink
    }

    public func observe(_ event: ResourceChangeEvent) {
        var violations: [InvariantViolation] = []
        lock.lock()
        if event.wikiID != busWikiID {
            violations.append(InvariantViolation(
                code: "wiki.event.wrong-wiki",
                owner: owner,
                message: "Event wiki ID \(event.wikiID.rawValue) differs from bus wiki ID \(busWikiID.rawValue)."))
        }
        if let lastSequence, event.seq <= lastSequence {
            violations.append(InvariantViolation(
                code: "wiki.event.sequence",
                owner: owner,
                message: "Event sequence \(event.seq) does not increase after \(lastSequence)."))
        }
        lastSequence = event.seq
        lock.unlock()

        for violation in violations {
            sink.record(violation)
        }
    }
}
