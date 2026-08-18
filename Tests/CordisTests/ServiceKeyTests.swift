@testable import Cordis
import Foundation
import Testing

@Suite("Service keys", .timeLimit(.minutes(1)))
struct ServiceKeyTests {
    @Test("type identity separates values")
    func typeIdentitySeparatesValues() async throws {
        let identity = ServiceIdentity()
        let strings = ServiceKey<String>(identity: identity, label: "shared")
        let integers = ServiceKey<Int>(identity: identity, label: "shared")
        let context = CordisContext()

        #expect(strings.erased != integers.erased)
        _ = try await context.supply(strings, value: "value")

        #expect(try await context.find(strings) == "value")
        #expect(try await context.find(integers) == nil)
    }

    @Test("same identity and realm define one typed key")
    func sameIdentityAndRealmDefineOneTypedKey() {
        let identity = ServiceIdentity()
        let realm = ServiceRealm.isolated()
        let first = ServiceKey<String>(identity: identity, realm: realm, label: "first label")
        let second = ServiceKey<String>(identity: identity, realm: realm, label: "second label")

        #expect(first == second)
        #expect(Set([first, second]).count == 1)
    }

    @Test("realm separates the same value type")
    func realmSeparatesSameType() async throws {
        let identity = ServiceIdentity()
        let firstRealm = ServiceRealm.isolated()
        let secondRealm = ServiceRealm.isolated()
        let first = ServiceKey<String>(identity: identity, realm: firstRealm, label: "service")
        let second = ServiceKey<String>(identity: identity, realm: secondRealm, label: "service")
        let context = CordisContext()

        _ = try await context.supply(first, value: "first")

        #expect(try await context.find(first) == "first")
        #expect(try await context.find(second) == nil)
    }

    @Test("duplicate ambient supply is rejected")
    func duplicateAmbientSupplyIsRejected() async throws {
        let key = ServiceKey<String>(label: "service")
        let context = CordisContext()
        _ = try await context.supply(key, value: "first")

        await #expect(throws: CordisError.self) {
            try await context.supply(key, value: "second")
        }
    }

    @Test("component supply cannot replace an ambient provider")
    func componentSupplyCannotReplaceAmbientProvider() async throws {
        let key = ServiceKey<String>(label: "service")
        let context = CordisContext()
        _ = try await context.supply(key, value: "ambient")
        let definition = try ComponentDefinition(
            label: "component",
            provisions: [ServiceDependency(key)]) { activation in
                _ = try await activation.supply(key, value: "component")
            }
        let handle = try await context.register(definition)

        #expect(try await handle.awaitSettled().kind == .failed)
        #expect(try await context.require(key) == "ambient")
    }

    @Test("two component supplies cannot replace each other")
    func componentSupplyCannotReplaceComponentProvider() async throws {
        let key = ServiceKey<String>(label: "service")
        let context = CordisContext()
        let first = try ComponentDefinition(
            label: "first",
            provisions: [ServiceDependency(key)]) { activation in
                _ = try await activation.supply(key, value: "first")
            }
        let second = try ComponentDefinition(
            label: "second",
            provisions: [ServiceDependency(key)]) { activation in
                _ = try await activation.supply(key, value: "second")
            }
        let firstHandle = try await context.register(first)
        #expect(try await firstHandle.awaitSettled().kind == .active)
        let secondHandle = try await context.register(second)

        #expect(try await secondHandle.awaitSettled().kind == .failed)
        #expect(try await context.require(key) == "first")
    }
}
