import Foundation
import Testing
@testable import WikiFSCore

/// `HtmlExtractionBackend` — the typed enum persisted in
/// `ExtractionConfig.htmlBackend` (issue #799 PR1). Mirrors `ExtractionBackend`
/// (PDF) tests: Codable round-trip for each case, displayName sanity, raw-value
/// stability (so the JSON-side format doesn't drift between releases), and
/// `CaseIterable` ordering locked in — the Settings picker's iteration order
/// and the round-trip JSON keys both depend on it.
struct HtmlExtractionBackendTests {

    @Test func codableRoundTripsAllCases() throws {
        for backend in HtmlExtractionBackend.allCases {
            let encoded = try JSONEncoder().encode(backend)
            let decoded = try JSONDecoder().decode(HtmlExtractionBackend.self, from: encoded)
            #expect(decoded == backend)
        }
    }

    @Test func stringRawValueRoundTripsThroughJSON() throws {
        // The raw value IS the JSON string in extraction-config.json, so a
        // config written by an older release of this same code reads back the
        // same case. Lock the literal strings to prevent silent renames.
        for (backend, raw) in [
            (HtmlExtractionBackend.defuddle, "defuddle"),
            (HtmlExtractionBackend.tagBased, "tagBased"),
        ] {
            let json = Data(#""\#(raw)""#.utf8)
            let decoded = try JSONDecoder().decode(HtmlExtractionBackend.self, from: json)
            #expect(decoded == backend)
            #expect(backend.rawValue == raw)
        }
    }

    @Test func unknownRawValueThrows() {
        // A backend not yet invented (future Whisper / readability / etc.) or a
        // typo doesn't decode as a phantom case — it errors. The
        // `ExtractionConfig` decode then degrades this throw to nil via its
        // `try?` wrapper (see `unknownHtmlAndPodcastBackendValuesDegradeToNil`
        // in ExtractionConfigTests); here we lock the raw enum's own contract.
        let json = Data(#""whisper""#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(HtmlExtractionBackend.self, from: json)
        }
    }

    @Test func allCasesMatchesExpectedCasesInOrder() {
        // The Settings picker iterates `allCases` — lock the order so a
        // source-order swap in the enum doesn't silently shuffle the picker.
        #expect(HtmlExtractionBackend.allCases == [.defuddle, .tagBased])
    }

    @Test func displayNameNonEmptyAndDistinctPerCase() {
        // A bare or duplicate displayName would either render an empty picker
        // row or two indistinguishable rows; either is a UI bug. Lock both.
        let names = HtmlExtractionBackend.allCases.map(\.displayName)
        #expect(names.allSatisfy { !$0.isEmpty })
        #expect(Set(names).count == names.count)
    }

    @Test func displayNameStability() {
        // Lock the literal strings shown in the Settings picker & the
        // Extract/Re-extract menu (future PR2). Renames are user-visible.
        #expect(HtmlExtractionBackend.defuddle.displayName == "Defuddle (article extraction)")
        #expect(HtmlExtractionBackend.tagBased.displayName == "Tag-based (built-in)")
    }
}
