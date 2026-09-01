#if os(macOS)
import Foundation
import Testing
import WikiFSCore
import WikiFSEngine
@testable import WikiFS

@Suite("Installed renderer host")
@MainActor
struct InstalledRendererHostTests {
    @Test("startup publishes an empty machine registry without installation")
    func emptyStartupPublishesWithoutMutation() async throws {
        let root = URL.temporaryDirectory.appending(path: "empty-renderer-startup-\(UUID().uuidString)")
        defer { remove(root) }
        let layout = try RendererPackageStoreLayout(appGroupContainerRoot: root)
        let store = RendererMachineIndexStore(layout: layout)
        let before = try await store.read()
        let handle = try await makeRuntime(layout: layout)
        let host = InstalledRendererHost(services: handle.services)

        await host.refresh()
        let after = try await store.read()

        #expect(after == before)
        #expect(host.inputs.enabledDescriptors.isEmpty)
        try await handle.dispose()
    }

    @Test("local Excalidraw import and removal preserve source data")
    func localExcalidrawImportAndRemovalPreserveSource() async throws {
        let root = URL.temporaryDirectory.appending(path: "local-excalidraw-import-\(UUID().uuidString)")
        defer { remove(root) }
        let layout = try RendererPackageStoreLayout(appGroupContainerRoot: root)
        let store = RendererMachineIndexStore(layout: layout)
        let handle = try await makeRuntime(layout: layout)
        let host = InstalledRendererHost(services: handle.services)

        #expect(await host.installRendererDirectory(PackageFenceTestSupport.packageDirectory))
        let installed = try await store.read()
        #expect(installed.availableDescriptorProjection.contains {
            $0.reference.packageID == PackageFenceTestSupport.installedPackageID
        })
        #expect(await host.installRendererDirectory(PackageFenceTestSupport.packageDirectory))
        #expect(try await store.read() == installed)

        #expect(await host.removeRenderer(
            packageID: PackageFenceTestSupport.installedPackageID,
            version: PackageFenceTestSupport.installedPackageVersion))
        #expect(try await store.read().availableDescriptorProjection.isEmpty)
        try await handle.dispose()
    }

    @Test("an unchanged 1.0.4 machine record prepares its provider")
    func version104MachineStorePreparesProviderAndServesEntryResource() async throws {
        let root = URL.temporaryDirectory.appending(path: "legacy-excalidraw-store-\(UUID().uuidString)")
        defer { remove(root) }
        let layout = try RendererPackageStoreLayout(appGroupContainerRoot: root)
        let legacyPackageURL = root.appendingPathComponent("excalidraw-1.0.4", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyPackageURL, withIntermediateDirectories: true)
        for assetName in ["LICENSE.md", "PROVENANCE.md", "index.html", "viewer.css", "viewer.js"] {
            try FileManager.default.copyItem(
                at: PackageFenceTestSupport.packageDirectory.appendingPathComponent(assetName),
                to: legacyPackageURL.appendingPathComponent(assetName))
        }
        let legacyManifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Excalidraw-1.0.4/manifest-1.0.4.txt")
        let legacyManifest = try Data(contentsOf: legacyManifestURL)
        try legacyManifest.write(
            to: legacyPackageURL.appendingPathComponent("manifest.json"),
            options: .atomic)
        let legacyPackage = legacyPackageURL
        let validator = RendererPackageValidator(
            packageRoot: layout.root,
            stagingRoot: layout.stagingRoot,
            reservedFenceAliases: BuiltInRendererDescriptors.reservedFenceAliases)
        let validated = try validator.validate(directory: legacyPackage)
        let descriptor = try #require(validated.manifest.descriptors.count == 1 ? validated.manifest.descriptors.first : nil)
        let destination = layout.packageURL(
            packageID: validated.manifest.packageID,
            version: validated.manifest.version)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: validated.stagedRoot, to: destination)

        let timestamp = try RFC3339Timestamp(validating: "2026-09-01T10:00:00+00:00")
        let record = try RendererPackageInstallRecord(
            packageID: validated.manifest.packageID,
            version: validated.manifest.version,
            expectedPackageHash: try RendererSHA256Digest(
                hex: "3068dfdac9b8e8e31f8ac0704c944ef462238c55aa0bbc3bca86d5769e8c9243"),
            state: .validated,
            reservedAt: timestamp,
            updatedAt: timestamp,
            validatedDescriptors: [descriptor])
        let machineStore = RendererMachineIndexStore(
            layout: layout,
            reservedFenceAliases: BuiltInRendererDescriptors.reservedFenceAliases)
        let initial = try await machineStore.read()
        _ = try await machineStore.mutate(expectedGeneration: initial.generation) { records, _ in
            records = [record]
        }

        let handle = try await makeRuntime(layout: layout)
        let preparation = try await handle.services.prepareCurrentRegistry()
        let prepared = try #require(preparation.enabledDescriptors.count == 1 ? preparation.enabledDescriptors.first : nil)
        guard case let .webPackage(entryPoint) = prepared.implementation else {
            Issue.record("Expected the legacy package descriptor to remain a web package.")
            return
        }
        let reservation = RendererPackageReservation(
            packageID: prepared.reference.packageID,
            version: prepared.reference.version)
        let provider = try #require(preparation.provider(for: reservation))
        let resource = try provider.resource(for: RendererPackageScheme.url(
            packageID: reservation.packageID,
            version: reservation.version,
            path: entryPoint.path))

        #expect(prepared.reference.version.rawValue == "1.0.4")
        #expect(resource.isEntryDocument)
        #expect(!resource.data.isEmpty)
        try await handle.dispose()
    }

    @Test("an unavailable machine store preserves the Source fallback")
    func unavailableMachineStorePreservesSourceFallback() async throws {
        let host = InstalledRendererHost(services: UnavailableRendererServices())
        let packageID = try RendererPackageID(validating: "org.example.host")
        let version = try RendererPackageVersion(validating: "1.0.0")

        await host.refresh()

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
        let packageURL = PackageFenceTestSupport.packageDirectory
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
            Issue.record("Expected the renderer package to be a web package.")
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

    @Test("ordinary import fails closed when an installed hash conflicts")
    func ordinaryImportRejectsConflictingInstalledHash() async throws {
        let root = URL.temporaryDirectory.appending(path: "renderer-package-conflict-\(UUID().uuidString)")
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Renderer package conflict fixture cleanup failed.") }
        }
        let layout = try RendererPackageStoreLayout(appGroupContainerRoot: root)
        let store = RendererMachineIndexStore(layout: layout)
        let packageURL = PackageFenceTestSupport.packageDirectory
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
        await host.refresh()

        let index = try await store.read()
        #expect(index.records == [conflicting])
        #expect(host.inputs.enabledDescriptors.isEmpty)
        try await handle.dispose()
    }

    private func remove(_ root: URL) {
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Renderer host fixture cleanup failed: \(error)") }
    }

    private func makeRuntime(
        layout: RendererPackageStoreLayout
    ) async throws -> RendererRuntimeHandle {
        try await RendererRuntimeFactory(layout: layout).assemble()
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
