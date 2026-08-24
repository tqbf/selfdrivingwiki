#if os(macOS)
import Cordis
import Testing
import WikiFSTypes
@testable import WikiFSEngine

@Suite("Wiki scope identity snapshots")
struct WikiScopeIdentitySnapshotTests {
    @Test("matching app identities record no violations")
    func matchesDescriptorSessionStoreBusAndDatabaseIdentity() async throws {
        let wikiID = WikiID(rawValue: "wiki-match")
        let process = try CordisContext(descriptor: .process(.app))
        let wiki = try await process.child(descriptor: .wiki(wikiID))
        let snapshot = WikiScopeIdentitySnapshot(
            scope: try await wiki.scopeDiagnostics(),
            profileWikiID: wikiID,
            sessionWikiID: wikiID,
            storeWikiID: wikiID,
            eventBusWikiID: wikiID,
            databaseWikiID: wikiID,
            host: .app)
        let sink = RecordingInvariantViolationSink()

        snapshot.validate(sink: sink)

        #expect(sink.violations().isEmpty)
    }

    @Test("mismatched daemon identities record attributed violations")
    func mismatchesDeliverViolations() async throws {
        let wikiID = WikiID(rawValue: "wiki-scope")
        let wrong = WikiID(rawValue: "wiki-wrong")
        let process = try CordisContext(descriptor: .process(.daemon))
        let wiki = try await process.child(descriptor: .wiki(wikiID))
        let snapshot = WikiScopeIdentitySnapshot(
            scope: try await wiki.scopeDiagnostics(),
            profileWikiID: wrong,
            sessionWikiID: wrong,
            storeWikiID: wrong,
            eventBusWikiID: wrong,
            databaseWikiID: wrong,
            host: .daemon(cacheKey: wrong))
        let sink = RecordingInvariantViolationSink()

        snapshot.validate(sink: sink)

        #expect(sink.violations().count == 6)
        #expect(sink.violations().allSatisfy { $0.owner == InvariantOwners.wikiIdentity })
    }
}
#endif
