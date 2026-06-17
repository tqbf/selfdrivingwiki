import Foundation
import Testing
@testable import WikiFSCore

/// Tests for `ZoteroClient`'s request-building, decoding, and status-code mapping
/// — driven entirely by a FAKE fetcher returning canned `(Data, Int)` pairs, no
/// real network. Mirrors `URLIngestServiceTests`'s fake-fetcher pattern.
struct ZoteroClientTests {

    // MARK: - Test double

    /// A fetcher returning a canned response (or throwing). Captures the last
    /// request built, so tests can assert on headers/query items.
    final class FakeFetcher: ZoteroClient.RequestFetcher, @unchecked Sendable {
        var data: Data = Data()
        var statusCode: Int = 200
        var error: Error?
        private(set) var lastRequest: URLRequest?

        func fetch(_ request: URLRequest) async throws -> (data: Data, statusCode: Int) {
            lastRequest = request
            if let error { throw error }
            return (data, statusCode)
        }
    }

    private let config = ZoteroClient.Config(libraryID: "7089244", apiKey: "test-key")

    private func makeClient(_ fetcher: FakeFetcher) -> ZoteroClient {
        ZoteroClient(config: config, fetcher: fetcher)
    }

    // MARK: - Request building

    @Test func searchRequestCarriesAuthHeaders() async throws {
        let fetcher = FakeFetcher()
        fetcher.data = Data("[]".utf8)
        _ = try await makeClient(fetcher).searchItems(query: "consciousness")

        let request = fetcher.lastRequest!
        #expect(request.value(forHTTPHeaderField: "Zotero-API-Key") == "test-key")
        #expect(request.value(forHTTPHeaderField: "Zotero-API-Version") == "3")
        #expect(request.url?.path == "/users/7089244/items")
    }

    @Test func searchRequestCarriesQueryParams() async throws {
        let fetcher = FakeFetcher()
        fetcher.data = Data("[]".utf8)
        _ = try await makeClient(fetcher).searchItems(query: "Lamme 2006", limit: 25)

        let items = URLComponents(url: fetcher.lastRequest!.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(items.contains(URLQueryItem(name: "q", value: "Lamme 2006")))
        #expect(items.contains(URLQueryItem(name: "qmode", value: "titleCreatorYear")))
        #expect(items.contains(URLQueryItem(name: "itemType", value: "-attachment")))
        #expect(items.contains(URLQueryItem(name: "limit", value: "25")))
    }

    @Test func emptyQueryOmitsQAndQmode() async throws {
        let fetcher = FakeFetcher()
        fetcher.data = Data("[]".utf8)
        _ = try await makeClient(fetcher).searchItems(query: "   ", limit: 1)

        let items = URLComponents(url: fetcher.lastRequest!.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(!items.contains { $0.name == "q" })
        #expect(!items.contains { $0.name == "qmode" })
    }

    @Test func childrenRequestTargetsItemKey() async throws {
        let fetcher = FakeFetcher()
        fetcher.data = Data("[]".utf8)
        _ = try await makeClient(fetcher).childAttachments(ofItemKey: "NXYPZL8Q")
        #expect(fetcher.lastRequest?.url?.path == "/users/7089244/items/NXYPZL8Q/children")
    }

    // MARK: - Decoding

    private let itemJSON = """
        [{
            "key": "NXYPZL8Q", "version": 271,
            "data": {
                "itemType": "journalArticle",
                "title": "A Semantic Dataflow Logger",
                "date": "2016",
                "creators": [
                    {"creatorType": "author", "firstName": "Kenji", "lastName": "Ito"},
                    {"creatorType": "author", "firstName": "Kohei", "lastName": "Kaneko"}
                ]
            }
        }]
        """

    @Test func decodeItemsParsesMinimalFields() throws {
        let items = try ZoteroClient.decodeItems(Data(itemJSON.utf8))
        #expect(items.count == 1)
        #expect(items[0].key == "NXYPZL8Q")
        #expect(items[0].version == 271)
        #expect(items[0].itemType == "journalArticle")
        #expect(items[0].title == "A Semantic Dataflow Logger")
        #expect(items[0].date == "2016")
        #expect(items[0].creatorSummary == "Ito, K.; Kaneko, K.")
    }

    @Test func decodeItemsHandlesOrgCreatorAndNoCreators() throws {
        let json = """
            [
              {"key": "A1", "version": 1, "data": {"itemType": "report", "creators": [{"name": "WHO"}]}},
              {"key": "A2", "version": 1, "data": {"itemType": "report"}}
            ]
            """
        let items = try ZoteroClient.decodeItems(Data(json.utf8))
        #expect(items[0].creatorSummary == "WHO")
        #expect(items[1].creatorSummary == nil)
    }

    private let attachmentJSON = """
        [
          {
            "key": "DJLXA7DG", "version": 271,
            "data": {
                "itemType": "attachment", "parentItem": "NXYPZL8Q",
                "linkMode": "imported_file", "filename": "Ito and Kaneko - 2016.pdf",
                "contentType": "application/pdf"
            }
          },
          {
            "key": "NOTE1", "version": 1,
            "data": {"itemType": "note"}
          }
        ]
        """

    @Test func decodeAttachmentsFiltersOutNotesAndParsesFields() throws {
        let attachments = try ZoteroClient.decodeAttachments(Data(attachmentJSON.utf8))
        #expect(attachments.count == 1)
        #expect(attachments[0].key == "DJLXA7DG")
        #expect(attachments[0].parentItem == "NXYPZL8Q")
        #expect(attachments[0].linkMode == "imported_file")
        #expect(attachments[0].filename == "Ito and Kaneko - 2016.pdf")
        #expect(attachments[0].contentType == "application/pdf")
        #expect(attachments[0].hasLocalCopy)
    }

    @Test func linkedModesReportNoLocalCopy() throws {
        let json = """
            [{"key": "L1", "version": 1, "data": {"itemType": "attachment", "linkMode": "linked_url"}}]
            """
        let attachments = try ZoteroClient.decodeAttachments(Data(json.utf8))
        #expect(!attachments[0].hasLocalCopy)
    }

    @Test func malformedJSONThrowsDecodingError() {
        #expect(throws: ZoteroClient.ZoteroError.self) {
            try ZoteroClient.decodeItems(Data("not json".utf8))
        }
    }

    // MARK: - Status-code mapping

    @Test func statusMappingForKnownCodes() {
        #expect(throws: Never.self) { try ZoteroClient.checkStatus(200) }
        #expect(throws: ZoteroClient.ZoteroError.unauthorized) { try ZoteroClient.checkStatus(403) }
        #expect(throws: ZoteroClient.ZoteroError.notFound) { try ZoteroClient.checkStatus(404) }
        #expect(throws: ZoteroClient.ZoteroError.httpStatus(500)) { try ZoteroClient.checkStatus(500) }
    }

    @Test func unauthorizedPropagatesFromSearch() async throws {
        let fetcher = FakeFetcher()
        fetcher.statusCode = 403
        await #expect(throws: ZoteroClient.ZoteroError.unauthorized) {
            try await makeClient(fetcher).searchItems(query: "x")
        }
    }

    @Test func transportErrorWrappedAsNetwork() async throws {
        let fetcher = FakeFetcher()
        fetcher.error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "offline"])
        await #expect(throws: (any Error).self) {
            try await makeClient(fetcher).searchItems(query: "x")
        }
    }

    // MARK: - verifyConnection

    @Test func verifyConnectionSucceedsOnOK() async throws {
        let fetcher = FakeFetcher()
        fetcher.data = Data("[]".utf8)
        try await makeClient(fetcher).verifyConnection()
    }

    @Test func verifyConnectionFailsOnBadKey() async throws {
        let fetcher = FakeFetcher()
        fetcher.statusCode = 403
        await #expect(throws: ZoteroClient.ZoteroError.unauthorized) {
            try await makeClient(fetcher).verifyConnection()
        }
    }
}
