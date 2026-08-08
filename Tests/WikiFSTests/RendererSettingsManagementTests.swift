import Foundation
import Testing
@testable import WikiFSCore

@Suite(.serialized, .timeLimit(.minutes(1)))
struct RendererSettingsManagementTests {
    @Test("removal retains a redacted machine tombstone and deletes only the payload")
    func removalPreservesMachineBoundary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("renderer-settings-\(UUID().uuidString)", isDirectory: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Renderer settings fixture cleanup failed.") }
        }
        let layout = try RendererPackageStoreLayout(appGroupContainerRoot: root)
        let packageID = try RendererPackageID(validating: "org.example.settings")
        let version = try RendererPackageVersion(validating: "1.0.0")
        let timestamp = RFC3339Timestamp(date: Date(timeIntervalSince1970: 1_700_000_000))
        let record = try RendererPackageInstallRecord(
            packageID: packageID,
            version: version,
            expectedPackageHash: try RendererSHA256Digest(bytes: Array(repeating: 3, count: 32)),
            state: .quarantined,
            reservedAt: timestamp,
            updatedAt: timestamp,
            diagnostic: .packageQuarantined)
        let store = RendererMachineIndexStore(layout: layout)
        let initial = try await store.read()
        let packageRoot = layout.packageURL(packageID: packageID, version: version)
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        #expect(isRendererPackageStorePathContained(packageRoot, within: layout.packagesRoot))
        _ = try await store.mutate(expectedGeneration: initial.generation) { records, _ in
            records.append(record)
        }

        let removed = try await store.remove(packageID: packageID, version: version)

        #expect(removed.records.count == 1)
        #expect(removed.records.first?.state == .removed)
        #expect(removed.records.first?.diagnostic == .packageRemoved)
        #expect(removed.availableDescriptorProjection.isEmpty)
        #expect(FileManager.default.fileExists(atPath: packageRoot.path) == false)
        #expect(try await store.read().records.first?.state == .removed)
    }

    @Test("renderer preference version selection is an exact typed reference")
    func versionSelectionUsesExactReference() throws {
        let packageID = try RendererPackageID(validating: "org.example.settings")
        let version = try RendererPackageVersion(validating: "2.0.0")
        let registration = try RendererRegistrationID(validating: "canvas")
        let reference = RendererReference(packageID: packageID, version: version, registrationID: registration)

        #expect(RendererPreferenceReference.exact(reference) == .exact(reference))
    }
}
