import Cordis
import Testing

@Suite("Scope diagnostics snapshots")
struct ScopeDiagnosticsSnapshotTests {
    @Test("returns immutable metadata without context exposure")
    func returnsImmutableMetadataWithoutContextExposure() async throws {
        let root = try CordisContext(descriptor: .process(.standalone))
        let key = ServiceKey<String>(label: "ambient")
        _ = try await root.supply(key, value: "value")

        let snapshot = try await root.scopeDiagnostics()

        #expect(snapshot.contextID == root.id)
        #expect(snapshot.parentContextID == nil)
        #expect(snapshot.lifecycle == .live)
        #expect(snapshot.activeRegistrationCount == 1)
        #expect(snapshot.retainedComponentRecordCount == 0)
        #expect(snapshot.activeChildCount == 0)
    }
}
