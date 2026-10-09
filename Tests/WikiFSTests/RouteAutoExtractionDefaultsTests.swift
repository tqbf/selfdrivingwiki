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
    }
}
