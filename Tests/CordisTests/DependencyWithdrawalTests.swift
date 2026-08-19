import Cordis
import Foundation
import Testing

@Suite("Dependency withdrawal", .timeLimit(.minutes(1)))
struct DependencyWithdrawalTests {
    @Test("transitive dependents drain leaf first with provider visibility")
    func withdrawalDrainsTransitiveDependentsLeafFirst() async throws {
        let rootKey = ServiceKey<String>(label: "root")
        let middleKey = ServiceKey<Int>(label: "middle")
        let leafKey = ServiceKey<Bool>(label: "leaf")
        let context = CordisContext()
        let log = EventLog<String>()

        let middle = try ComponentDefinition(
            label: "middle",
            dependencies: [ServiceDependency(rootKey)],
            provisions: [ServiceDependency(middleKey)]) { activation in
                _ = try await activation.require(rootKey)
                _ = try await activation.supply(middleKey, value: 1)
                _ = try await activation.effect { cleanup in
                    let root = try await cleanup.require(rootKey)
                    let ownSupply = try await cleanup.find(middleKey)
                    await log.append("middle:\(root):own=\(ownSupply == nil)")
                }
            }
        let leaf = try ComponentDefinition(
            label: "leaf",
            dependencies: [ServiceDependency(middleKey)],
            provisions: [ServiceDependency(leafKey)]) { activation in
                _ = try await activation.require(middleKey)
                _ = try await activation.supply(leafKey, value: true)
                _ = try await activation.effect { cleanup in
                    let middle = try await cleanup.require(middleKey)
                    let ownSupply = try await cleanup.find(leafKey)
                    await log.append("leaf:\(middle):own=\(ownSupply == nil)")
                }
            }
        let middleHandle = try await context.register(middle)
        let leafHandle = try await context.register(leaf)
        let rootProvider = try await context.supply(rootKey, value: "root-value")
        #expect(try await middleHandle.awaitSettled().kind == .active)
        #expect(try await leafHandle.awaitSettled().kind == .active)

        try await rootProvider.dispose()

        #expect(await log.snapshot() == ["leaf:1:own=true", "middle:root-value:own=true"])
        #expect(try await context.find(middleKey) == nil)
        #expect(try await context.find(leafKey) == nil)
        #expect(try await middleHandle.state.kind == .pending)
        #expect(try await leafHandle.state.kind == .pending)
    }

    @Test("direct provider-component disposal reactivates against an ancestor fallback")
    func componentDisposalReactivatesAncestorFallback() async throws {
        let key = ServiceKey<String>(label: "service")
        let root = CordisContext()
        _ = try await root.supply(key, value: "ancestor")
        let child = try await root.child()
        let observations = EventLog<String>()
        let localProvider = try ComponentDefinition(
            label: "local provider",
            provisions: [ServiceDependency(key)]) { activation in
                _ = try await activation.supply(key, value: "local")
            }
        let consumer = try ComponentDefinition(
            label: "consumer",
            dependencies: [ServiceDependency(key)]) { activation in
                await observations.append(try await activation.require(key))
            }
        let providerHandle = try await child.register(localProvider)
        #expect(try await providerHandle.awaitSettled().kind == .active)
        let consumerHandle = try await child.register(consumer)
        #expect(try await consumerHandle.awaitSettled().kind == .active)
        #expect(await observations.snapshot() == ["local"])

        try await providerHandle.dispose()

        #expect(try await providerHandle.state.kind == .disposed)
        #expect(try await consumerHandle.awaitSettled().kind == .active)
        #expect(await observations.snapshot() == ["local", "ancestor"])
        #expect(try await child.require(key) == "ancestor")
    }

    @Test("replacement provider reactivates direct and transitive dependents")
    func replacementReactivatesDependents() async throws {
        let rootKey = ServiceKey<String>(label: "root")
        let middleKey = ServiceKey<Int>(label: "middle")
        let context = CordisContext()
        let middleActivations = Counter()
        let leafActivations = Counter()

        let middle = try ComponentDefinition(
            label: "middle",
            dependencies: [ServiceDependency(rootKey)],
            provisions: [ServiceDependency(middleKey)]) { activation in
                let value = try await activation.require(rootKey)
                await middleActivations.increment()
                _ = try await activation.supply(middleKey, value: value.count)
            }
        let leaf = try ComponentDefinition(
            label: "leaf",
            dependencies: [ServiceDependency(middleKey)]) { activation in
                _ = try await activation.require(middleKey)
                await leafActivations.increment()
            }
        let middleHandle = try await context.register(middle)
        let leafHandle = try await context.register(leaf)
        let first = try await context.supply(rootKey, value: "one")
        _ = try await middleHandle.awaitSettled()
        _ = try await leafHandle.awaitSettled()

        try await first.dispose()
        _ = try await context.supply(rootKey, value: "second")
        #expect(try await middleHandle.awaitSettled().kind == .active)
        #expect(try await leafHandle.awaitSettled().kind == .active)
        #expect(await middleActivations.get() == 2)
        #expect(await leafActivations.get() == 2)
        #expect(try await context.require(middleKey) == 6)
    }
}
