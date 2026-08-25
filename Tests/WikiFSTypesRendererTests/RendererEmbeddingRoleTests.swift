import Foundation
import Testing
@testable import WikiFSTypes

struct RendererEmbeddingRoleTests {
    @Test func legacyDescriptorConstructsWithoutManifest() throws {
        let descriptor = try RendererFixtures.webDescriptor()
        #expect(descriptor.supportedEmbeddingRoles == [.disclosureRow])
    }

    @Test func legacyManifestConstructsWithoutEncoding() throws {
        let descriptor = try RendererFixtures.webDescriptor()
        let manifest = try RendererManifest(
            revision: 1,
            packageID: RendererFixtures.packageID,
            version: RendererFixtures.version,
            descriptors: [descriptor],
            assets: descriptor.approvedAssets)
        #expect(manifest.revision == 1)
        #expect(manifest.descriptors.count == 1)
    }

    @Test func descriptorRequiresAtLeastOneEmbeddingRole() throws {
        #expect(throws: RendererValidationError.missingEmbeddingRoles) {
            _ = try RendererFixtures.webDescriptor(
                embeddingRoles: [],
                explicitEmbeddingRoles: true)
        }
    }

    @Test func revisionOneCanonicalJSONOmitsDerivedLegacyRole() throws {
        let descriptor = try RendererFixtures.webDescriptor()
        let manifest = try RendererManifest(
            revision: RendererManifestRevision.legacy,
            packageID: RendererFixtures.packageID,
            version: RendererFixtures.version,
            descriptors: [descriptor],
            assets: descriptor.approvedAssets)
        let json = try String(decoding: manifest.canonicalJSON(), as: UTF8.self)

        let expectedJSON = #"{"assets":[{"digest":"0000000000000000000000000000000000000000000000000000000000000000","path":"index.html"}],"descriptors":[{"accessibility":{"supportsKeyboardNavigation":true,"supportsVoiceOver":true},"approvedAssets":[{"digest":"0000000000000000000000000000000000000000000000000000000000000000","path":"index.html"}],"capabilities":["inputRead"],"compatibility":{"maximumProtocolRevision":1,"minimumProtocolRevision":1},"displayName":"Example Web Viewer","implementation":{"webPackage":{"_0":{"path":"index.html"}}},"linkPolicy":"none","matchers":[{"artifactKind":{"_0":"source"}}],"presentations":["web"],"priority":0,"reference":{"packageID":"org.example.viewer","registrationID":"viewer","version":"1.2.3"},"sizeLimits":{"maximumDecodedByteCount":2048,"maximumInputByteCount":1024}}],"packageID":"org.example.viewer","revision":1,"version":"1.2.3"}"#
        #expect(json == expectedJSON)
        #expect(try manifest.packageHash().hex == "fc5abe6a595e935bb8ba4be1c97c495f7a2114740b26518d71483664594a2fc1")
        #expect(descriptor.supportedEmbeddingRoles == [.disclosureRow])
    }

    @Test func revisionTwoRequiresExplicitRoles() throws {
        let legacyDescriptor = try RendererFixtures.webDescriptor()
        #expect(throws: RendererValidationError.missingEmbeddingRoles) {
            _ = try RendererManifest(
                revision: RendererManifestRevision.current,
                packageID: RendererFixtures.packageID,
                version: RendererFixtures.version,
                descriptors: [legacyDescriptor],
                assets: legacyDescriptor.approvedAssets)
        }
    }

    @Test func revisionTwoCanonicalJSONIncludesRoles() throws {
        let descriptor = try RendererFixtures.webDescriptor(
            embeddingRoles: [.inlineContent, .disclosureRow],
            explicitEmbeddingRoles: true)
        let manifest = try RendererManifest(
            revision: RendererManifestRevision.current,
            packageID: RendererFixtures.packageID,
            version: RendererFixtures.version,
            descriptors: [descriptor],
            assets: descriptor.approvedAssets)
        let json = try String(decoding: manifest.canonicalJSON(), as: UTF8.self)

        #expect(json.contains("supportedEmbeddingRoles"))
        #expect(json.contains("inlineContent"))
        #expect(json.contains("disclosureRow"))
    }

    @Test func revisionTwoHashChangesWithRoleSet() throws {
        let inline = try RendererFixtures.webDescriptor(
            embeddingRoles: [.inlineContent],
            explicitEmbeddingRoles: true)
        let row = try RendererFixtures.webDescriptor(
            embeddingRoles: [.disclosureRow],
            explicitEmbeddingRoles: true)
        let inlineManifest = try RendererManifest(
            revision: 2,
            packageID: RendererFixtures.packageID,
            version: RendererFixtures.version,
            descriptors: [inline],
            assets: inline.approvedAssets)
        let rowManifest = try RendererManifest(
            revision: 2,
            packageID: RendererFixtures.packageID,
            version: RendererFixtures.version,
            descriptors: [row],
            assets: row.approvedAssets)

        #expect(try inlineManifest.packageHash() != rowManifest.packageHash())
    }

    @Test func matchingFiltersRoleBeforePriority() throws {
        let highPriorityRow = try RendererFixtures.nativeDescriptor(
            embeddingRoles: [.disclosureRow],
            explicitEmbeddingRoles: true,
            priority: 100)
        let inlineRegistration = try RendererRegistrationID(validating: "inline-viewer")
        let lowPriorityInline = try RendererFixtures.nativeDescriptor(
            registrationID: inlineRegistration,
            embeddingRoles: [.inlineContent],
            explicitEmbeddingRoles: true,
            priority: 1)
        let input = try RendererFixtures.input()
        let matches = RendererResolution.matching(
            descriptors: [highPriorityRow, lowPriorityInline],
            input: input,
            requiredEmbeddingRole: .inlineContent,
            hostProtocolRevision: 1)

        #expect(matches.map(\.reference) == [lowPriorityInline.reference])
    }

    @Test func legacyDescriptorsCannotFillInlineRole() throws {
        let legacy = try RendererFixtures.webDescriptor()
        let input = try RendererFixtures.input(artifact: .source)
        let matches = RendererResolution.matching(
            descriptors: [legacy],
            input: input,
            requiredEmbeddingRole: .inlineContent,
            hostProtocolRevision: 1)

        #expect(matches.isEmpty)
    }
}
