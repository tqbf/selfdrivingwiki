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
        let host = InstalledRendererHost(machineStore: store, layout: layout)

        await host.bootstrapBundledRendererPackages()
        let first = try await store.read()
        await host.bootstrapBundledRendererPackages()
        let repeated = try await store.read()

        #expect(first.records.count == 1)
        #expect(first.availableDescriptorProjection.map(\.reference.registrationID) == [BundledRendererPackages.excalidrawRegistrationID])
        #expect(repeated == first)
        #expect(host.inputs.enabledDescriptors == first.availableDescriptorProjection)
    }

    @Test("an unavailable machine store preserves the Source fallback")
    func unavailableMachineStorePreservesSourceFallback() async throws {
        let host = InstalledRendererHost(machineStore: nil, layout: nil)
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
        let host = InstalledRendererHost(machineStore: nil, layout: nil)
        let reference = RendererReference(
            packageID: try RendererPackageID(validating: "org.example.host"),
            version: try RendererPackageVersion(validating: "1.0.0"),
            registrationID: try RendererRegistrationID(validating: "installed"))

        #expect(await host.resetInstalledRendererSafeMode(for: reference) == false)
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

        let host = InstalledRendererHost(machineStore: store, layout: layout)
        await host.bootstrapBundledRendererPackages()

        let index = try await store.read()
        #expect(index.records == [conflicting])
        #expect(host.inputs.enabledDescriptors.isEmpty)
    }
}
#endif
