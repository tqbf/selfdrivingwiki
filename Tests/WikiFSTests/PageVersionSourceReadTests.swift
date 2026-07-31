import Foundation
import Testing
@testable import WikiFSCore

struct PageVersionSourceReadTests {
    private struct PageFixture {
        let id: PageID
        let title: String
    }

    private func preparedStore() throws -> (GRDBWikiStore, URL, PageFixture, [SourceSummary]) {
        let url = try MetadataSQLiteFixtureSupport.fileURL(prefix: "page-version-sources")
        let store = try GRDBWikiStore(databaseURL: url)
        let page = try store.createPage(title: "Evidence")
        let sources = try [
            store.addSource(filename: "zeta.txt", data: Data("z".utf8)),
            store.addSource(filename: "alpha.txt", data: Data("a".utf8)),
            store.addSource(filename: "beta.txt", data: Data("b".utf8)),
        ]
        return (store, url, .init(id: page.id, title: "Evidence"), sources)
    }

    private func withClosedStore<T>(
        _ fixture: (URL, PageFixture, [SourceSummary]) throws -> T
    ) throws -> T {
        let (store, url, page, sources) = try preparedStore()
        store.close()
        return try fixture(url, page, sources)
    }

    @Test func pageVersionSourcesReturnsEmptyForMissingVersion() throws {
        let store = try TestStoreFactory.inMemory()
        #expect(try store.pageVersionSources(versionID: PageVersionID(rawValue: "missing")).isEmpty)
    }

    @Test func pageVersionSourcesReturnsEmptyForLegacyVersion() throws {
        try withClosedStore { url, page, _ in
            let store = try GRDBWikiStore(databaseURL: url)
            let head = try #require(try store.pageHeadVersionID(pageID: page.id))
            #expect(try store.pageVersionSources(versionID: head).isEmpty)
        }
    }

    @Test func pageVersionSourcesReturnsTypedResults() throws {
        try withClosedStore { url, page, sources in
            let reopened = try GRDBWikiStore(databaseURL: url)
            let head = try #require(try reopened.pageHeadVersionID(pageID: page.id))
            reopened.close()
            try MetadataSQLiteFixtureSupport.execute(
                "INSERT INTO page_version_sources VALUES ('\(head.rawValue)', '\(sources[0].id.rawValue)', 'primary')",
                at: url
            )
            let result = try GRDBWikiStore(databaseURL: url).pageVersionSources(versionID: head)
            #expect(result == [.init(pageVersionID: head, sourceID: sources[0].id, role: .primary)])
        }
    }

    @Test func pageVersionSourcesOrdersByRoleThenDisplayNameThenID() throws {
        try withClosedStore { url, page, sources in
            let reopened = try GRDBWikiStore(databaseURL: url)
            let head = try #require(try reopened.pageHeadVersionID(pageID: page.id))
            reopened.close()
            try MetadataSQLiteFixtureSupport.execute("""
            INSERT INTO page_version_sources VALUES ('\(head.rawValue)', '\(sources[0].id.rawValue)', 'supporting');
            INSERT INTO page_version_sources VALUES ('\(head.rawValue)', '\(sources[1].id.rawValue)', 'primary');
            INSERT INTO page_version_sources VALUES ('\(head.rawValue)', '\(sources[2].id.rawValue)', 'supporting');
            INSERT INTO page_version_sources VALUES ('\(head.rawValue)', '\(sources[0].id.rawValue)', 'quoted');
            """, at: url)
            let values = try GRDBWikiStore(databaseURL: url).pageVersionSources(versionID: head)
            #expect(values.map(\.role) == [.primary, .supporting, .supporting, .quoted])
            #expect(values.map(\.sourceID) == [sources[1].id, sources[2].id, sources[0].id, sources[0].id])
        }
    }

    @Test func pageVersionSourcesThrowsTypedCorruptionForUnknownRole() throws {
        try withClosedStore { url, page, sources in
            let reopened = try GRDBWikiStore(databaseURL: url)
            let head = try #require(try reopened.pageHeadVersionID(pageID: page.id))
            reopened.close()
            try MetadataSQLiteFixtureSupport.execute("""
            PRAGMA ignore_check_constraints = ON;
            INSERT INTO page_version_sources VALUES ('\(head.rawValue)', '\(sources[0].id.rawValue)', 'untrusted');
            """, at: url)
            do {
                _ = try GRDBWikiStore(databaseURL: url).pageVersionSources(versionID: head)
                Issue.record("expected typed role corruption")
            } catch let error as MetadataStoreError {
                #expect(error == .unknownPageVersionSourceRole("untrusted"))
            }
        }
    }

    @Test func pageHeadSourcesReturnsEmptyForMissingPage() throws {
        let store = try TestStoreFactory.inMemory()
        #expect(try store.pageHeadSources(pageID: PageID(rawValue: "missing")).isEmpty)
    }

    @Test func pageHeadSourcesReturnsEmptyForLegacyHead() throws {
        try withClosedStore { url, page, _ in
            let store = try GRDBWikiStore(databaseURL: url)
            let values = try store.pageHeadSources(pageID: page.id)
            #expect(values.isEmpty)
        }
    }

    @Test func pageHeadSourcesResolvesCurrentHeadNotAlternative() throws {
        try withClosedStore { url, page, sources in
            let store = try GRDBWikiStore(databaseURL: url)
            let oldHead = try #require(try store.pageHeadVersionID(pageID: page.id))
            let newHead = try store.appendPageVersion(
                pageID: page.id, title: page.title, body: "new", expectedHeadVersionID: oldHead
            )
            store.close()
            try MetadataSQLiteFixtureSupport.execute("""
            INSERT INTO page_version_sources VALUES ('\(oldHead.rawValue)', '\(sources[0].id.rawValue)', 'primary');
            INSERT INTO page_version_sources VALUES ('\(newHead.rawValue)', '\(sources[1].id.rawValue)', 'quoted');
            """, at: url)
            let values = try GRDBWikiStore(databaseURL: url).pageHeadSources(pageID: page.id)
            #expect(values.map(\.sourceID) == [sources[1].id])
        }
    }

    @Test func pageHeadSourcesThrowsTypedCorruptionForUnknownRole() throws {
        try withClosedStore { url, page, sources in
            let reopened = try GRDBWikiStore(databaseURL: url)
            let head = try #require(try reopened.pageHeadVersionID(pageID: page.id))
            reopened.close()
            try MetadataSQLiteFixtureSupport.execute("""
            PRAGMA ignore_check_constraints = ON;
            INSERT INTO page_version_sources VALUES ('\(head.rawValue)', '\(sources[0].id.rawValue)', 'invalid');
            """, at: url)
            do {
                _ = try GRDBWikiStore(databaseURL: url).pageHeadSources(pageID: page.id)
                Issue.record("expected typed role corruption")
            } catch let error as MetadataStoreError {
                #expect(error == .unknownPageVersionSourceRole("invalid"))
            }
        }
    }

    @Test func sourceReferencingPageVersionsReturnsTypedOrderedIDs() throws {
        try withClosedStore { url, page, sources in
            let store = try GRDBWikiStore(databaseURL: url)
            let first = try #require(try store.pageHeadVersionID(pageID: page.id))
            let second = try store.appendPageVersion(
                pageID: page.id, title: page.title, body: "second", expectedHeadVersionID: first
            )
            store.close()
            try MetadataSQLiteFixtureSupport.execute("""
            INSERT INTO page_version_sources VALUES ('\(second.rawValue)', '\(sources[0].id.rawValue)', 'primary');
            INSERT INTO page_version_sources VALUES ('\(first.rawValue)', '\(sources[0].id.rawValue)', 'quoted');
            """, at: url)
            #expect(try GRDBWikiStore(databaseURL: url).sourceReferencingPageVersions(sourceID: sources[0].id) == [first, second].sorted())
        }
    }

    @Test func sourceReferencingPageVersionsReturnsEmptyForUnreferencedSource() throws {
        try withClosedStore { url, _, sources in
            let store = try GRDBWikiStore(databaseURL: url)
            let values = try store.sourceReferencingPageVersions(sourceID: sources[0].id)
            #expect(values.isEmpty)
        }
    }

    @Test func sourceReferencingPageVersionsReturnsEmptyForMissingSource() throws {
        let store = try TestStoreFactory.inMemory()
        #expect(try store.sourceReferencingPageVersions(sourceID: SourceID(rawValue: "missing")).isEmpty)
    }
}
