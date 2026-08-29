import Testing
import WikiFSMarkdown
@testable import WikiFSEngine

/// The process facade is what production consumers resolve as
/// `ExtractionServices`. Both preparation entry points must forward to the
/// installed services: a missing forwarder silently turns every valid HTML
/// selection into an unavailable service.
@Suite("Extractor facade forwarding")
struct ExtractorFacadeForwardingTests {
    private struct StubExtractor: HtmlMarkdownExtractor {
        func extract(html: String) async -> HtmlExtractionResult? { nil }
    }

    private struct StubServices: ExtractionServices {
        let extractor: any HtmlMarkdownExtractor

        func prepare(backendOverride: ExtractionBackend?) async throws -> ExtractionPreparation {
            throw ExtractionServicesError.unavailable
        }

        func prepareHTML(
            backendOverride: HtmlExtractionBackend?
        ) async throws -> any HtmlMarkdownExtractor {
            extractor
        }
    }

    @Test func prepareHTMLForwardsToInstalledServices() async throws {
        let facade = MutableExtractionServices()
        let installation = MutableExtractionServices.Installation()
        await facade.install(StubServices(extractor: StubExtractor()), for: installation)

        // Before forwarding existed, this threw `.unavailable` regardless of
        // the installed services, dead-ending every app HTML selection.
        let forwarded = try await facade.prepareHTML(backendOverride: nil)
        let result = await forwarded.extract(html: "x")
        #expect(result == nil)
    }

    @Test func invalidatedInstallationBecomesUnavailableAgain() async throws {
        let facade = MutableExtractionServices()
        let installation = MutableExtractionServices.Installation()
        await facade.install(StubServices(extractor: StubExtractor()), for: installation)
        await facade.invalidate(installation)

        await #expect(throws: ExtractionServicesError.unavailable) {
            _ = try await facade.prepareHTML(backendOverride: nil)
        }
    }
}
