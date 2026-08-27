import Foundation
import Testing
@testable import WikiFSEngine
@testable import WikiFSExtractorStore
@testable import WikiFSCore

@Suite("Extractor catalog wakes", .serialized, .timeLimit(.minutes(3)))
struct ExtractorCatalogWakeTests {
    @Test func publicationWakesOnceAndSilentMutationsDoNot() async throws {
        let environment = try await GeneratedPluginFixtures.InstalledEnvironment.install()
        defer { environment.cleanup() }

        let counter = WakeCounter()
        let writer = try ExtractorPackageCatalogWriter.testing(
            layout: environment.layout,
            postWake: { counter.increment() })

        // A published generation is the only thing worth waking readers for.
        let emptied = try await writer.replaceCatalog(expectedGeneration: 1, records: [])
        #expect(emptied.generation == 2)
        #expect(counter.value == 1)

        // Removing an absent revision publishes nothing, so it wakes nobody.
        let unchanged = try await writer.remove(revision: environment.revision)
        #expect(unchanged.generation == 2)
        #expect(counter.value == 1)

        // Recovery that finds nothing to change also publishes nothing.
        let recovered = try await writer.recover()
        #expect(recovered.generation == 2)
        #expect(counter.value == 1)
    }

    @Test func wakesDuringOnePassCollapseIntoExactlyOneMorePass() async throws {
        let box = CoalescerBox()
        let passes = PassCounter()
        let coalescer = ExtractorCatalogWakeCoalescer {
            let pass = await passes.record()
            guard pass == 1 else { return }
            // Both arrive while the first pass is draining, so they set one
            // pending bit rather than starting two more passes. Hint delivery
            // never waits, so neither call can stall the pass it interrupts.
            await box.value?.receiveWake(waitForQuiescence: false)
            await box.value?.receiveWake(waitForQuiescence: false)
        }
        box.value = coalescer

        await coalescer.receiveWake()

        #expect(await passes.count == 2)
    }

    @Test func reinstallingTheSameRevisionPublishesNothingAndWakesNobody() async throws {
        let environment = try await GeneratedPluginFixtures.InstalledEnvironment.install()
        defer { environment.cleanup() }

        let counter = WakeCounter()
        let writer = try ExtractorPackageCatalogWriter.testing(
            layout: environment.layout,
            postWake: { counter.increment() })

        // Re-importing the exact revision already installed is idempotent: it
        // publishes no generation, so it must not wake any reader.
        let reimported = try await writer.importDirectory(
            environment.sourcePackageRoot,
            installedAt: RFC3339Timestamp(date: Date()))
        #expect(reimported.generation == 1)
        #expect(counter.value == 0)
    }

    @Test func stoppedObserverAcceptsNoFurtherPasses() async throws {
        let passes = PassCounter()
        let observer = ExtractorCatalogWakeObserver { _ = await passes.record() }

        await observer.receiveWake()
        #expect(await passes.count == 1)

        // Stop is idempotent, and it leaves the wake path closed.
        await observer.stop()
        await observer.stop()

        await observer.receiveWake()
        observer.scheduleWake()
        #expect(await passes.count == 1)
    }

    @Test func cancelledCoalescerIgnoresLaterWakes() async throws {
        let passes = PassCounter()
        let coalescer = ExtractorCatalogWakeCoalescer { _ = await passes.record() }

        await coalescer.receiveWake()
        #expect(await passes.count == 1)

        await coalescer.cancel()
        await coalescer.receiveWake()
        #expect(await passes.count == 1)
    }

    @Test func wakeAppliesTheNewlyPublishedGeneration() async throws {
        let environment = try await GeneratedPluginFixtures.InstalledEnvironment.install()
        defer { environment.cleanup() }

        let context = try await ProcessExtractionContext.assemble(layout: environment.layout)
        _ = await context.reconcileNow()
        #expect(await context.registry.containsRevision(environment.revision))

        let writer = try ExtractorPackageCatalogWriter.testing(layout: environment.layout)
        _ = try await writer.replaceCatalog(expectedGeneration: 1, records: [])

        // The wake carries no generation; the pass rereads the durable catalog.
        await context.receiveCatalogWake()

        #expect(await context.registry.containsRevision(environment.revision) == false)
        let observation = await context.observationSnapshot()
        #expect(observation.appliedGeneration == 2)

        await context.shutdown()
    }

    @Test func wakeAfterShutdownCannotReconcileAgain() async throws {
        let environment = try await GeneratedPluginFixtures.InstalledEnvironment.install()
        defer { environment.cleanup() }

        let context = try await ProcessExtractionContext.assemble(layout: environment.layout)
        _ = await context.reconcileNow()
        await context.shutdown()

        let writer = try ExtractorPackageCatalogWriter.testing(layout: environment.layout)
        _ = try await writer.replaceCatalog(expectedGeneration: 1, records: [])

        await context.receiveCatalogWake()

        // Shutdown closed the wake path, so the disposed graph never applied
        // the later generation.
        let observation = await context.observationSnapshot()
        #expect(observation.appliedGeneration == 1)
    }
}

private final class WakeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private final class CoalescerBox: @unchecked Sendable {
    var value: ExtractorCatalogWakeCoalescer?
}

private actor PassCounter {
    private(set) var count = 0

    func record() -> Int {
        count += 1
        return count
    }
}
