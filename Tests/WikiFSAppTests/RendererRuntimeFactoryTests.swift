#if os(macOS)
import Foundation
import Testing
import WikiFSCore
import WikiFSEngine
@testable import WikiFS

@Suite("Renderer runtime assembly", .serialized, .timeLimit(.minutes(2)))
struct RendererRuntimeFactoryTests {
    @Test("fixed renderer service labels remain stable")
    func serviceLabelsAreStable() {
        #expect(RendererRuntimeFactory.ServiceLabels.all == [
            "renderer.package-store-layout",
            "renderer.machine-index-store",
            "renderer.package-validator-factory",
            "renderer.resource-provider-factory",
            "renderer.runtime",
            "renderer.services",
        ])
    }

    @Test("component registration order does not affect settlement")
    func shuffledRegistrationOrderSettles() async throws {
        let fixture = try Fixture(name: "shuffled")
        defer { fixture.cleanup() }
        let handle = try await fixture.assembly.assemble(
            registrationOrder: RendererRuntimeFactory.Component.allCases.reversed())
        let preparation = try await handle.services.prepareCurrentRegistry()

        #expect(preparation.machineIndex.records.isEmpty)
        #expect(preparation.enabledDescriptors.isEmpty)
        try await handle.dispose()
    }

    @Test("preparation descriptors and providers share one generation")
    func preparationUsesOneGeneration() async throws {
        let fixture = try Fixture(name: "generation")
        defer { fixture.cleanup() }
        let handle = try await fixture.assembly.assemble()
        let preparation = try await handle.services.prepareCurrentRegistry()

        #expect(preparation.machineIndex.availableDescriptorProjection == preparation.enabledDescriptors)
        for descriptor in preparation.enabledDescriptors {
            let reservation = RendererPackageReservation(
                packageID: descriptor.reference.packageID,
                version: descriptor.reference.version)
            #expect(preparation.provider(for: reservation) != nil)
        }
        try await handle.dispose()
    }

    @Test("provider existential crosses an actor boundary with its fixture bytes")
    @MainActor
    func existentialCrossesActorBoundary() async throws {
        let fixture = try Fixture(name: "sendable")
        defer { fixture.cleanup() }
        let handle = try await fixture.assembly.assemble()
        let preparation = try await handle.services.installLocalDirectory(
            PackageFenceTestSupport.packageDirectory)
        let returned = await PreparationRelay().relay(preparation)
        let descriptor = try #require(returned.enabledDescriptors.first)
        let reservation = RendererPackageReservation(
            packageID: descriptor.reference.packageID,
            version: descriptor.reference.version)
        let provider = try #require(returned.provider(for: reservation))
        guard case let .webPackage(entryPoint) = descriptor.implementation else {
            Issue.record("Expected installed renderer to be a web package.")
            return
        }
        let resource = try provider.resource(for: RendererPackageScheme.url(
            packageID: reservation.packageID,
            version: reservation.version,
            path: entryPoint.path))

        #expect(!resource.data.isEmpty)
        #expect(resource.isEntryDocument)
        try await handle.dispose()
    }

    @Test("disposed runtime rejects later operations")
    func disposalRejectsWork() async throws {
        let fixture = try Fixture(name: "dispose")
        defer { fixture.cleanup() }
        let handle = try await fixture.assembly.assemble()
        try await handle.dispose()

        await #expect(throws: RendererServicesError.disposed) {
            try await handle.services.prepareCurrentRegistry()
        }
        try await handle.dispose()
    }

    @Test("facade is unavailable before installation")
    func facadeUnavailableBeforeInstall() async {
        let services = MutableRendererServices()
        await #expect(throws: RendererServicesError.unavailable) {
            try await services.prepareCurrentRegistry()
        }
    }

    @Test("shutdown after consume prevents main-actor publication")
    @MainActor
    func shutdownAfterConsumePreventsPublication() async throws {
        let fixture = try Fixture(name: "publication-race")
        defer { fixture.cleanup() }
        let owner = RendererCompositionOwner { try await fixture.assembly.assemble() }
        let host = InstalledRendererHost(services: owner.services)
        await owner.start()
        await owner.awaitSettled()
        let publication = try #require(await owner.consumeStartupPreparation())

        await owner.shutdown()

        #expect(publication.publish(to: host) == false)
        #expect(host.machineIndex == nil)
        #expect(host.inputs.enabledDescriptors.isEmpty)
    }

    @Test("owner shutdown is idempotent and rejects new work")
    func repeatedShutdownIsSafe() async throws {
        let fixture = try Fixture(name: "owner")
        defer { fixture.cleanup() }
        let owner = RendererCompositionOwner { try await fixture.assembly.assemble() }
        await owner.start()
        await owner.awaitSettled()
        await owner.shutdown()
        await owner.shutdown()

        await #expect(throws: RendererServicesError.unavailable) {
            try await owner.services.prepareCurrentRegistry()
        }
    }

    @Test("Cordis context types stay inside approved renderer domain files")
    func contextTypesStayInsideAssemblyBoundary() throws {
        let root = repositoryRoot()
        let rendererFiles = try FileManager.default.contentsOfDirectory(
            at: root.appending(path: "Sources/WikiFS/Renderer"),
            includingPropertiesForKeys: nil)
        let approved = Set(["RendererRuntimeFactory.swift"])
        for file in rendererFiles where file.pathExtension == "swift" && !approved.contains(file.lastPathComponent) {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(!source.contains("CordisContext"))
            #expect(!source.contains("ServiceKey<"))
            #expect(!source.contains("import Cordis"))
        }
        let appSource = try String(
            contentsOf: root.appending(path: "Sources/WikiFS/Window/WikiFSApp.swift"),
            encoding: .utf8)
        #expect(!appSource.contains("CordisContext"))
        #expect(!appSource.contains("ServiceKey<"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private actor PreparationRelay {
    func relay(_ preparation: RendererPreparation) -> RendererPreparation { preparation }
}

private struct Fixture: Sendable {
    let root: URL
    let assembly: RendererRuntimeFactory

    init(name: String) throws {
        root = URL.temporaryDirectory.appending(path: "renderer-runtime-\(name)-\(UUID().uuidString)")
        let layout = try RendererPackageStoreLayout(appGroupContainerRoot: root)
        assembly = RendererRuntimeFactory(layout: layout)
    }

    func cleanup() {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Renderer runtime fixture cleanup failed.") }
    }
}
#endif
