import Cordis
import Foundation
import Testing

@Suite("Context hierarchy", .timeLimit(.minutes(1)))
struct ContextHierarchyTests {
    @Test("child reads parent and parent cannot read child")
    func childReadsParentNotViceVersa() async throws {
        let parentKey = ServiceKey<String>(label: "parent")
        let childKey = ServiceKey<Int>(label: "child")
        let parent = CordisContext()
        let child = try await parent.child()
        _ = try await parent.supply(parentKey, value: "ancestor")
        _ = try await child.supply(childKey, value: 42)

        #expect(try await child.require(parentKey) == "ancestor")
        #expect(try await parent.find(childKey) == nil)
    }

    @Test("child shadows ancestor without becoming a duplicate")
    func childShadowsAncestor() async throws {
        let key = ServiceKey<String>(label: "service")
        let parent = CordisContext()
        let child = try await parent.child()
        _ = try await parent.supply(key, value: "parent")
        _ = try await child.supply(key, value: "child")

        #expect(try await parent.require(key) == "parent")
        #expect(try await child.require(key) == "child")
    }

    @Test("parent disposal cascades children before parent effects")
    func parentDisposalCascadesChildren() async throws {
        let log = EventLog<String>()
        let parent = CordisContext()
        let child = try await parent.child()
        let parentComponent = try ComponentDefinition(label: "parent") { activation in
            _ = try await activation.effect { _ in await log.append("parent") }
        }
        let childComponent = try ComponentDefinition(label: "child") { activation in
            _ = try await activation.effect { _ in await log.append("child") }
        }
        let parentHandle = try await parent.register(parentComponent)
        let childHandle = try await child.register(childComponent)
        _ = try await parentHandle.awaitSettled()
        _ = try await childHandle.awaitSettled()

        try await parent.dispose()
        try await parent.dispose()

        #expect(await log.snapshot() == ["child", "parent"])
        #expect(try await parentHandle.state.kind == .disposed)
        #expect(try await childHandle.state.kind == .disposed)
        let afterDisposeKey = ServiceKey<String>(label: "after-dispose")
        await #expect(throws: CordisError.disposedContext(child.id)) {
            try await child.find(afterDisposeKey)
        }
        await #expect(throws: CordisError.disposedContext(child.id)) {
            try await child.require(afterDisposeKey)
        }
        await #expect(throws: CordisError.disposedContext(child.id)) {
            try await child.supply(afterDisposeKey, value: "value")
        }
        await #expect(throws: CordisError.disposedContext(child.id)) {
            try await child.register(try ComponentDefinition(label: "late") { _ in })
        }
        await #expect(throws: CordisError.disposedContext(child.id)) { try await child.child() }
        await #expect(throws: CordisError.disposedContext(child.id)) { try await child.diagnostics() }
        await #expect(throws: CordisError.disposedContext(child.id)) { try await childHandle.restart() }
        try await childHandle.dispose()
        try await child.dispose()
        #expect(try await childHandle.state.kind == .disposed)
    }
}
