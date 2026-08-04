import Foundation
import Testing
import WikiFSTypes

struct RendererRegistrySnapshotTests {
    @Test func combinesBuiltInsAndEnabledInstalledDescriptorsDeterministically() throws {
        let builtIn = try RendererFixtures.nativeDescriptor(priority: 10)
        let installed = try RendererFixtures.nativeDescriptor(
            registrationID: try .init(validating: "installed"),
            priority: 20)

        let forward = try RendererRegistrySnapshot(
            builtInDescriptors: [builtIn],
            enabledInstalledDescriptors: [installed])
        let reverse = try RendererRegistrySnapshot(
            builtInDescriptors: [builtIn],
            enabledInstalledDescriptors: [installed])

        #expect(forward.descriptors.map(\.reference) == reverse.descriptors.map(\.reference))
        #expect(forward.descriptors.map(\.reference) == [installed.reference, builtIn.reference])
    }

    @Test func rejectsDuplicateDescriptorReferencesAcrossInputs() throws {
        let descriptor = try RendererFixtures.nativeDescriptor()
        #expect(throws: RendererValidationError.self) {
            _ = try RendererRegistrySnapshot(
                builtInDescriptors: [descriptor],
                enabledInstalledDescriptors: [descriptor])
        }
    }

    @Test func matchingAndPreferenceDelegateThroughSnapshotProtocolRevision() throws {
        let compatible = try RendererFixtures.nativeDescriptor()
        let incompatible = try RendererFixtures.nativeDescriptor(
            registrationID: try .init(validating: "future"),
            compatibility: try .init(minimumProtocolRevision: 2, maximumProtocolRevision: 2))
        let snapshot = try RendererRegistrySnapshot(
            builtInDescriptors: [incompatible, compatible],
            hostProtocolRevision: 1)
        let input = try RendererFixtures.input()

        #expect(snapshot.matching(input).map(\.reference) == [compatible.reference])
        #expect(snapshot.preferred(preference: .exact(incompatible.reference), input: input) == nil)
        #expect(snapshot.preferred(preference: .logical(compatible.logicalReference), input: input) == compatible)
    }
}
