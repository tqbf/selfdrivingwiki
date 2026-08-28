import Foundation
import Testing
import WikiFSTypes
@testable import WikiFSCore

/// `ExtractorRouteID` identity, ordering, normalization, and coding, plus
/// `ExtractorRouteSelectionRecord` deterministic normalization.
struct ExtractorRouteTests {

    // MARK: - AC.1: route identity is its own typed namespace

    /// The route type cannot be interchanged with the namespaces it is built
    /// from. The cross-type half of this contract is compile-time (a route is
    /// not an `ExtractorKind`, a `ExtractorMIMEType`, or a raw string — those
    /// arguments simply do not type-check); this test pins the runtime half:
    /// identity is the *pair*, so kind and MIME each contribute distinction.
    @Test func routeNamespacesRemainDistinct() throws {
        let pdf = ExtractorRouteID.canonicalPDF
        let html = ExtractorRouteID.canonicalHTML

        // Same kind, different MIME → different routes.
        let xhtml = try ExtractorRouteID(
            kind: .html,
            mimeType: ExtractorMIMEType(validating: "application/xhtml+xml"))
        #expect(xhtml != html)
        #expect(xhtml.kind == html.kind)

        // Same MIME, different kind → different routes.
        let pdfMIME = try ExtractorMIMEType(validating: "application/pdf")
        let otherKind = ExtractorRouteID(kind: .html, mimeType: pdfMIME)
        #expect(otherKind != pdf)
        #expect(otherKind.mimeType == pdf.mimeType)

        // The two canonical routes are the only canonical ones.
        #expect(pdf.isCanonical)
        #expect(html.isCanonical)
        #expect(xhtml.isCanonical == false)

        // A route identity helper accepts routes only — the adjacent lines show
        // the distinct namespaces that must NOT satisfy it (compile-time).
        func identity(_ route: ExtractorRouteID) -> ExtractorRouteID { route }
        #expect(identity(pdf) == pdf)
        // identity(.pdf)                      // ExtractorKind: does not compile
        // identity(pdfMIME)                   // ExtractorMIMEType: does not compile
        // identity("application/pdf")         // raw string: does not compile
    }

    @Test func canonicalRoutesUseNormalizedMIME() {
        #expect(ExtractorRouteID.canonicalPDF.kind == .pdf)
        #expect(ExtractorRouteID.canonicalPDF.mimeType.rawValue == "application/pdf")
        #expect(ExtractorRouteID.canonicalHTML.kind == .html)
        #expect(ExtractorRouteID.canonicalHTML.mimeType.rawValue == "text/html")
    }

    // MARK: - Normalization and ordering

    @Test func normalizingInitCanonicalizesCaseAndWhitespace() throws {
        let route = try #require(ExtractorRouteID(normalizing: .pdf, mimeTypeString: "  Application/PDF \n"))
        #expect(route == .canonicalPDF)
        #expect(ExtractorRouteID(normalizing: .pdf, mimeTypeString: "not a mime") == nil)
        #expect(ExtractorRouteID(normalizing: .pdf, mimeTypeString: "") == nil)
    }

    @Test func routeOrderingIsKindThenMIME() throws {
        let htmlTagBased = try ExtractorRouteID(kind: .html, mimeType: ExtractorMIMEType(validating: "application/xhtml+xml"))
        let htmlCanonical = ExtractorRouteID.canonicalHTML
        let pdfCanonical = ExtractorRouteID.canonicalPDF

        // Kind raw value orders first ("html" < "pdf"), then MIME raw value.
        #expect(htmlCanonical < pdfCanonical)
        #expect(htmlTagBased < pdfCanonical)
        #expect(htmlTagBased < htmlCanonical || htmlCanonical < htmlTagBased) // total order within a kind
    }

    // MARK: - Coding

    @Test func routeCodingRoundTripsKeyedShape() throws {
        let data = try JSONEncoder().encode(ExtractorRouteID.canonicalPDF)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(object["kind"] == "pdf")
        #expect(object["mimeType"] == "application/pdf")
        let decoded = try JSONDecoder().decode(ExtractorRouteID.self, from: data)
        #expect(decoded == .canonicalPDF)
    }

    @Test func routeCodingRejectsInvalidMIME() {
        #expect(throws: Error.self) {
            try JSONDecoder().decode(ExtractorRouteID.self, from: Data(#"{"kind":"pdf","mimeType":"not a mime"}"#.utf8))
        }
    }

    // MARK: - Record normalization

    @Test func recordNormalizationKeepsCanonicallyGreatestPerRoute() throws {
        let builtIn = ExtractorRouteSelectionRecord(
            route: .canonicalPDF,
            extractor: .builtIn(.pdf(.localPdf2md)))
        let logical = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.example.pdf"),
            registrationID: try ExtractorRegistrationID(validating: "main"))
        let installed = ExtractorRouteSelectionRecord(
            route: .canonicalPDF,
            extractor: .installed(logical))
        let htmlRecord = ExtractorRouteSelectionRecord(
            route: .canonicalHTML,
            extractor: .builtIn(.html(.tagBased)))

        // The installed reference sorts after the built-in one canonically.
        let expectedWinner = [builtIn, installed].sorted().last

        // Both original orders produce the identical normalized result.
        let first = [builtIn, installed, htmlRecord].normalizedForPersistence()
        let second = [installed, builtIn, htmlRecord].normalizedForPersistence()
        #expect(first.records == second.records)
        #expect(first.droppedDuplicates == 1)
        #expect(second.droppedDuplicates == 1)
        #expect(first.records.count == 2)
        #expect(first.records.contains(htmlRecord))
        #expect(first.records.contains { $0 == expectedWinner })

        // Duplicate-free input is preserved in sorted route order.
        let clean = [htmlRecord, builtIn].normalizedForPersistence()
        #expect(clean.records == [htmlRecord, builtIn])
        #expect(clean.droppedDuplicates == 0)
    }
}
