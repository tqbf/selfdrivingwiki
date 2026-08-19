#if os(macOS)
import Foundation
import Testing
import WikiFSCore
@testable import WikiFS

@Suite("Installed renderer host")
@MainActor
struct InstalledRendererHostTests {
    @Test("bundled Excalidraw is available as an app resource with its reviewed identity")
    func bundledExcalidrawResourceHasReviewedIdentity() throws {
        let packageURL = try #require(BundledRendererPackages.excalidrawResourceURL())
        let root = URL.temporaryDirectory.appending(path: "bundled-excalidraw-resource-\(UUID().uuidString)")
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Bundled Excalidraw resource fixture cleanup failed.") }
        }

        let package = try RendererPackageValidator(packageRoot: root).validate(directory: packageURL)

        #expect(package.manifest.packageID == BundledRendererPackages.excalidrawPackageID)
        #expect(package.manifest.version == BundledRendererPackages.excalidrawVersion)
        #expect(package.manifest.descriptors.map(\.reference.registrationID) == [BundledRendererPackages.excalidrawRegistrationID])
    }

    @Test("bundled Excalidraw bootstrap installs once and remains available to every wiki")
    func bundledExcalidrawBootstrapIsIdempotentAndMachineScoped() async throws {
        let root = URL.temporaryDirectory.appending(path: "bundled-excalidraw-bootstrap-\(UUID().uuidString)")
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Bundled Excalidraw bootstrap fixture cleanup failed.") }
        }
        let layout = try RendererPackageStoreLayout(appGroupContainerRoot: root)
        let store = RendererMachineIndexStore(layout: layout)
        let handle = try await makeRuntime(layout: layout)
        let host = InstalledRendererHost(services: handle.services)

        await host.bootstrapBundledRendererPackages()
        let first = try await store.read()
        await host.bootstrapBundledRendererPackages()
        let repeated = try await store.read()

        #expect(first.records.count == 1)
        #expect(first.availableDescriptorProjection.map(\.reference.registrationID) == [BundledRendererPackages.excalidrawRegistrationID])
        #expect(repeated == first)
        #expect(host.inputs.enabledDescriptors == first.availableDescriptorProjection)
        try await handle.dispose()
    }

    @Test("an unavailable machine store preserves the Source fallback")
    func unavailableMachineStorePreservesSourceFallback() async throws {
        let host = InstalledRendererHost(services: UnavailableRendererServices())
        let packageID = try RendererPackageID(validating: "org.example.host")
        let version = try RendererPackageVersion(validating: "1.0.0")

        await host.bootstrapBundledRendererPackages()

        #expect(host.machineIndex == nil)
        #expect(host.inputs.enabledDescriptors.isEmpty)
        let resetSucceeded = await host.resetInstalledRendererSafeMode(
            packageID: packageID,
            version: version)
        #expect(resetSucceeded == false)
    }

    @Test("host recovery is scoped by the typed renderer reference")
    func recoveryUsesTypedReference() async throws {
        let host = InstalledRendererHost(services: UnavailableRendererServices())
        let reference = RendererReference(
            packageID: try RendererPackageID(validating: "org.example.host"),
            version: try RendererPackageVersion(validating: "1.0.0"),
            registrationID: try RendererRegistrationID(validating: "installed"))

        #expect(await host.resetInstalledRendererSafeMode(for: reference) == false)
    }

    @Test("materialized session configuration remains pinned across preparation change")
    func materializedSessionConfigurationRemainsPinnedAcrossPreparationChange() async throws {
        let packageURL = try #require(BundledRendererPackages.excalidrawResourceURL())
        let validationRoot = URL.temporaryDirectory.appending(path: "renderer-pinned-validation-\(UUID().uuidString)")
        defer {
            if FileManager.default.fileExists(atPath: validationRoot.path) {
                do { try FileManager.default.removeItem(at: validationRoot) }
                catch { Issue.record("Pinned renderer validation fixture cleanup failed.") }
            }
        }
        let package = try RendererPackageValidator(packageRoot: validationRoot).validate(directory: packageURL)
        let descriptor = try #require(package.manifest.descriptors.first)
        guard case let .webPackage(entryPoint) = descriptor.implementation else {
            Issue.record("Expected bundled renderer to be a web package.")
            return
        }
        let reservation = RendererPackageReservation(
            packageID: descriptor.reference.packageID,
            version: descriptor.reference.version)
        let timestamp = try RFC3339Timestamp(validating: "2026-08-19T10:00:00+00:00")
        let record = try RendererPackageInstallRecord(
            packageID: reservation.packageID,
            version: reservation.version,
            expectedPackageHash: package.packageHash,
            state: .validated,
            reservedAt: timestamp,
            updatedAt: timestamp,
            validatedDescriptors: [descriptor])
        let providerA = FixtureResourceProvider(data: Data("preparation-a".utf8))
        let indexA = try RendererMachineIndex(generation: 1, records: [record])
        let host = InstalledRendererHost(services: UnavailableRendererServices())
        host.apply(RendererPreparation(
            machineIndex: indexA,
            enabledDescriptors: [descriptor],
            providers: [reservation: providerA],
            failureRecorder: { _, _ in }))
        let configurationA = try #require(host.inputs.configuration(
            for: descriptor,
            entryPoint: entryPoint))

        host.apply(RendererPreparation(
            machineIndex: try RendererMachineIndex(generation: 2),
            enabledDescriptors: [],
            providers: [:],
            failureRecorder: { _, _ in }))

        let oldResource = try configurationA.resourceProvider.resource(for: RendererPackageScheme.url(
            packageID: reservation.packageID,
            version: reservation.version,
            path: entryPoint.path))
        #expect(oldResource.data == Data("preparation-a".utf8))
        #expect(host.inputs.configuration(for: descriptor, entryPoint: entryPoint) == nil)
    }

    @Test("bundled bootstrap fails closed when an installed hash conflicts")
    func bundledBootstrapRejectsConflictingInstalledHash() async throws {
        let root = URL.temporaryDirectory.appending(path: "bundled-excalidraw-conflict-\(UUID().uuidString)")
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Bundled Excalidraw conflict fixture cleanup failed.") }
        }
        let layout = try RendererPackageStoreLayout(appGroupContainerRoot: root)
        let store = RendererMachineIndexStore(layout: layout)
        let packageURL = try #require(BundledRendererPackages.excalidrawResourceURL())
        let package = try RendererPackageValidator(packageRoot: root).validate(directory: packageURL)
        let timestamp = try RFC3339Timestamp(validating: "2026-08-08T17:00:00+00:00")
        let conflicting = try RendererPackageInstallRecord(
            packageID: package.manifest.packageID,
            version: package.manifest.version,
            expectedPackageHash: try RendererSHA256Digest(hex: String(repeating: "0", count: 64)),
            state: .validated,
            reservedAt: timestamp,
            updatedAt: timestamp,
            validatedDescriptors: package.manifest.descriptors)
        _ = try await store.read()
        _ = try await store.mutate(expectedGeneration: 0) { records, _ in
            records = [conflicting]
        }

        let handle = try await makeRuntime(layout: layout)
        let host = InstalledRendererHost(services: handle.services)
        await host.bootstrapBundledRendererPackages()

        let index = try await store.read()
        #expect(index.records == [conflicting])
        #expect(host.inputs.enabledDescriptors.isEmpty)
        try await handle.dispose()
    }

    private func makeRuntime(
        layout: RendererPackageStoreLayout
    ) async throws -> RendererRuntimeHandle {
        try await RendererRuntimeAssembly(
            layout: layout,
            bundledPackageSource: { BundledRendererPackages.excalidrawResourceURL() },
            reviewedBundledIdentity: .init(
                packageID: BundledRendererPackages.excalidrawPackageID,
                version: BundledRendererPackages.excalidrawVersion,
                registrationID: BundledRendererPackages.excalidrawRegistrationID))
            .assemble()
    }
}

private struct FixtureResourceProvider: RendererPackageResourceProviding {
    let data: Data

    func resource(for url: URL) throws -> RendererPackageResource {
        guard let mimeType = RendererMIMEType(rawValue: "text/html") else {
            throw RendererPackageResourceError.unsupportedMIMEType
        }
        return RendererPackageResource(
            data: data,
            mimeType: mimeType,
            isEntryDocument: true)
    }
}
#endif
