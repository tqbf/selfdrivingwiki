import Foundation
import Testing
@testable import WikiCtlCore
@testable import WikiFSCore

/// Compatibility writers must preserve their public inputs while persisting
/// through the typed derived-markdown seam.
struct ExtractionCompatibilityWriterTests {
    private func source(_ store: GRDBWikiStore) throws -> SourceSummary {
        try store.addSource(filename: "compatibility.pdf", data: Data("pdf".utf8))
    }

    @Test func appendProcessedMarkdownDerivedCompatibilityRoutesThroughAppendDerivedMarkdown() throws {
        let store = try TestStoreFactory.inMemory()
        let summary = try source(store)
        let version = try store.appendProcessedMarkdown(
            sourceID: summary.id, content: "derived", origin: .extraction,
            note: nil, technique: ExtractionTool.pdf2md.rawValue)
        let provenance = try #require(try store.extractionProvenance(markdownVersionID: version.id))
        #expect(provenance.origin == .extraction)
        #expect(provenance.producer == .tool(.pdf2md))
    }

    @Test func legacyTranscriptWriterRoutesThroughAppendDerivedMarkdown() throws {
        let store = try TestStoreFactory.inMemory()
        let summary = try source(store)
        let version = try store.appendProcessedMarkdown(
            sourceID: summary.id, content: "transcript", origin: .transcript,
            note: nil, technique: ExtractionTool.youtubeCaptions.rawValue)
        let provenance = try #require(try store.extractionProvenance(markdownVersionID: version.id))
        #expect(provenance.origin == .transcript)
        #expect(provenance.producer == .tool(.youtubeCaptions))
    }

    @Test func wikictlTranscriptCompatibilityRoutesThroughAppendDerivedMarkdown() throws {
        let store = try TestStoreFactory.inMemory()
        let summary = try source(store)
        try SourceCommand.persistRefreshMaterial(
            .derivedMarkdown(content: "cli transcript"), sourceID: summary.id, in: store)
        let version = try #require(try store.processedMarkdownHead(sourceID: summary.id))
        let provenance = try #require(try store.extractionProvenance(markdownVersionID: version.id))
        #expect(provenance.origin == .transcript)
        #expect(provenance.producer == .tool(.transcript))
    }

    @Test func sourceCommandAddAndRefreshPreserveDetectionPolicy() async throws {
        struct PDFAsTextFetcher: URLFetchService.URLResourceFetcher {
            func fetch(_ url: URL) async throws -> URLFetchService.FetchResponse {
                .init(
                    data: Data("%PDF-1.7".utf8),
                    contentType: "text/plain",
                    finalURL: URL(string: "https://example.com/report.txt")!)
            }
        }

        let store = try TestStoreFactory.inMemory()
        _ = try await SourceCommand.runAddURL(
            "https://example.com/report.txt",
            allowDuplicateURL: false,
            in: store,
            fetcher: PDFAsTextFetcher())
        let added = try #require(try store.listSources().first)
        #expect(added.mimeType == MimeType.pdf)

        try SourceCommand.persistRefreshMaterial(
            .contentVersion(
                data: Data("%PDF-1.7 refreshed".utf8),
                detectionHints: .init(
                    declaredMIME: .init("text/plain", origin: .httpResponse),
                    filenameExtension: "txt"),
                provenance: .init(
                    agentName: "website", activityKind: "fetch",
                    plan: "https://example.com/report.txt")),
            sourceID: added.id,
            in: store)
        let refreshed = try store.getSource(id: added.id)
        let activeVersion = try #require(try store.activeContentVersion(sourceID: added.id))
        #expect(refreshed.mimeType == MimeType.pdf)
        #expect(activeVersion.mimeType == MimeType.pdf)
    }

    @Test func GRDBAddAppendAndSnapshotImageRedetectAtFinalBoundary() throws {
        let store = try TestStoreFactory.inMemory()
        let pdfBytes = Data("%PDF-1.7".utf8)
        let hints = ContentTypeDetectionHints(
            declaredMIME: .init("text/plain", origin: .httpResponse),
            filenameExtension: "txt")

        let typed = try store.addSource(
            filename: "typed.txt", data: pdfBytes,
            detectionHints: hints, ingestMetadata: nil, provenance: nil,
            role: .primary, originalPath: nil, activityID: nil,
            resolvedDisplayName: nil)
        #expect(typed.mimeType == MimeType.pdf)
        #expect(try store.activeContentVersion(sourceID: typed.id)?.mimeType == MimeType.pdf)

        let appended = try store.appendContentVersion(
            sourceID: typed.id,
            data: Data("%PDF-1.7 appended".utf8),
            detectionHints: hints,
            provenance: nil)
        #expect(appended.mimeType == MimeType.pdf)
        #expect(try store.getSource(id: typed.id).mimeType == MimeType.pdf)

        let activityID = try store.ensureFetchActivity(provenance: .init(
            agentName: "website", activityKind: "fetch",
            plan: "https://example.com/page"))
        let snapshot = try store.addSnapshotImage(
            filename: "snapshot.txt", data: pdfBytes,
            detectionHints: hints,
            originalPath: "snapshot.txt",
            sourceURL: URL(string: "https://example.com/snapshot.txt")!,
            activityID: activityID,
            role: .media)
        #expect(snapshot.mimeType == MimeType.pdf)
        #expect(try store.activeContentVersion(sourceID: snapshot.id)?.mimeType == MimeType.pdf)
    }

    @Test func wikictlContentRefreshPreservesDeclaredMIMEHints() throws {
        let store = try TestStoreFactory.inMemory()
        let summary = try source(store)
        let provenance = SourceProvenance(
            agentName: "website",
            activityKind: "fetch",
            plan: "https://example.com/download")
        let hints = ContentTypeDetectionHints(
            declaredMIME: DeclaredMIME(
                "application/x-refresh-test; version=1",
                origin: .httpResponse))

        try SourceCommand.persistRefreshMaterial(
            .contentVersion(
                data: Data([0x00, 0x01, 0x02]),
                detectionHints: hints,
                provenance: provenance),
            sourceID: summary.id,
            in: store)

        let refreshed = try #require(try store.listSources().first { $0.id == summary.id })
        let activeVersion = try #require(try store.contentVersionHistory(sourceID: summary.id).first)
        #expect(refreshed.mimeType == "application/x-refresh-test")
        #expect(activeVersion.mimeType == "application/x-refresh-test")
    }
}
