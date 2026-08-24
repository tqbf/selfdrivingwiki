import Cordis
import Testing

@Suite("Invariant registry", .serialized, .timeLimit(.minutes(1)))
struct InvariantRegistryTests {
    @Test("validates selection and reserves owners in child contexts")
    func validatesSelectionAndReservesOwnersInChildContexts() async throws {
        let root = try CordisContext(descriptor: .process(.standalone))
        let sink = RecordingInvariantViolationSink()
        let registry = try InvariantRegistry(
            root: root,
            configuration: .init(allowlist: ["wiki.*"], blocklist: ["wiki.blocked"]),
            sink: sink)

        let selected = try await registry.register(.init(owner: "wiki.selected") { _ in })
        let blocked = try await registry.register(.init(owner: "wiki.blocked") { _ in })

        #expect(await registry.activeOwners() == ["wiki.selected"])
        #expect((try await root.scopeDiagnostics()).activeChildCount == 1)
        try await blocked.dispose()
        try await selected.dispose()
        try await selected.dispose()
        #expect(await registry.activeOwners().isEmpty)
    }

    @Test("rejects invalid filter patterns")
    func rejectsInvalidFilterPatterns() throws {
        let root = try CordisContext(descriptor: .process(.standalone))
        let sink = RecordingInvariantViolationSink()
        #expect(throws: InvariantRegistryError.blankPattern) {
            _ = try InvariantRegistry(root: root, configuration: .init(allowlist: [""]), sink: sink)
        }
        #expect(throws: InvariantRegistryError.paddedPattern(" wiki.*")) {
            _ = try InvariantRegistry(root: root, configuration: .init(allowlist: [" wiki.*"]), sink: sink)
        }
        #expect(throws: InvariantRegistryError.duplicatePattern("wiki.*")) {
            _ = try InvariantRegistry(
                root: root,
                configuration: .init(allowlist: ["wiki.*"], blocklist: ["wiki.*"]),
                sink: sink)
        }
        #expect(throws: InvariantRegistryError.invalidPattern("wiki.*.bad")) {
            _ = try InvariantRegistry(root: root, configuration: .init(allowlist: ["wiki.*.bad"]), sink: sink)
        }
    }

    @Test("failed installer disposes child before owner reuse")
    func failedInstallerDisposesChildBeforeOwnerReuse() async throws {
        struct Failure: Error {}
        let root = try CordisContext(descriptor: .process(.standalone))
        let registry = try InvariantRegistry(root: root, sink: RecordingInvariantViolationSink())
        let installer = InvariantInstaller(owner: "wiki.failure") { _ in throw Failure() }

        await #expect(throws: Error.self) { _ = try await registry.register(installer) }
        #expect((try await root.scopeDiagnostics()).activeChildCount == 0)

        let replacement = try await registry.register(.init(owner: "wiki.failure") { _ in })
        try await replacement.dispose()
    }

    @Test("cleanup failure releases owner after terminal disposal")
    func cleanupFailureReleasesOwner() async throws {
        struct CleanupFailure: Error {}
        let root = try CordisContext(descriptor: .process(.standalone))
        let registry = try InvariantRegistry(root: root, sink: RecordingInvariantViolationSink())
        let registration = try await registry.register(.init(owner: "wiki.cleanup-failure") { activation in
            _ = try await activation.effect { _ in throw CleanupFailure() }
        })

        await #expect(throws: CordisError.self) { try await registration.dispose() }
        #expect(await registry.activeOwners().isEmpty)

        let replacement = try await registry.register(.init(owner: "wiki.cleanup-failure") { _ in })
        try await replacement.dispose()
    }

    @Test("duplicate active owner is rejected")
    func duplicateActiveOwnerIsRejected() async throws {
        let root = try CordisContext(descriptor: .process(.standalone))
        let registry = try InvariantRegistry(root: root, sink: RecordingInvariantViolationSink())
        let registration = try await registry.register(.init(owner: "wiki.unique") { _ in })

        await #expect(throws: InvariantRegistryError.duplicateOwner("wiki.unique")) {
            _ = try await registry.register(.init(owner: "wiki.unique") { _ in })
        }
        try await registration.dispose()
    }
}
