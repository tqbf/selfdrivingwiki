import Foundation
import Testing
@testable import WikiFSCore

/// Phase 4b integration tests: store-level behavior for byteless external-embed
/// media sources — changeToken advance (AC.6), dedup (AC.7), the batched
/// `embedDescriptors()` query, `addURL` routing (AC.1/AC.2), and refreshability
/// (AC.8). No network — routing uses pure recognizers + an exploding/HTML fetcher.
@MainActor
struct BytelessEmbedIntegrationTests {

    private func tempStore() throws -> SQLiteWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-embed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SQLiteWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    /// Fails if reached — a recognized media URL must NOT hit the HTML fetcher.
    struct ExplodingFetcher: URLFetchService.URLResourceFetcher {
        func fetch(_ url: URL) async throws -> URLFetchService.FetchResponse {
            Issue.record("HTML fetcher must not run for a recognized media URL")
            throw URLFetchService.FetchError.empty
        }
    }

    struct HTMLFetcher: URLFetchService.URLResourceFetcher {
        func fetch(_ url: URL) async throws -> URLFetchService.FetchResponse {
            URLFetchService.FetchResponse(
                data: Data("<title>Hi</title><p>x</p>".utf8),
                contentType: "text/html", finalURL: url)
        }
    }

    // MARK: - AC.6: changeToken advances on byteless media add

    @Test func changeTokenAdvancesWhenBytelessMediaAdded() throws {
        let store = try tempStore()
        let before = try store.changeToken()
        _ = try store.addBytelessSource(
            filename: "youtube-dQw4w9WgXcQ",
            mimeType: "video/youtube",
            provenance: SourceProvenance(
                agentName: "youtube", activityKind: "fetch",
                plan: "https://youtu.be/dQw4w9WgXcQ",
                externalRef: "https://youtu.be/dQw4w9WgXcQ",
                externalIdentity: "dQw4w9WgXcQ"),
            role: .primary)
        let after = try store.changeToken()
        #expect(before != after)
    }

    // MARK: - AC.7: duplicate external_identity rejected

    @Test func duplicateExternalIdentityRejected() throws {
        let store = try tempStore()
        _ = try store.addBytelessSource(
            filename: "spotify-track-abc",
            mimeType: "audio/spotify",
            provenance: SourceProvenance(
                agentName: "spotify", activityKind: "fetch",
                plan: "https://open.spotify.com/track/abc",
                externalRef: "https://open.spotify.com/track/abc",
                externalIdentity: "track/abc"),
            role: .primary)
        // Same external_identity → duplicate (byteless partial-index dedup).
        #expect(throws: WikiStoreError.self) {
            _ = try store.addBytelessSource(
                filename: "spotify-track-abc-2",
                mimeType: "audio/spotify",
                provenance: SourceProvenance(
                    agentName: "spotify", activityKind: "fetch",
                    plan: "https://open.spotify.com/track/abc",
                    externalRef: "https://open.spotify.com/track/abc",
                    externalIdentity: "track/abc"),
                role: .primary)
        }
        #expect(try store.listSources().count == 1)
    }

    // MARK: - embedDescriptors() query

    @Test func embedDescriptorsReturnsBytelessMediaOnly() throws {
        let store = try tempStore()
        // A byteful source (has bytes) — should NOT appear.
        _ = try store.addSource(
            filename: "pic.png", data: Data([0x89, 0x50, 0x4E, 0x47]),
            zoteroItemKey: nil, zoteroItemTitle: nil, mimeType: "image/png",
            provenance: nil)
        // A byteless YouTube source — SHOULD appear with the right fields.
        let yt = try store.addBytelessSource(
            filename: "youtube-dQw4w9WgXcQ",
            mimeType: "video/youtube",
            provenance: SourceProvenance(
                agentName: "youtube", activityKind: "fetch",
                plan: "https://youtu.be/dQw4w9WgXcQ",
                externalRef: "https://youtu.be/dQw4w9WgXcQ",
                externalIdentity: "dQw4w9WgXcQ"),
            role: .primary)

        let descriptors = try store.embedDescriptors()
        #expect(descriptors.count == 1)  // byteful excluded
        let d = try #require(descriptors[yt.id])
        #expect(d.mimeType == "video/youtube")
        #expect(d.externalIdentity == "dQw4w9WgXcQ")
        #expect(d.agentName == "youtube")
        #expect(d.planURL == "https://youtu.be/dQw4w9WgXcQ")
        // The descriptor yields a YouTube iframe target.
        let target = try #require(ExternalEmbed.target(for: d))
        #expect(target.kind == .iframe)
        // Embed URL carries the reader origin (issue #206: no origin ⇒ error 153).
        #expect(target.url.hasPrefix("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?"))
        #expect(target.url.contains("origin="))
    }

    // MARK: - AC.1: provider URL routing (no network)

    @Test func youtubeURLRoutesToBytelessVideoEmbed() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let outcome = try await model.addURL(
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ", fetcher: ExplodingFetcher())
        #expect(outcome.kind == .videoEmbed)
        let source = try #require(try store.listSources().first)
        #expect(source.byteSize == 0)  // byteless
        let origin = try #require(try store.sourceOrigin(sourceID: source.id))
        #expect(origin.agentName == "youtube")
        #expect(origin.externalIdentity == "dQw4w9WgXcQ")
    }

    @Test func spotifyURLRoutesToBytelessAudioEmbed() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let outcome = try await model.addURL(
            "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC", fetcher: ExplodingFetcher())
        #expect(outcome.kind == .audioEmbed)
        let source = try #require(try store.listSources().first)
        let origin = try #require(try store.sourceOrigin(sourceID: source.id))
        #expect(origin.agentName == "spotify")
        #expect(origin.externalIdentity == "track/4uLU6hMCjMI75M1A2tKUQC")
    }

    // MARK: - AC.2: direct-remote media routing (no network)

    @Test func remoteMp3RoutesToBytelessRemoteMedia() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let outcome = try await model.addURL(
            "https://radio.example.com/live.mp3", fetcher: ExplodingFetcher())
        #expect(outcome.kind == .remoteMedia)
        let source = try #require(try store.listSources().first)
        #expect(source.byteSize == 0)
        let origin = try #require(try store.sourceOrigin(sourceID: source.id))
        #expect(origin.agentName == "remote-media")
        #expect(origin.externalIdentity == "https://radio.example.com/live.mp3")
    }

    @Test func plainHTMLURLStillUsesWebsiteFetcher() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        // A non-media URL must NOT route to byteless media — it hits the fetcher.
        let outcome = try await model.addURL(
            "https://example.com/article", fetcher: HTMLFetcher())
        #expect(outcome.kind == .htmlConverted)
    }

    // MARK: - AC.8: new providers are not refreshable

    @Test func bytelessMediaProvidersAreNotRefreshable() async throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        let service = SourceRefreshService(fetcher: HTMLFetcher())
        let agents = ["youtube", "vimeo", "spotify", "soundcloud", "remote-media"]
        for (i, agent) in agents.enumerated() {
            _ = try store.addBytelessSource(
                filename: "media-\(i)",
                mimeType: agent.contains("video") || agent == "vimeo" ? "video/\(agent)" : "audio/\(agent)",
                provenance: SourceProvenance(
                    agentName: agent, activityKind: "fetch",
                    plan: "https://example.com/\(agent)",
                    externalRef: nil, externalIdentity: "id-\(i)"),
                role: .primary)
        }
        for source in try store.listSources() {
            let origin = try #require(try store.sourceOrigin(sourceID: source.id))
            #expect(origin.agentName != "website")  // sanity
            await #expect(throws: SourceRefreshService.RefreshError.self) {
                _ = try await service.materialize(origin: origin)
            }
        }
        _ = model  // suppress unused warning
    }
}
