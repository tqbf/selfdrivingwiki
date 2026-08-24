import Cordis
import Testing
import WikiFSTypes

@Suite("Cordis scope descriptors")
struct ContextScopeDescriptorTests {
    @Test("process and wiki descriptors use context identity")
    func processAndWikiDescriptorsUseContextIdentity() async throws {
        let root = try CordisContext(descriptor: .process(.app))
        let wikiID = WikiID(rawValue: "wiki-a")
        let child = try await root.child(descriptor: .wiki(wikiID))

        let rootSnapshot = try await root.scopeDiagnostics()
        let childSnapshot = try await child.scopeDiagnostics()

        #expect(rootSnapshot.contextID == root.id)
        #expect(rootSnapshot.descriptor == .process(.app))
        #expect(childSnapshot.contextID == child.id)
        #expect(childSnapshot.contextID != rootSnapshot.contextID)
        #expect(childSnapshot.descriptor == .wiki(wikiID))
    }

    @Test("parent descriptor uses the existing context tree")
    func parentDescriptorUsesExistingContextTree() async throws {
        let root = try CordisContext(descriptor: .process(.daemon))
        let child = try await root.child(descriptor: .wiki(WikiID(rawValue: "wiki-b")))

        let snapshot = try await child.scopeDiagnostics()

        #expect(snapshot.parentContextID == root.id)
        #expect(snapshot.parentDescriptor == .process(.daemon))
        #expect((try await root.scopeDiagnostics()).activeChildCount == 1)
    }

    @Test("descriptor validation permits only process to wiki")
    func validatesInitialParentMatrix() async throws {
        let standalone = CordisContext()
        let nested = try await standalone.child()
        await #expect(throws: ScopeDescriptorError.wikiRequiresProcessParent) {
            _ = try await nested.child(descriptor: .wiki(WikiID(rawValue: "wiki-c")))
        }

        let process = try CordisContext(descriptor: .process(.app))
        await #expect(throws: ScopeDescriptorError.processRequiresRoot) {
            _ = try await process.child(descriptor: .process(.daemon))
        }
        #expect(throws: ScopeDescriptorError.wikiRequiresProcessParent) {
            _ = try CordisContext(descriptor: .wiki(WikiID(rawValue: "wiki-d")))
        }
    }

    @Test("descriptor does not change disposal semantics")
    func descriptorDoesNotChangeDisposalSemantics() async throws {
        let root = try CordisContext(descriptor: .process(.app))
        let child = try await root.child(descriptor: .wiki(WikiID(rawValue: "wiki-e")))
        _ = try await child.supply(ServiceKey<Int>(label: "value"), value: 1)

        try await root.dispose()

        let snapshot = try await child.scopeDiagnostics()
        #expect(snapshot.lifecycle == .disposed)
        #expect(snapshot.activeRegistrationCount == 0)
        await #expect(throws: CordisError.disposedContext(child.id)) {
            _ = try await child.supply(ServiceKey<Int>(label: "late"), value: 2)
        }
    }
}
