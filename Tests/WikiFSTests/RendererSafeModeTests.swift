import Foundation
import Testing
@testable import WikiFSCore

@Suite("Renderer safe mode", .serialized, .timeLimit(.minutes(1)))
struct RendererSafeModeTests {
    @Test func thresholdDisablesInstalledOnlyAndResetRestores() async throws {
        let fixture = try RendererMachineStoreFailureFixture()
        defer { fixture.remove() }
        let store = try await fixture.installedStore()
        var index = try await store.read()
        for minute in 0..<RendererInstalledRendererFailurePolicy.threshold {
            let update = try await store.recordInstalledRendererFailure(
                packageID: fixture.packageID,
                version: fixture.version,
                failure: .webContentProcessTerminated,
                expectedGeneration: index.generation,
                clock: RendererMachineStoreFailureFixture.Clock(timestamp: try RendererMachineStoreFailureFixture.timestamp(minutes: minute))
            )
            index = update.index
        }

        let builtIn = try fixture.builtInDescriptor()
        let suppressed = try RendererRegistrySnapshot(builtInDescriptors: [builtIn], enabledInstalledDescriptors: index.availableDescriptorProjection)
        #expect(suppressed.descriptors == [builtIn])

        let reset = try await store.resetInstalledRendererSafeMode(expectedGeneration: index.generation)
        let restored = try RendererRegistrySnapshot(builtInDescriptors: [builtIn], enabledInstalledDescriptors: reset.availableDescriptorProjection)
        #expect(reset.safeModeIsEnabled == false)
        #expect(restored.descriptors.contains(fixture.installedDescriptor))
        let resetClock = RendererMachineStoreFailureFixture.Clock(timestamp: try RendererMachineStoreFailureFixture.timestamp(minutes: 1))
        let resetWindow = try await store.failureWindow(packageID: fixture.packageID, version: fixture.version, clock: resetClock)
        #expect(resetWindow.count == 0)
        #expect((try await RendererMachineIndexStore(layout: fixture.layout).read()).safeModeIsEnabled == false)
    }

    @Test func staleResetCannotDiscardAConcurrentFailureHistory() async throws {
        let fixture = try RendererMachineStoreFailureFixture()
        defer { fixture.remove() }
        let first = try await fixture.installedStore()
        let second = RendererMachineIndexStore(layout: fixture.layout)
        let generation = (try await first.read()).generation
        let clock = RendererMachineStoreFailureFixture.Clock(timestamp: try RendererMachineStoreFailureFixture.timestamp(minutes: 0))

        _ = try await first.recordInstalledRendererFailure(packageID: fixture.packageID, version: fixture.version, failure: .loadTimedOut, expectedGeneration: generation, clock: clock)
        await #expect(throws: RendererMachineIndexStoreError.staleGeneration) {
            try await second.resetInstalledRendererSafeMode(expectedGeneration: generation)
        }
        #expect((try await first.failureWindow(packageID: fixture.packageID, version: fixture.version, clock: clock)).count == 1)
    }
}
