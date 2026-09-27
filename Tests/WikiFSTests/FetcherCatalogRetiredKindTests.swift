import Foundation
import Testing
import WikiFSTypes

/// AC.1 — catalog read tolerance for the retired `zotero` extractor kind.
///
/// The fetcher role replaced the `zotero` extractor kind, and that raw value
/// no longer decodes into `ExtractorKind`. A catalog written by an older
/// host (whose records still declare the retired kind) must stay READABLE:
/// the retired record is skipped with a diagnostic instead of failing the
/// whole read, its digest reservation survives, and every OTHER malformed
/// record remains fatal.
@Suite("Fetcher catalog retired-kind tolerance")
struct FetcherCatalogRetiredKindTests {

    // MARK: - Fixtures

    private static let pdfDigest =
        "1111111111111111111111111111111111111111111111111111111111111111"
    private static let zoteroDigest =
        "2222222222222222222222222222222222222222222222222222222222222222"

    /// A schema-1 catalog document: (a) one record whose registration
    /// declares the retired `zotero` kind, and (b) one valid PDF record.
    /// Both carry explicit digest reservations.
    private static func catalogJSON(
        extraRecord: String? = nil
    ) -> String {
        var records = """
              {
                "revision": {
                  "packageID": "org.selfdrivingwiki.zotero",
                  "version": "1.0.0",
                  "digest": "\(zoteroDigest)"
                },
                "displayName": "Zotero Attachment",
                "protocolRevision": 3,
                "manifestRevision": 3,
                "launch": {"mode": "direct"},
                "registrations": [
                  {
                    "id": "attachment",
                    "displayName": "Zotero Attachment",
                    "kinds": ["zotero"],
                    "mimeTypes": ["application/zotero"]
                  }
                ],
                "capabilities": ["network"],
                "installedAt": "2026-01-01T00:00:00+00:00"
              },
              {
                "revision": {
                  "packageID": "org.selfdrivingwiki.pdf2md",
                  "version": "1.0.0",
                  "digest": "\(pdfDigest)"
                },
                "displayName": "PDF",
                "protocolRevision": 1,
                "manifestRevision": 1,
                "launch": {"mode": "direct"},
                "registrations": [
                  {
                    "id": "pdf",
                    "displayName": "PDF",
                    "kinds": ["pdf"],
                    "mimeTypes": ["application/pdf"]
                  }
                ],
                "capabilities": [],
                "installedAt": "2026-01-01T00:00:00+00:00"
              }
        """
        if let extraRecord {
            records += ",\n              \(extraRecord)"
        }
        return """
        {
          "schemaVersion": 1,
          "generation": 1,
          "records": [
        \(records)
          ],
          "reservations": [
            {
              "reservation": {
                "packageID": "org.selfdrivingwiki.zotero",
                "version": "1.0.0"
              },
              "digest": "\(zoteroDigest)"
            },
            {
              "reservation": {
                "packageID": "org.selfdrivingwiki.pdf2md",
                "version": "1.0.0"
              },
              "digest": "\(pdfDigest)"
            }
          ]
        }
        """
    }

    private static func decode(_ json: String) throws -> ExtractorPackageCatalog {
        try JSONDecoder().decode(ExtractorPackageCatalog.self, from: Data(json.utf8))
    }

    // MARK: - Read tolerance

    @Test func retiredKindRecordSkippedAndPDFRecordDecodes() throws {
        let catalog = try Self.decode(Self.catalogJSON())

        // Exactly the zotero record was skipped…
        #expect(catalog.skippedRetiredKindRecordCount == 1)
        #expect(catalog.skippedUnknownRevisionRecordCount == 0)
        // …and the PDF record decoded.
        #expect(catalog.records.count == 1)
        let pdf = try #require(catalog.records.first)
        #expect(pdf.revision.packageID.rawValue == "org.selfdrivingwiki.pdf2md")
        #expect(pdf.registrations.first?.kinds == [.pdf])
    }

    @Test func bothDigestReservationsSurviveTheSkip() throws {
        let catalog = try Self.decode(Self.catalogJSON())
        #expect(catalog.reservations.count == 2)
        let reservedIDs = Set(catalog.reservations.map { $0.reservation.packageID.rawValue })
        #expect(reservedIDs.contains("org.selfdrivingwiki.zotero"))
        #expect(reservedIDs.contains("org.selfdrivingwiki.pdf2md"))
        // The retired record's exact digest survived untouched.
        let zotero = try #require(catalog.reservations.first {
            $0.reservation.packageID.rawValue == "org.selfdrivingwiki.zotero"
        })
        #expect(zotero.digest.hex == Self.zoteroDigest)
    }

    @Test func encodingTheDecodedCatalogDropsTheSkippedRecordAndKeepsReservations() throws {
        let catalog = try Self.decode(Self.catalogJSON())
        let encoded = try JSONEncoder().encode(catalog)
        let roundTripped = try Self.decode(String(decoding: encoded, as: UTF8.self))

        #expect(roundTripped.records.count == 1)
        #expect(roundTripped.records.first?.revision.packageID.rawValue == "org.selfdrivingwiki.pdf2md")
        #expect(roundTripped.reservations.count == 2)
        #expect(roundTripped.skippedRetiredKindRecordCount == 0)

        // The encoded records array holds only the PDF record; the retired
        // record appears nowhere except through its surviving reservation.
        // (Structural check: JSONEncoder key order is per-process hash
        // order, so byte-level substring matching would be flaky.)
        let object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let encodedRecords = try #require(object["records"] as? [[String: Any]])
        #expect(encodedRecords.count == 1)
        let encodedRevision = try #require(
            encodedRecords.first?["revision"] as? [String: Any])
        #expect(encodedRevision["packageID"] as? String == "org.selfdrivingwiki.pdf2md")
        let encodedReservations = try #require(
            object["reservations"] as? [[String: Any]])
        #expect(encodedReservations.count == 2)
        let reservedIDs = Set(encodedReservations.compactMap {
            ($0["reservation"] as? [String: Any])?["packageID"] as? String
        })
        #expect(reservedIDs == [
            "org.selfdrivingwiki.zotero", "org.selfdrivingwiki.pdf2md",
        ])
    }

    @Test func unrelatedMalformedRecordStillThrows() {
        // A record that does NOT declare the retired kind but carries a bad
        // digest (5 hex characters) is unrelated malformed data: the read
        // stays strict and throws.
        let malformed = """
        {
          "revision": {
            "packageID": "org.selfdrivingwiki.broken",
            "version": "1.0.0",
            "digest": "abcde"
          },
          "displayName": "Broken",
          "protocolRevision": 1,
          "manifestRevision": 1,
          "launch": {"mode": "direct"},
          "registrations": [
            {
              "id": "pdf",
              "displayName": "PDF",
              "kinds": ["pdf"],
              "mimeTypes": ["application/pdf"]
            }
          ],
          "capabilities": [],
          "installedAt": "2026-01-01T00:00:00+00:00"
        }
        """
        #expect(throws: (any Error).self) {
            _ = try Self.decode(Self.catalogJSON(extraRecord: malformed))
        }
    }
}
