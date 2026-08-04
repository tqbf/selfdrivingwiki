import Foundation
import Testing
import WikiFSTypes

struct RendererRegistrySnapshotTests {
    @Test func combinesBuiltInsAndEnabledInstalledDescriptorsDeterministically() throws {
        let builtIn = try RendererFixtures.nativeDescriptor(priority: 10)
        let installedA = try RendererFixtures.webDescriptor(
            packageID: try .init(validating: "org.example.alpha"),
            registrationID: try .init(validating: "installed-a"),
            priority: 20)
        let installedB = try RendererFixtures.webDescriptor(
            packageID: try .init(validating: "org.example.beta"),
            registrationID: try .init(validating: "installed-b"),
            priority: 20)

        let forward = try RendererRegistrySnapshot(
            builtInDescriptors: [builtIn],
            enabledInstalledDescriptors: [installedA, installedB])
        let reverse = try RendererRegistrySnapshot(
            builtInDescriptors: [builtIn],
            enabledInstalledDescriptors: [installedB, installedA])

        #expect(forward.descriptors.map(\.reference) == reverse.descriptors.map(\.reference))
        #expect(forward.descriptors.map(\.reference) == [installedA.reference, installedB.reference, builtIn.reference])
    }

    @Test func rejectsDuplicateDescriptorReferencesAcrossInputs() throws {
        let builtIn = try RendererFixtures.nativeDescriptor()
        let installed = try RendererFixtures.webDescriptor()
        #expect(throws: RendererValidationError.duplicateRegistration(builtIn.reference.registrationID)) {
            _ = try RendererRegistrySnapshot(
                builtInDescriptors: [builtIn],
                enabledInstalledDescriptors: [installed])
        }
    }

    @Test func rejectsInstalledDescriptorsInBuiltInChannel() throws {
        let installed = try RendererFixtures.webDescriptor()
        #expect(throws: RendererValidationError.builtInRegistryContainsInstalled(installed.reference.registrationID)) {
            _ = try RendererRegistrySnapshot(builtInDescriptors: [installed])
        }
    }

    @Test func rejectsBuiltInDescriptorsInInstalledChannel() throws {
        let builtIn = try RendererFixtures.nativeDescriptor()
        #expect(throws: RendererValidationError.installedRegistryContainsBuiltIn(builtIn.reference.registrationID)) {
            _ = try RendererRegistrySnapshot(
                builtInDescriptors: [],
                enabledInstalledDescriptors: [builtIn])
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
