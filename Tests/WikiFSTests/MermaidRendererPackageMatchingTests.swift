import Foundation
import Testing
@testable import WikiFSCore
import WikiFSTypes

/// Matching and manifest-declaration behavior for the reviewed Mermaid
/// renderer package: text/mermaid MIME routing plus the `.mmd` extension
/// fallback, the revision-3 validation contract, priority 90 (the old built-in
/// markdownDocument tier), and the roles/limits the reader consumes.
@Suite("Mermaid renderer package matching", .serialized)
struct MermaidRendererPackageMatchingTests {
    private let manifest: RendererManifest
    private let descriptor: RendererDescriptor

    init() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("RendererPackages/Mermaid", isDirectory: true)
        manifest = try JSONDecoder().decode(
            RendererManifest.self,
            from: Data(contentsOf: packageRoot.appendingPathComponent("manifest.json")))
        descriptor = try #require(manifest.descriptors.first)
    }

    private func input(
        mimeType: String?,
        fileExtension: String?,
        artifactKind: RendererArtifactKind? = .source
    ) throws -> RendererMatchInput {
        try RendererMatchInput(
            mimeType: try mimeType.map { try RendererMIMEType(validating: $0) },
            fileExtension: try fileExtension.map { try RendererFileExtension(validating: $0) },
            sniffedBytes: Data("flowchart LR\n    A --> B".utf8),
            artifactKind: artifactKind)
    }

    @Test("identity block decodes with the reviewed package identity")
    func identityBlockDecodes() throws {
        #expect(manifest.revision == 3)
        #expect(manifest.packageID.rawValue == "org.selfdrivingwiki.mermaid-readonly")
        #expect(manifest.version.rawValue == "1.0.0")
        #expect(descriptor.reference.registrationID.rawValue == "mermaid")
        #expect(descriptor.displayName == "Mermaid")
        #expect(descriptor.priority == 90)
        #expect(descriptor.implementation == .webPackage(.init(path: try .init(validating: "index.html"))))
    }

    @Test("a text/mermaid source selects the package at the strong tier")
    func mermaidMIMESelectsAtStrongTier() throws {
        #expect(descriptor.matchTier(for: try input(mimeType: "text/mermaid", fileExtension: "mmd")) == .strong)
        #expect(descriptor.matchTier(for: try input(mimeType: "text/mermaid", fileExtension: "mmd")) != .extensionFallback)
    }

    @Test("a .mmd source with no MIME selects the package at the extension-fallback tier")
    func mmdExtensionSelectsAtFallbackTier() throws {
        // The legacy NULL-MIME row shape: the extension fallback exists for
        // exactly this case.
        #expect(descriptor.matchTier(for: try input(mimeType: nil, fileExtension: "mmd")) == .extensionFallback)
    }

    @Test("a source with an empty extension constructs without throwing or matching")
    func emptyExtensionIsAbsenceOfExtension() throws {
        // Extensionless source rows carry ext == "": that must be normalized
        // to nil (an absent extension), never an invalid extension that drops
        // the source from renderer candidates.
        let source = try RendererEmbeddedContent.Source(
            sourceID: SourceID(rawValue: "01JEMPTYEXTFIXTURE0000001"),
            sourceVersionID: SourceVersionID(rawValue: "01JEMPTYEXTFIXTURE0000002"),
            mimeType: try .init(validating: "text/plain"),
            fileExtension: "",
            bytes: Data("hello".utf8))
        #expect(source.fileExtension == nil)
        // With no real extension and no matching MIME, nothing resolves.
        let snapshot = try RendererRegistrySnapshot(
            builtInDescriptors: [],
            availableInstalledDescriptors: [descriptor])
        let input = try RendererMatchInput(
            mimeType: try RendererMIMEType(validating: "text/plain"),
            fileExtension: source.fileExtension.flatMap { try RendererFileExtension(validating: $0) },
            sniffedBytes: Data("hello".utf8),
            artifactKind: .source)
        #expect(snapshot.matching(input).isEmpty)
    }

    @Test("unrelated text sources do not select the package")
    func unrelatedTextSourcesDoNotSelect() throws {
        #expect(descriptor.matchTier(for: try input(mimeType: "text/plain", fileExtension: "txt")) == nil)
        #expect(descriptor.matchTier(for: try input(mimeType: "text/markdown", fileExtension: "md")) == nil)
        #expect(descriptor.matchTier(for: try input(mimeType: nil, fileExtension: "txt")) == nil)
        #expect(descriptor.matchTier(for: try input(mimeType: nil, fileExtension: nil)) == nil)
    }

    @Test("the package declares a MIME matcher plus an extension fallback")
    func matchersAreMIMEPlusExtension() throws {
        #expect(descriptor.matchers.count == 2)
        #expect(descriptor.matchers.contains(.normalizedMIME(try .init(validating: "text/mermaid"))))
        #expect(descriptor.matchers.contains(.extensionFallback(try .init(validating: "mmd"))))
    }

    @Test("the fence claim carries the revision-3 validation contract")
    func fenceClaimCarriesTheValidationContract() throws {
        let claim = try #require(descriptor.fenceClaims.first)
        let alias = try RendererFenceAlias(validating: "mermaid")
        let mime = try RendererMIMEType(validating: "text/mermaid")
        #expect(claim.alias == alias)
        #expect(claim.inlineMIMEType == mime)
        let validation = try #require(claim.validation)
        #expect(validation.engineAssetPath.rawValue == "mermaid.min.js")
        #expect(validation.wrapperAssetPath.rawValue == "validate.js")
        #expect(validation.entryFunction == "__sdw_validate_fence")
        #expect(descriptor.hasFenceValidation)
        // The declared assets are approved members of the package.
        #expect(descriptor.approvedAssets.contains { $0.path == validation.engineAssetPath })
        #expect(descriptor.approvedAssets.contains { $0.path == validation.wrapperAssetPath })
    }

    @Test("the package obeys the read-only role and capability contract")
    func readOnlyContractHolds() throws {
        #expect(descriptor.capabilities == [.inputRead])
        #expect(descriptor.linkPolicy == .none)
        #expect(descriptor.presentations == [.web])
        #expect(descriptor.supportedEmbeddingRoles == [.inlineContent, .disclosureRow])
        #expect(descriptor.accessibility.supportsVoiceOver)
        #expect(descriptor.accessibility.supportsKeyboardNavigation)
        #expect(descriptor.sizeLimits.maximumInputByteCount == 48_000)
        #expect(descriptor.sizeLimits.maximumDecodedByteCount == 48_000)
        #expect(descriptor.sizeLimits.maximumInputByteCount <= WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount)
    }

    @Test("the registry input for a NULL-MIME .mmd row resolves the package")
    func plannerRoutesNullMimeMmdThroughThePackage() throws {
        // The SourceDetail presentation planner's registry input shape: a
        // legacy NULL-MIME .mmd row resolves the package descriptor by
        // extension through the same snapshot the planner builds.
        let snapshot = try RendererRegistrySnapshot(
            builtInDescriptors: [],
            availableInstalledDescriptors: [descriptor])
        let input = try self.input(mimeType: nil, fileExtension: "mmd")
        let matches = snapshot.matching(input)
        #expect(matches.map(\.reference) == [descriptor.reference])
    }

    @Test("a .mmd row resolves only the package")
    func mmdRowsResolveOnlyThePackage() throws {
        // With the package installed, a .mmd row's matches contain the
        // package descriptor; nothing else answers diagram sources, and the
        // match is exactly one descriptor.
        let snapshot = try RendererRegistrySnapshot(
            builtInDescriptors: [],
            availableInstalledDescriptors: [descriptor])
        let mimeInput = try self.input(mimeType: "text/mermaid", fileExtension: "mmd")
        let extensionInput = try self.input(mimeType: nil, fileExtension: "mmd")
        #expect(snapshot.matching(mimeInput).map(\.reference) == [descriptor.reference])
        #expect(snapshot.matching(extensionInput).map(\.reference) == [descriptor.reference])
        // Unrelated formats resolve nothing.
        let unrelated = try self.input(mimeType: "text/plain", fileExtension: "txt")
        #expect(snapshot.matching(unrelated).isEmpty)
    }
}
