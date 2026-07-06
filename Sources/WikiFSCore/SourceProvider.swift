import Foundation
import UniformTypeIdentifiers

/// Phase 3a — the provider protocol that owns *materialization* (bytes +
/// filename + mime + PROV provenance) for every ingest entry point. The four
/// ingest paths (drag-drop, URL, Zotero, Markdown-folder) each build a provider,
/// `materialize()` into a `MaterializedSource`, and flow through the single
/// `WikiStoreModel.storeMaterialized(_:)` → `store.addSource(provenance:)` seam.
///
/// A provider materializes bytes/provenance **only** — it never writes the store
/// (single-writer discipline: the `@MainActor` model owns the write, exactly as
/// today). Network/file I/O inside `materialize()` runs off the main actor.
///
/// See `plans/graph-model-and-versioning.md` §11 (provider protocol).

// MARK: - Provenance descriptor

/// The PROV-DM descriptor threaded into `addSource`/`appendContentVersion`. When
/// present, the store swaps the synthetic `legacy-import` agent/activity stub for
/// a **real** provider agent + a `fetch`/`import` activity carrying `plan`/
/// `external_ref`, and writes `external_identity` on the v1 version.
///
/// Every column this populates already exists and was previously stubbed NULL
/// (`activities.plan`/`external_ref`, `agents.version`/`external_ref`,
/// `source_versions.external_identity`) — Phase 3a is a code-only change.
public struct SourceProvenance: Sendable, Equatable {
    /// The `wasAssociatedWith` target agent name — idempotent via `ensureAgent`
    /// (dedups on `(name, kind)`), e.g. `"local-file"`, `"website"`, `"zotero"`.
    public let agentName: String
    /// `agents.kind` (PROV agent kind). Defaults to `"software"`.
    public let agentKind: String
    /// `agents.version` — a tool/model version, if known. `nil` for local providers.
    public let agentVersion: String?
    /// `activities.kind` — `"fetch"` for URL/website, `"import"` for local/
    /// Zotero/folder.
    public let activityKind: String
    /// `activities.plan` — the recipe. For website = the request URL string.
    public let plan: String?
    /// `activities.external_ref` — provider-scoped stable identity for this
    /// *activity* (e.g. the final resolved URL). Per-ingest, NOT per-agent.
    public let externalRef: String?
    /// `source_versions.external_identity` — the canonical external id (resolved
    /// URL for website; Zotero item key for Zotero; `nil` for local).
    public let externalIdentity: String?

    public init(
        agentName: String,
        agentKind: String = "software",
        agentVersion: String? = nil,
        activityKind: String,
        plan: String? = nil,
        externalRef: String? = nil,
        externalIdentity: String? = nil
    ) {
        self.agentName = agentName
        self.agentKind = agentKind
        self.agentVersion = agentVersion
        self.activityKind = activityKind
        self.plan = plan
        self.externalRef = externalRef
        self.externalIdentity = externalIdentity
    }
}

// MARK: - Materialized source

/// A provider's output: the bytes to store + the provenance to record. Carries
/// **no store handle** — the store owns the write (`storeMaterialized` →
/// `addSource`). Also carries the retained Zotero legacy columns so the
/// `ZoteroProvider` can populate both the PROV layer and the legacy columns in
/// one call (§4.2: zotero columns are "legacy provenance, retained").
public struct MaterializedSource: Sendable {
    public let filename: String
    public let data: Data
    public let mimeType: String?
    public let zoteroItemKey: String?
    public let zoteroItemTitle: String?
    public let provenance: SourceProvenance?

    public init(
        filename: String,
        data: Data,
        mimeType: String? = nil,
        zoteroItemKey: String? = nil,
        zoteroItemTitle: String? = nil,
        provenance: SourceProvenance? = nil
    ) {
        self.filename = filename
        self.data = data
        self.mimeType = mimeType
        self.zoteroItemKey = zoteroItemKey
        self.zoteroItemTitle = zoteroItemTitle
        self.provenance = provenance
    }
}

// MARK: - Provider protocol

/// Materializes bytes + provenance for one ingest. Each provider turns its input
/// into a `MaterializedSource`; the caller then stores it through the shared
/// `storeMaterialized(_:)` seam. A provider NEVER writes the store.
public protocol SourceProvider: Sendable {
    /// The agent name this provider records (`"local-file"`, `"website"`, …).
    var agentName: String { get }
    /// Produce the bytes + provenance. Network/file I/O here may run off-main.
    func materialize() async throws -> MaterializedSource
}

// MARK: - Read-side origin projection

/// The read-side projection of a source's origin (the inverse of
/// `SourceProvenance`): joined from the active content version → its activity →
/// the associated agent. `plan`/`externalRef` come from the **activity** row
/// (per-ingest, so two website sources with different URLs each return their
/// own); `agentName` from the **agent** row.
public struct SourceOrigin: Sendable, Equatable {
    public let agentName: String
    public let activityKind: String
    public let plan: String?
    public let externalRef: String?
    public let externalIdentity: String?
    public let fetchedAt: Date

    public init(
        agentName: String,
        activityKind: String,
        plan: String?,
        externalRef: String?,
        externalIdentity: String?,
        fetchedAt: Date
    ) {
        self.agentName = agentName
        self.activityKind = activityKind
        self.plan = plan
        self.externalRef = externalRef
        self.externalIdentity = externalIdentity
        self.fetchedAt = fetchedAt
    }

    /// A short human label for the origin, for UI/CLI display.
    public var displayLabel: String {
        switch agentName {
        case "website": return "Website"
        case "zotero": return "Zotero"
        case "markdown-folder": return "Markdown folder"
        case "local-file": return "File"
        case "legacy-import": return "Imported"
        case "apple-podcast": return "Apple Podcast"
        default: return agentName.capitalized
        }
    }
}

// MARK: - LocalFileProvider

/// Materializes a drag-dropped / picked file: reads the bytes (off-main), sniffs
/// the MIME type, and records `agentName = "local-file"` with an `import`
/// activity (no external identity).
public struct LocalFileProvider: SourceProvider {
    public let agentName = "local-file"
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func materialize() async throws -> MaterializedSource {
        let url = fileURL
        let data = try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: url)
        }.value
        // Preserve the pre-Phase-3 addFiles dispatch: derive mime from the ext,
        // run the bytes through URLFetchService.plan(for:) so content-sniffing +
        // extension inference stay identical, and pass the UTType mime explicitly.
        let ext = (url.lastPathComponent as NSString).pathExtension.lowercased()
        let mimeType = UTType(filenameExtension: ext)?.preferredMIMEType
        let response = URLFetchService.FetchResponse(data: data, contentType: mimeType, finalURL: url)
        let plan = URLFetchService.plan(for: response)
        return MaterializedSource(
            filename: plan.filename,
            data: plan.data,
            mimeType: mimeType,
            provenance: SourceProvenance(
                agentName: agentName,
                activityKind: "import"
            )
        )
    }
}

// MARK: - WebsiteProvider

/// Materializes a fetched URL: normalizes → fetches → dispatches by content type
/// (HTML→Markdown / PDF / text / binary), reusing `URLFetchService.plan(for:)`
/// unchanged. Records `agentName = "website"`, `activityKind = "fetch"`,
/// `plan` = the request URL, and `externalIdentity`/`externalRef` = the resolved
/// final URL.
///
/// `materializeWithPlan()` returns the `MaterializedSource` alongside the
/// computed dispatch `StorePlan`, so `addURL` can build its `FetchOutcome`
/// (kind/size) without a second fetch. A pure struct — `materialize()` is the
/// protocol-conformant projection that discards the plan.
public struct WebsiteProvider: SourceProvider {
    public let agentName = "website"
    public let rawInput: String
    public let fetcher: any URLFetchService.URLResourceFetcher

    public init(rawInput: String, fetcher: any URLFetchService.URLResourceFetcher) {
        self.rawInput = rawInput
        self.fetcher = fetcher
    }

    public func materialize() async throws -> MaterializedSource {
        try await materializeWithPlan().source
    }

    /// The full materialization, returning the dispatch plan alongside the
    /// `MaterializedSource` (so the caller can report kind/size).
    public func materializeWithPlan() async throws -> (source: MaterializedSource, plan: URLFetchService.StorePlan) {
        guard let url = URLFetchService.normalizeURL(rawInput) else {
            throw URLFetchService.FetchError.invalidURL(
                rawInput.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let response = try await fetcher.fetch(url)
        guard !response.data.isEmpty else { throw URLFetchService.FetchError.empty }
        let plan = URLFetchService.plan(for: response)
        let finalURLString = response.finalURL.absoluteString
        let source = MaterializedSource(
            filename: plan.filename,
            data: plan.data,
            // Pass nil so the store sniffs (the dispatch plan already converted
            // HTML→Markdown bytes; mime is for the stored artifact, not the
            // original response). Mirrors the pre-Phase-3 addURL behavior.
            mimeType: nil,
            provenance: SourceProvenance(
                agentName: agentName,
                activityKind: "fetch",
                plan: url.absoluteString,
                externalRef: finalURLString,
                externalIdentity: finalURLString
            )
        )
        return (source, plan)
    }
}

// MARK: - ApplePodcastProvider

#if PODCAST_TRANSCRIPTS
/// Materializes an Apple Podcasts episode transcript: the fetch (token signing →
/// AMP metadata → TTML download → parse → markdown) runs off-main, producing a
/// `MaterializedSource` with `agentName = "apple-podcast"`, `activityKind = "fetch"`,
/// `plan`/`externalRef` = the episode's `podcasts.apple.com` URL, and
/// `externalIdentity` = the numeric episode ID (`i=` value). This is the first real
/// consumer of the `SourceProvider` protocol; `addURL` routes recognized episode
/// URLs here instead of `WebsiteProvider`.
///
/// Holds the page URL separately from `EpisodeRef` so the provenance records the
/// canonical `podcasts.apple.com` link (not the episode ID alone) — the ID is what
/// the AMP endpoint wants, but the URL is what the user pasted and what the Origin
/// row should surface.
public struct ApplePodcastProvider: SourceProvider {
    public let agentName = "apple-podcast"
    public let episode: PodcastEpisodeURL.EpisodeRef
    public let pageURL: URL
    public let fetcher: any PodcastTranscriptFetching

    public init(
        episode: PodcastEpisodeURL.EpisodeRef,
        pageURL: URL,
        fetcher: any PodcastTranscriptFetching
    ) {
        self.episode = episode
        self.pageURL = pageURL
        self.fetcher = fetcher
    }

    public func materialize() async throws -> MaterializedSource {
        let episode = self.episode
        let fetcher = self.fetcher
        // The transcript fetch (helper subprocess + two HTTP round-trips) is
        // off-main; the provider never touches the store.
        let transcript = try await Task.detached(priority: .userInitiated) {
            try await fetcher.transcript(for: episode)
        }.value
        let urlString = pageURL.absoluteString
        return MaterializedSource(
            filename: transcript.filename,
            data: Data(transcript.markdown.utf8),
            mimeType: "text/markdown",
            provenance: SourceProvenance(
                agentName: agentName,
                activityKind: "fetch",
                plan: urlString,
                externalRef: urlString,
                externalIdentity: episode.id
            )
        )
    }
}
#endif

// MARK: - ZoteroProvider

/// Materializes a Zotero attachment: resolves its local file (off-main read),
/// recording `agentName = "zotero"`, `activityKind = "import"`,
/// `externalIdentity` = the parent item key. Also populates the retained legacy
/// `zoteroItemKey`/`zoteroItemTitle` columns (§4.2).
public struct ZoteroProvider: SourceProvider {
    public let agentName = "zotero"
    public let attachment: ZoteroAttachment
    public let parentItem: ZoteroItem
    public let zoteroDir: URL

    public init(attachment: ZoteroAttachment, parentItem: ZoteroItem, zoteroDir: URL) {
        self.attachment = attachment
        self.parentItem = parentItem
        self.zoteroDir = zoteroDir
    }

    public func materialize() async throws -> MaterializedSource {
        switch ZoteroLocalStorage.resolve(attachment, zoteroDir: zoteroDir) {
        case .local(let path):
            let data = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: path)
            }.value
            return MaterializedSource(
                filename: path.lastPathComponent,
                data: data,
                mimeType: nil,
                zoteroItemKey: parentItem.key,
                zoteroItemTitle: parentItem.title,
                provenance: SourceProvenance(
                    agentName: agentName,
                    activityKind: "import",
                    externalIdentity: parentItem.key
                )
            )
        case .unavailable(let reason):
            throw ZoteroFetchError.unavailable(reason)
        }
    }
}

// MARK: - MarkdownFolderProvider

/// Materializes one `.md`/`.markdown` file from a folder import: the
/// `MarkdownFolderReader.walk` does the batch off-main discovery + read, and this
/// provider adapts each walked file into a `MaterializedSource` with
/// `agentName = "markdown-folder"` (so "everything from a folder import" is a
/// join). Takes the pre-read `(filename, data)` from the walk to avoid a
/// double-read.
public struct MarkdownFolderProvider: SourceProvider {
    public let agentName = "markdown-folder"
    public let filename: String
    public let data: Data
    public let mimeType: String?

    public init(filename: String, data: Data, mimeType: String? = nil) {
        self.filename = filename
        self.data = data
        self.mimeType = mimeType
    }

    public func materialize() async throws -> MaterializedSource {
        MaterializedSource(
            filename: filename,
            data: data,
            mimeType: mimeType,
            provenance: SourceProvenance(
                agentName: agentName,
                activityKind: "import"
            )
        )
    }
}
