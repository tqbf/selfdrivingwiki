import Foundation
import Testing
@testable import WikiFSEngine
import WikiFSTypes

/// Pins the host-capability derivation behind import auto-extraction kinds.
/// The wiring computes package-only kinds as claimed kinds minus
/// `ExtractorRouteHostCatalog.hostBackendKinds`. A previous derivation
/// subtracted the route DESCRIPTOR kinds instead — the DOCX Settings display
/// row made that set empty, and import auto-extraction silently stopped
/// firing. These tests fail if the derivation degrades to empty again.
@Suite("Host backend kinds")
struct HostBackendKindsTests {
    /// The choice categories, not the route display rows, decide whether the
    /// host can execute a kind. DOCX's only host choice is `.prompt`, so it
    /// is package-only even though its route has a Settings display row.
    @Test func hostBackendKindsCoverOnlyBuiltInAndConnectedServiceRoutes() {
        #expect(ExtractorRouteHostCatalog.hostBackendKinds == [.pdf, .html])
        #expect(ExtractorRouteHostCatalog.hostBackendKinds.contains(.docx) == false)
    }

    /// The exact computation the session wiring performs: claimed kinds minus
    /// host backend kinds. With the current reviewed registrations claimed
    /// (pdf, html, docx), the package-only set is exactly docx — never empty.
    @Test func packageOnlyKindsDerivationNeverEmptiesForClaimedDocx() {
        let claimedInputs = RegisteredExtractionInputs(claims: [
            .init(kind: .pdf, mimeTypes: ["application/pdf"], filenameExtensions: ["pdf"]),
            .init(kind: .html, mimeTypes: ["text/html"], filenameExtensions: ["html"]),
            .init(
                kind: .docx,
                mimeTypes: [MimeType.docx],
                filenameExtensions: ["docx"]),
        ])
        let packageOnlyKinds = Set(claimedInputs.claims.map(\.kind))
            .subtracting(ExtractorRouteHostCatalog.hostBackendKinds)
        #expect(packageOnlyKinds == [.docx])
        #expect(packageOnlyKinds.isEmpty == false)
    }

    /// A route the host has never heard of (a future package-only kind)
    /// contributes no host backend: its claimed kind stays package-only.
    @Test func unclaimedRouteStaysPackageOnly() {
        let claimedInputs = RegisteredExtractionInputs(claims: [
            .init(kind: .docx, mimeTypes: [MimeType.docx], filenameExtensions: ["docx"]),
        ])
        let packageOnlyKinds = Set(claimedInputs.claims.map(\.kind))
            .subtracting(ExtractorRouteHostCatalog.hostBackendKinds)
        #expect(packageOnlyKinds == [.docx])
    }
}
