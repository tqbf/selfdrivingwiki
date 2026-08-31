import Foundation
import Testing
@testable import WikiFSCore

/// Matching and manifest-declaration behavior for the D2 renderer package
/// shape: extension-fallback routing only, `inputRead` as the sole capability,
/// no link authority, and the revision-2 role rule.
@Suite("D2 renderer package matching", .serialized)
struct D2RendererPackageMatchingTests {
    private let manifest: RendererManifest
    private let descriptor: RendererDescriptor

    init() throws {
        manifest = try JSONDecoder().decode(
            RendererManifest.self,
            from: Data(D2PackageFixtures.manifestJSON.utf8))
        descriptor = try #require(manifest.descriptors.first)
    }

    private func d2Input(extensionName: String? = D2PackageFixtures.sourceExtension) throws -> RendererMatchInput {
        try RendererMatchInput(
            mimeType: nil,
            fileExtension: extensionName.map { try RendererFileExtension(validating: $0) },
            sniffedBytes: Data("x -> y".utf8),
            artifactKind: nil)
    }

    @Test("identity block decodes with the planned package identity")
    func identityBlockDecodes() throws {
        #expect(manifest.revision == 2)
        #expect(manifest.packageID.rawValue == D2PackageFixtures.packageID)
        #expect(manifest.version.rawValue == D2PackageFixtures.packageVersion)
        #expect(descriptor.reference.registrationID.rawValue == D2PackageFixtures.registrationID)
        #expect(descriptor.displayName == D2PackageFixtures.displayName)
        #expect(descriptor.priority == D2PackageFixtures.priority)
        #expect(descriptor.implementation == .webPackage(.init(path: try .init(validating: "index.html"))))
    }

    @Test("a d2 source selects the package at the extension-fallback tier")
    func d2ExtensionSelectsAtFallbackTier() throws {
        #expect(descriptor.matchTier(for: try d2Input()) == .extensionFallback)
        #expect(descriptor.matchTier(for: try d2Input()) != .strong)
    }

    @Test("matching stays extension-only and claims no MIME type or signature")
    func matchersAreExtensionOnly() throws {
        #expect(descriptor.matchers.count == 1)
        #expect(descriptor.matchers.first?.isExtensionFallback == true)
        // A MIME claim like text/plain would annex every plain-text source.
        for matcher in descriptor.matchers {
            guard case .normalizedMIME = matcher else { continue }
            Issue.record("D2 must not declare a MIME matcher")
        }
    }

    @Test("a d2 source does not select Excalidraw-shaped or built-in descriptors")
    func d2SourceExcludesOtherRenderers() throws {
        let excalidrawShaped = try RendererDescriptor(
            reference: .init(
                packageID: try .init(validating: "org.selfdrivingwiki.excalidraw-readonly"),
                version: try .init(validating: "1.0.3"),
                registrationID: try .init(validating: "excalidraw")),
            displayName: "Excalidraw",
            implementation: .webPackage(.init(path: try .init(validating: "index.html"))),
            matchers: [
                .normalizedMIME(try .init(validating: "application/json")),
                .extensionFallback(try .init(validating: "excalidraw")),
                .boundedJSONArtifact(.excalidraw),
            ],
            presentations: [.web],
            supportedEmbeddingRoles: [.disclosureRow, .inlineContent],
            approvedAssets: [RendererAsset(
                path: try .init(validating: "index.html"),
                digest: try .init(hex: "aa0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0a"))],
            capabilities: [.inputRead],
            sizeLimits: .init(maximumInputByteCount: 48_000, maximumDecodedByteCount: 48_000),
            linkPolicy: .none,
            accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true),
            compatibility: .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1),
            priority: 110)

        let input = try d2Input()
        #expect(excalidrawShaped.matchTier(for: input) == nil)

        let mermaidBuiltIn = try RendererDescriptor(
            reference: .init(
                packageID: try .init(validating: "org.selfdrivingwiki.built-in"),
                version: try .init(validating: "1.0.0"),
                registrationID: try .init(validating: "mermaid")),
            displayName: "Mermaid",
            implementation: .builtIn(.mermaid),
            matchers: [.extensionFallback(try .init(validating: "mmd"))],
            presentations: [.native],
            supportedEmbeddingRoles: [.disclosureRow],
            approvedAssets: [],
            capabilities: [.inputRead],
            sizeLimits: .init(maximumInputByteCount: 48_000, maximumDecodedByteCount: 48_000),
            linkPolicy: .none,
            accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true),
            compatibility: .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1),
            priority: 100)
        #expect(mermaidBuiltIn.matchTier(for: input) == nil)
    }

    @Test("capabilities, link policy, and embedding roles obey the read-only contract")
    func manifestRulesPinReadOnlyContract() throws {
        #expect(descriptor.capabilities == [.inputRead])
        #expect(descriptor.linkPolicy == .none)
        #expect(!descriptor.capabilities.contains(.externalLink))
        #expect(descriptor.supportedEmbeddingRoles.isEmpty == false)
        #expect(descriptor.supportedEmbeddingRoles == [.disclosureRow])
    }

    @Test("linkPolicy none rejects an externalLink capability at construction")
    func externalLinkCapabilityIsForbiddenWithNonePolicy() throws {
        #expect(throws: RendererValidationError.self) {
            try RendererDescriptor(
                reference: .init(
                    packageID: try .init(validating: D2PackageFixtures.packageID),
                    version: try .init(validating: D2PackageFixtures.packageVersion),
                    registrationID: try .init(validating: D2PackageFixtures.registrationID)),
                displayName: D2PackageFixtures.displayName,
                implementation: .webPackage(.init(path: try .init(validating: "index.html"))),
                matchers: [.extensionFallback(try .init(validating: D2PackageFixtures.sourceExtension))],
                presentations: [.web],
                supportedEmbeddingRoles: [.disclosureRow],
                approvedAssets: [RendererAsset(
                    path: try .init(validating: "index.html"),
                    digest: try .init(hex: "aa0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0a"))],
                capabilities: [.inputRead, .externalLink],
                sizeLimits: .init(maximumInputByteCount: 48_000, maximumDecodedByteCount: 48_000),
                linkPolicy: .none,
                accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true),
                compatibility: .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1),
                priority: D2PackageFixtures.priority)
        }
    }

    @Test("tie-break against built-ins is stable and priority-dominated")
    func tieBreakIsStable() throws {
        let builtInPackageID = try RendererPackageID(validating: "org.selfdrivingwiki.built-in")
        let builtIn = try RendererDescriptor(
            reference: .init(
                packageID: builtInPackageID,
                version: try .init(validating: "1.0.0"),
                registrationID: try .init(validating: "svg")),
            displayName: "SVG",
            implementation: .builtIn(.svg),
            matchers: [.normalizedMIME(try .init(validating: "image/svg+xml"))],
            presentations: [.native],
            supportedEmbeddingRoles: [.disclosureRow],
            approvedAssets: [],
            capabilities: [.inputRead],
            sizeLimits: .init(maximumInputByteCount: 48_000, maximumDecodedByteCount: 48_000),
            linkPolicy: .none,
            accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true),
            compatibility: .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1),
            priority: D2PackageFixtures.priority)

        // Equal priorities: the comparison is the immutable reference key, and
        // package IDs compare ascending, so the outcome never depends on
        // registration or install order. Ascending key order = priority
        // descending, so the built-in (equal priority, lexicographically
        // smaller package ID) sorts before the D2 descriptor.
        #expect(descriptor.stableTieBreakKey != builtIn.stableTieBreakKey)
        #expect(builtIn.stableTieBreakKey < descriptor.stableTieBreakKey)
        #expect(descriptor.stableTieBreakKey > builtIn.stableTieBreakKey)

        // A higher priority sorts before any lower priority regardless of
        // reference ordering.
        let promoted = try RendererDescriptor(
            reference: .init(
                packageID: try .init(validating: D2PackageFixtures.packageID),
                version: try .init(validating: D2PackageFixtures.packageVersion),
                registrationID: try .init(validating: D2PackageFixtures.registrationID)),
            displayName: D2PackageFixtures.displayName,
            implementation: .webPackage(.init(path: try .init(validating: "index.html"))),
            matchers: [.extensionFallback(try .init(validating: D2PackageFixtures.sourceExtension))],
            presentations: [.web],
            supportedEmbeddingRoles: [.disclosureRow],
            approvedAssets: [RendererAsset(
                path: try .init(validating: "index.html"),
                digest: try .init(hex: "aa0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0a"))],
            capabilities: [.inputRead],
            sizeLimits: .init(maximumInputByteCount: 48_000, maximumDecodedByteCount: 48_000),
            linkPolicy: .none,
            accessibility: .init(supportsVoiceOver: true, supportsKeyboardNavigation: true),
            compatibility: .init(minimumProtocolRevision: 1, maximumProtocolRevision: 1),
            priority: D2PackageFixtures.priority + 1)
        #expect(promoted.stableTieBreakKey < builtIn.stableTieBreakKey)
    }
}
