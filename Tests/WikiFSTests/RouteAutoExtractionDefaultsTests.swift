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

    @Test("bundled policy covers the caption routes INCLUDING YouTube")
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
        // Caption-based transcription is cheap and covered at import.
        #expect(bundled.importTranscriptionWanted(for: youtube))
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

    // MARK: - Speech policy (on-device transcription)

    /// The on-device speech acquisition is NEVER an automatic policy row:
    /// the synthetic audio fetcher route exists only as a fetcher selection
    /// (an explicit speech job resolves it directly from the persisted
    /// intent), and it can never appear in the import-conversion or
    /// import-transcription tables. Import never enqueues `.onDeviceSpeech`,
    /// even with the audio fetcher active.
    @Test("speech never runs automatically from bundled policy")
    func speechNeverAutomatic() throws {
        let bundled = ExtractorRouteDefaults.bundled

        // The fetcher selection exists for the explicit speech action.
        let selection = bundled.fetcherDefault(for: .canonicalAudioAcquire)
        guard case .installed(let logical)? = selection else {
            Issue.record("bundled audio-acquire fetcher route has no default selection")
            return
        }
        #expect(logical.packageID.rawValue == "org.selfdrivingwiki.audio-acquire")
        #expect(logical.registrationID.rawValue == "audio")

        // Automatic policy never mentions it. The automatic tables are
        // extractor-kind tables, so a fetcher route cannot even be
        // expressed there — assert the tables stay free of the synthetic
        // MIME and that no route selects speech behavior.
        let synthetic = MimeType.audioXWikiAudioAcquire
        #expect(bundled.routeAutoExtraction.contains { record in
            record.route.mimeType.rawValue == synthetic
        } == false)
        #expect(bundled.routeImportTranscription.contains { record in
            record.route.mimeType.rawValue == synthetic
        } == false)
    }

    @Test("the synthetic audio route is absent from a policy file without it")
    func syntheticRouteAbsentDecodesEmpty() throws {
        let json = #"{"routeExtractors": [], "routeFetchers": []}"#
        let defaults = try JSONDecoder().decode(
            ExtractorRouteDefaults.self, from: Data(json.utf8))
        #expect(defaults.fetcherDefault(for: .canonicalAudioAcquire) == nil)
    }
}
