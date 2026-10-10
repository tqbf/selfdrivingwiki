import Foundation
import Testing
import WikiFSTypes
@testable import WikiFSCore

/// Verifies the bundled default-route policy's import-conversion table
/// (issue #1380): HTML selects the reviewed Defuddle package as both the
/// default route selection and an import-converting route, a policy file
/// without the table still decodes (older bundled data), and the applied
/// defaults present Defuddle as the HTML selection label the Extract button
/// and the session wiring read.
@Suite("Route auto-extraction bundled policy")
struct RouteAutoExtractionDefaultsTests {

    @Test("bundled policy selects HTML for import conversion via Defuddle")
    func bundledPolicySelectsHTMLForImportConversion() throws {
        let bundled = ExtractorRouteDefaults.bundled

        #expect(bundled.autoExtractKinds == [.html])

        let selection = bundled.routeExtractors.first { $0.route == .canonicalHTML }?.extractor
        guard case .installed(let logical)? = selection else {
            Issue.record("bundled HTML route has no installed default selection")
            return
        }
        #expect(logical.packageID.rawValue == "org.selfdrivingwiki.defuddle")
        #expect(logical.registrationID.rawValue == "article")
    }

    @Test("applied defaults present Defuddle as the HTML selection label")
    func appliedDefaultsLabelHTMLAsDefuddle() {
        let config = ExtractionConfig().applying(defaults: .bundled)
        #expect(config.htmlSelectionLabel == .defuddle)
    }

    @Test("a policy without the auto-extraction table decodes empty")
    func missingTableDecodesEmpty() throws {
        let json = #"{"routeExtractors": [], "routeFetchers": []}"#
        let defaults = try JSONDecoder().decode(
            ExtractorRouteDefaults.self, from: Data(json.utf8))

        #expect(defaults.routeAutoExtraction.isEmpty)
        #expect(defaults.autoExtractKinds.isEmpty)
        #expect(defaults.routeImportTranscription.isEmpty)
    }

    // MARK: - Import-transcription policy (issue #1379, revised)

    @Test("bundled policy covers the podcast routes and NOT the YouTube route")
    func bundledImportTranscriptionPolicy() throws {
        let bundled = ExtractorRouteDefaults.bundled

        let rssPodcast = ExtractorRouteID(
            kind: .podcastTranscript,
            mimeType: try ExtractorMIMEType(validating: "audio/podcast"))
        let applePodcast = ExtractorRouteID(
            kind: .applePodcastTranscript,
            mimeType: try ExtractorMIMEType(validating: "audio/apple-podcast"))
        let youtube = ExtractorRouteID(
            kind: .youtubeTranscript,
            mimeType: try ExtractorMIMEType(validating: "video/youtube"))

        #expect(bundled.importTranscriptionWanted(for: rssPodcast))
        #expect(bundled.importTranscriptionWanted(for: applePodcast))
        // YouTube import stays explicit: the Transcribe action is the only
        // path, even though the route's default selection is the reviewed
        // package.
        #expect(bundled.importTranscriptionWanted(for: youtube) == false)
        // Conversion policy and transcription policy stay separate tables.
        #expect(bundled.routeAutoExtraction.contains {
            $0.route == .canonicalHTML
        })
    }

    @Test("a policy without the import-transcription table decodes empty")
    func missingImportTranscriptionTableDecodesEmpty() throws {
        let json = """
        {"routeExtractors": [], "routeAutoExtraction": [
            {"route": {"kind": "html", "mimeType": "text/html"}}
        ]}
        """
        let defaults = try JSONDecoder().decode(
            ExtractorRouteDefaults.self, from: Data(json.utf8))

        #expect(defaults.routeImportTranscription.isEmpty)
        #expect(defaults.importTranscriptionWanted(for: .canonicalHTML) == false)
    }

    @Test("import-transcription records round-trip through their route identity")
    func importTranscriptionRecordsRoundTrip() throws {
        // ExtractorRouteDefaults is persist-decodable only, so the record
        // round-trips through the same JSON shape the policy file carries.
        let json = """
        {"routeExtractors": [], "routeImportTranscription": [
            {"route": {"kind": "html", "mimeType": "text/html"}}
        ]}
        """
        let decoded = try JSONDecoder().decode(
            ExtractorRouteDefaults.self, from: Data(json.utf8))

        #expect(decoded.routeImportTranscription.count == 1)
        #expect(decoded.routeImportTranscription.first?.route == .canonicalHTML)
        #expect(decoded.importTranscriptionWanted(for: .canonicalHTML))
        #expect(decoded.importTranscriptionWanted(
            for: ExtractorRouteID(
                kind: .youtubeTranscript,
                mimeType: try ExtractorMIMEType(validating: "video/youtube"))) == false)
    }
}
