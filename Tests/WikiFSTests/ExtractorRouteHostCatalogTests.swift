#if os(macOS)
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine

/// #1177: the host catalog is the single presentation map from well-known
/// adapter IDs to roles. Unknown IDs and non-host references resolve to nil
/// so callers take their generic fallback paths; the Docling family is the
/// one cross-namespace exception (retired host name and reviewed installed
/// lineage present identically).
@Suite("Extractor route host catalog presentation roles")
struct ExtractorRouteHostCatalogTests {
    @Test func wellKnownAdapterIDsMapToRoles() {
        func role(_ rawValue: String) -> ExtractorRouteHostRole? {
            ExtractorRouteHostCatalog.role(for: ExtractorRouteHostCatalog.hostReference(rawValue))
        }

        #expect(role("acp") == .connectedServiceACP)
        #expect(role("anthropic") == .retiredDirectAnthropicAPI)
        #expect(role("gemini") == .retiredDirectGeminiAPI)
        #expect(role("doclingServe") == .doclingLineage)
        #expect(role("localPdf2md") == .pdf2mdLineage)
        #expect(role("defuddle") == .defuddleLineage)
        #expect(role("tagBased") == .builtInTagBased)
        #expect(role("future-adapter") == nil)
    }

    @Test func doclingFamilySpansNamespaces() {
        #expect(ExtractorRouteHostCatalog.role(for: ExtractorRouteHostCatalog.legacyDoclingServeReference) == .doclingLineage)
        #expect(ExtractorRouteHostCatalog.role(for: .installed(ProcessExtractionServices.reviewedDoclingLogical)) == .doclingLineage)
    }

    @Test func otherReferencesResolveToNil() {
        #expect(ExtractorRouteHostCatalog.role(for: nil) == nil)
        #expect(ExtractorRouteHostCatalog.role(for: ExtractionBackendReference.none) == nil)
        #expect(ExtractorRouteHostCatalog.role(for: .installed(ProcessExtractionServices.reviewedPDFLogical)) == nil)
    }
}
#endif
