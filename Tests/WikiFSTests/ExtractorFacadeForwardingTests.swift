import Foundation
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

    /// Marks that the installed services actually received the YouTube call:
    /// the stub throws its own error so a forwarded call is distinguishable
    /// from the facade's protocol-default `.unavailable`.
    private struct TranscriptStubServices: ExtractionServices {
        enum Marker: Error { case youtubeReceived }

        func prepare(backendOverride: ExtractionBackend?) async throws -> ExtractionPreparation {
            throw Marker.youtubeReceived
        }

        func prepareYouTubeTranscript() async throws -> ProcessPackageYouTubeTranscript {
            throw Marker.youtubeReceived
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

    @Test func prepareYouTubeTranscriptForwardsToInstalledServices() async throws {
        let facade = MutableExtractionServices()
        await facade.install(TranscriptStubServices(), for: .init())

        // Before forwarding existed, this threw the protocol-default
        // `.unavailable` regardless of the installed services, failing every
        // queued YouTube transcription with "Extraction services are
        // unavailable."
        await #expect(throws: TranscriptStubServices.Marker.youtubeReceived) {
            _ = try await facade.prepareYouTubeTranscript()
        }
    }

    /// The class-level net: every requirement the `ExtractionServices`
    /// protocol declares must appear as a forwarded method on
    /// `MutableExtractionServices`. A new protocol seam without a facade
    /// forwarder compiles (the protocol extension supplies a throwing
    /// default) and dead-ends that route at runtime — this scan turns it
    /// into a build-time-visible failure.
    @Test func mutableFacadeForwardsEveryProtocolSeam() throws {
        let root = URL(fileURLWithPath: #filePath)
        var directory = root.deletingLastPathComponent()
        for _ in 0..<4 where FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Package.swift").path) == false {
            directory = directory.deletingLastPathComponent()
        }
        let source = try String(
            contentsOf: directory.appendingPathComponent(
                "Sources/WikiFSEngine/ExtractionCoordinator.swift"),
            encoding: .utf8)

        let protocolStart = try #require(source.range(of: "public protocol ExtractionServices"))
        let body = String(source[protocolStart.upperBound...])
        let protocolEnd = try #require(body.range(of: "\n}"))
        let declaration = String(body[..<protocolEnd.lowerBound])

        let names = try NSRegularExpression(pattern: #"\bfunc ([A-Za-z]\w*)"#)
            .matches(in: declaration, range: NSRange(declaration.startIndex..., in: declaration))
            .compactMap { Range($0.range(at: 1), in: declaration).map { String(declaration[$0]) } }
        #expect(names.isEmpty == false, "no protocol requirements found to scan")

        let facadeStart = try #require(source.range(of: "actor MutableExtractionServices"))
        let facade = String(source[facadeStart.upperBound...])
        for name in names {
            #expect(
                facade.contains("func \(name)"),
                "MutableExtractionServices does not forward \(name); calls fall through to the throwing protocol default")
        }
    }
}
