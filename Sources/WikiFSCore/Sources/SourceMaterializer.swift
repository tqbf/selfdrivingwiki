import Foundation
import UniformTypeIdentifiers

/// Phase 3a — the materializer protocol that owns *materialization* (bytes +
/// filename + mime + PROV provenance) for every ingest entry point. The four
/// ingest paths (drag-drop, URL, Zotero, Markdown-folder) each build a materializer,
/// `materialize()` into a `MaterializedSource`, and flow through the single
/// `WikiStoreModel.storeMaterialized(_:)` → `store.addSource(provenance:)` seam.
///
/// A materializer produces bytes/provenance **only** — it never writes the store
/// (single-writer discipline: the `@MainActor` model owns the write, exactly as
/// today). Network/file I/O inside `materialize()` runs off the main actor.
///
/// See `plans/graph-model-and-versioning.md` §11 (materializer protocol).

// MARK: - Provenance descriptor

/// The PROV-DM descriptor threaded into `addSource`/`appendContentVersion`. When
/// present, the store swaps the synthetic `legacy-import` agent/activity stub for
/// a **real** materializer agent + a `fetch`/`import` activity carrying `plan`/
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
    /// `agents.version` — a tool/model version, if known. `nil` for local materializers.
    public let agentVersion: String?
    /// `activities.kind` — `"fetch"` for URL/website, `"import"` for local/
    /// Zotero/folder.
    public let activityKind: String
    /// `activities.plan` — the recipe. For website = the request URL string.
    public let plan: String?
    /// `activities.external_ref` — materializer-scoped stable identity for this
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

/// A materializer's output: the bytes to store + the provenance to record. Carries
/// **no store handle** — the store owns the write (`storeMaterialized` →
/// `addSource`). Also carries the retained Zotero legacy columns so the
/// `ZoteroMaterializer` can populate both the PROV layer and the legacy columns in
/// one call (§4.2: zotero columns are "legacy provenance, retained").
///
/// `extractedMarkdown` (issue #599): non-nil when the source preserves its
/// original bytes AND carries a derived markdown version alongside — mirrors the
/// PDF → pdf2md model. The store path writes it as a `SourceMarkdownOrigin.extraction`
/// processed-markdown version after the source row lands.
public struct MaterializedSource: Sendable {
    public let filename: String
    public let data: Data
    public let mimeType: String?
    public let zoteroItemKey: String?
    public let zoteroItemTitle: String?
    public let provenance: SourceProvenance?
    public let extractedMarkdown: String?
    /// Which extractor produced `extractedMarkdown` (`"defuddle"` or
    /// `"html-to-markdown"`). Stamped on the `source_markdown_versions.technique`
    /// column so the provenance/alternatives UI surfaces the producer. `nil` for
    /// non-HTML sources (no extracted-markdown sidecar) — defaults to
    /// `"html-to-markdown"` in the store path.
    public let extractionTechnique: String?

    public init(
        filename: String,
        data: Data,
        mimeType: String? = nil,
        zoteroItemKey: String? = nil,
        zoteroItemTitle: String? = nil,
        provenance: SourceProvenance? = nil,
        extractedMarkdown: String? = nil,
        extractionTechnique: String? = nil
    ) {
        self.filename = filename
        self.data = data
        self.mimeType = mimeType
        self.zoteroItemKey = zoteroItemKey
        self.zoteroItemTitle = zoteroItemTitle
        self.provenance = provenance
        self.extractedMarkdown = extractedMarkdown
        self.extractionTechnique = extractionTechnique
    }
}

// MARK: - Provider protocol

/// Materializes bytes + provenance for one ingest. Each materializer turns its input
/// into a `MaterializedSource`; the caller then stores it through the shared
/// `storeMaterialized(_:)` seam. A materializer NEVER writes the store.
public protocol SourceMaterializer: Sendable {
    /// The agent name this materializer records (`"local-file"`, `"website"`, …).
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
    /// The source-version row id (the ULID of the `source_versions` row).
    public let versionID: String
    public let agentName: String
    /// The agent's structured kind (`chat` / `agent` / `human` / `model` /
    /// `software`). Degrades to `"software"` for the legacy-import shared
    /// agent so the UI can label pre-v39 rows distinctly.
    public let agentKind: String
    public let activityKind: String
    public let plan: String?
    public let externalRef: String?
    public let externalIdentity: String?
    /// A human-readable run name resolved from the provenance payload (#745).
    /// For `chat:<id>` agents this is the chat's display title. `nil` for
    /// other agent kinds or when the chat has been deleted.
    public let runTitle: String?
    public let fetchedAt: Date

    public init(
        versionID: String,
        agentName: String,
        agentKind: String,
        activityKind: String,
        plan: String?,
        externalRef: String?,
        externalIdentity: String?,
        runTitle: String? = nil,
        fetchedAt: Date
    ) {
        self.versionID = versionID
        self.agentName = agentName
        self.agentKind = agentKind
        self.activityKind = activityKind
        self.plan = plan
        self.externalRef = externalRef
        self.externalIdentity = externalIdentity
        self.runTitle = runTitle
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

// MARK: - LocalFileMaterializer

/// Materializes a drag-dropped / picked file: reads the bytes (off-main), sniffs
/// the MIME type, and records `agentName = "local-file"` with an `import`
/// activity (no external identity).
public struct LocalFileMaterializer: SourceMaterializer {
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
        // Derive mime from the ext, then route through format dispatch (same
        // pipeline as website/Zotero sources — content-sniffing + extension
        // inference). Pass the UTType mime explicitly.
        let ext = (url.lastPathComponent as NSString).pathExtension.lowercased()
        let mimeType = UTType(filenameExtension: ext)?.preferredMIMEType
        let (stem, extHint) = URLFetchService.nameHint(for: url)
        let plan = FormatMaterializer.dispatch(
            data: data, contentType: mimeType,
            stem: stem, extensionHint: extHint)
        return MaterializedSource(
            filename: plan.filename,
            data: plan.data,
            mimeType: mimeType,
            provenance: SourceProvenance(
                agentName: agentName,
                activityKind: "import",
                plan: fileURL.path,
                externalRef: fileURL.path
            ),
            extractedMarkdown: plan.extractedMarkdown)
    }
}

// MARK: - WebsiteMaterializer

/// Materializes a fetched URL: normalizes → fetches → dispatches by content type
/// (HTML→Markdown / PDF / text / binary) via `FormatMaterializer.dispatch`
/// (through `URLFetchService.nameHint(for:)`). Records `agentName = "website"`,
/// `activityKind = "fetch"`, `plan` = the request URL, and
/// `externalIdentity`/`externalRef` = the resolved final URL.
///
/// `materializeWithPlan()` returns the `MaterializedSource` alongside the
/// computed dispatch `FormatPlan`, so `addURL` can build its `FetchOutcome`
/// (kind/size) without a second fetch. A pure struct — `materialize()` is the
/// protocol-conformant projection that discards the plan.
public struct WebsiteMaterializer: SourceMaterializer {
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
    public func materializeWithPlan() async throws -> (source: MaterializedSource, plan: FormatPlan) {
        guard let url = URLFetchService.normalizeURL(rawInput) else {
            throw URLFetchService.FetchError.invalidURL(
                rawInput.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let response = try await fetcher.fetch(url)
        guard !response.data.isEmpty else { throw URLFetchService.FetchError.empty }
        let (stem, extHint) = URLFetchService.nameHint(for: response.finalURL)
        let plan = FormatMaterializer.dispatch(
            data: response.data, contentType: response.contentType,
            stem: stem, extensionHint: extHint)
        let finalURLString = response.finalURL.absoluteString
        let source = MaterializedSource(
            filename: plan.filename,
            data: plan.data,
            // Pass nil so the store sniffs (the dispatch plan already preserved
            // the original HTML bytes; mime is for the stored artifact, not the
            // original response). Mirrors the pre-Phase-3 addURL behavior.
            mimeType: nil,
            provenance: SourceProvenance(
                agentName: agentName,
                activityKind: "fetch",
                plan: url.absoluteString,
                externalRef: finalURLString,
                externalIdentity: finalURLString
            ),
            extractedMarkdown: plan.extractedMarkdown)
        return (source, plan)
    }

    /// Phase 4 — materialize a fetched URL as a **website snapshot** (HTML pages
    /// only): the page's markdown (with image srcs rewritten to relative sibling
    /// paths) plus its downloaded image bytes. Non-HTML responses (PDF / text /
    /// binary) return a snapshot with zero images — the caller routes those to
    /// the single-source store path.
    ///
    /// One shared `SourceProvenance` (agent `"website"`, kind `"fetch"`, plan =
    /// request URL, external_ref = final URL) covers the whole snapshot so the
    /// store can write all sources under one activity for sibling resolution.
    public func materializeSnapshot() async throws -> WebsiteSnapshot {
        guard let url = URLFetchService.normalizeURL(rawInput) else {
            throw URLFetchService.FetchError.invalidURL(
                rawInput.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let response = try await fetcher.fetch(url)
        guard !response.data.isEmpty else { throw URLFetchService.FetchError.empty }

        let (stem, extHint) = URLFetchService.nameHint(for: response.finalURL)
        let plan = FormatMaterializer.dispatch(
            data: response.data, contentType: response.contentType,
            stem: stem, extensionHint: extHint)
        let finalURLString = response.finalURL.absoluteString
        let provenance = SourceProvenance(
            agentName: agentName,
            activityKind: "fetch",
            plan: url.absoluteString,
            externalRef: finalURLString,
            externalIdentity: finalURLString)

        if plan.format == .html {
            // HTML: full snapshot — extract + download images, rewrite srcs.
            // The snapshot's page source preserves the ORIGINAL HTML bytes; the
            // snapshot markdown (with image srcs rewritten to stored siblings)
            // rides as the extracted-markdown sidecar (issue #599 — mirrors the
            // non-snapshot HTML path's normalized two-layer model).
            let html = URLFetchService.decodeText(response.data)
            return try await WebsiteSnapshotExtractor.snapshot(
                html: html,
                finalURL: response.finalURL,
                fetcher: fetcher,
                filename: plan.filename,
                provenance: provenance,
                plan: plan)
        }

        // Non-HTML: single source, no images.
        let source = MaterializedSource(
            filename: plan.filename, data: plan.data, mimeType: nil,
            provenance: provenance)
        return WebsiteSnapshot(page: source, images: [], plan: plan)
    }
}

// MARK: - Website snapshot (Phase 4)

/// One downloaded image sibling in a website snapshot. The image's bytes are
/// stored as a `.media` source sharing the page's fetch activity, keyed by its
/// relative `original_path` so the render resolver can rewrite the page's image
/// references to the stored blob.
public struct SnapshotImage: Sendable, Equatable {
    /// The disambiguated relative path used in the page's stored markdown and
    /// written to `source_versions.original_path` (e.g. `images/foo.png`).
    public let originalPath: String
    /// The filename for the stored image source (last path component).
    public let filename: String
    public let data: Data
    public let mimeType: String
    /// The resolved absolute URL the image was downloaded from — stored as the
    /// version's `external_identity` so a future snapshot-aware refresh can
    /// re-fetch by the same URL.
    public let sourceURL: URL

    public init(originalPath: String, filename: String, data: Data, mimeType: String, sourceURL: URL) {
        self.originalPath = originalPath
        self.filename = filename
        self.data = data
        self.mimeType = mimeType
        self.sourceURL = sourceURL
    }
}

/// A self-contained website snapshot: the page (markdown bytes) plus its
/// downloaded image siblings, all under one shared fetch provenance.
public struct WebsiteSnapshot: Sendable {
    public let page: MaterializedSource
    public let images: [SnapshotImage]
    public let plan: FormatPlan

    public init(page: MaterializedSource, images: [SnapshotImage], plan: FormatPlan) {
        self.page = page
        self.images = images
        self.plan = plan
    }
}

// MARK: - ApplePodcastMaterializer

#if PODCAST_TRANSCRIPTS
/// Materializes an Apple Podcasts episode transcript: the fetch (token signing →
/// AMP metadata → TTML download → parse → markdown) runs off-main, producing a
/// `MaterializedSource` with `agentName = "apple-podcast"`, `activityKind = "fetch"`,
/// `plan`/`externalRef` = the episode's `podcasts.apple.com` URL, and
/// `externalIdentity` = the numeric episode ID (`i=` value). This is the first real
/// consumer of the `SourceMaterializer` protocol; `addURL` routes recognized episode
/// URLs here instead of `WebsiteMaterializer`.
///
/// Holds the page URL separately from `EpisodeRef` so the provenance records the
/// canonical `podcasts.apple.com` link (not the episode ID alone) — the ID is what
/// the AMP endpoint wants, but the URL is what the user pasted and what the Origin
/// row should surface.
public struct ApplePodcastMaterializer: SourceMaterializer {
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
        // off-main; the materializer never touches the store.
        let transcript = try await Task.detached(priority: .userInitiated) {
            try await fetcher.transcript(for: episode)
        }.value
        let urlString = pageURL.absoluteString
        return MaterializedSource(
            filename: transcript.filename,
            data: Data(transcript.markdown.utf8),
            mimeType: MimeType.markdown,
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

// MARK: - ZoteroMaterializer

/// Materializes a Zotero attachment: resolves its local file (off-main read),
/// recording `agentName = "zotero"`, `activityKind = "import"`,
/// `externalIdentity` = the parent item key. Also populates the retained legacy
/// `zoteroItemKey`/`zoteroItemTitle` columns (§4.2).
public struct ZoteroMaterializer: SourceMaterializer {
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
            // Derive (stem, extensionHint) from the attachment filename and route
            // through format dispatch — the SAME pipeline as website/local-file
            // sources. This fixes a latent bug: a Zotero HTML attachment is now
            // converted to Markdown instead of stored as raw HTML.
            let filename = path.lastPathComponent
            let ns = filename as NSString
            let stem = ns.deletingPathExtension
            let extRaw = ns.pathExtension.lowercased()
            let plan = FormatMaterializer.dispatch(
                data: data, contentType: attachment.contentType,
                stem: stem, extensionHint: extRaw.isEmpty ? nil : extRaw)
            return MaterializedSource(
                filename: plan.filename,
                data: plan.data,
                // Pass nil so the store sniffs (the dispatch plan already
                // preserved the original HTML bytes when applicable).
                mimeType: nil,
                zoteroItemKey: parentItem.key,
                zoteroItemTitle: parentItem.title,
                provenance: SourceProvenance(
                    agentName: agentName,
                    activityKind: "import",
                    externalIdentity: parentItem.key
                ),
                extractedMarkdown: plan.extractedMarkdown)
        case .unavailable(let reason):
            throw ZoteroFetchError.unavailable(reason)
        }
    }
}

// MARK: - MarkdownFolderMaterializer

/// Materializes one `.md`/`.markdown` file from a folder import: the
/// `MarkdownFolderReader.walk` does the batch off-main discovery + read, and this
/// materializer adapts each walked file into a `MaterializedSource` with
/// `agentName = "markdown-folder"` (so "everything from a folder import" is a
/// join). Takes the pre-read `(filename, data)` from the walk to avoid a
/// double-read.
public struct MarkdownFolderMaterializer: SourceMaterializer {
    public let agentName = "markdown-folder"
    public let filename: String
    public let data: Data
    public let mimeType: String?
    /// The folder the import walked. Persisted as `plan`/`externalRef` so the
    /// origin chip can reveal it in Finder. `nil` for pre-change callers.
    public let directoryURL: URL?

    public init(filename: String, data: Data, mimeType: String? = nil, directoryURL: URL? = nil) {
        self.filename = filename
        self.data = data
        self.mimeType = mimeType
        self.directoryURL = directoryURL
    }

    public func materialize() async throws -> MaterializedSource {
        MaterializedSource(
            filename: filename,
            data: data,
            mimeType: mimeType,
            provenance: SourceProvenance(
                agentName: agentName,
                activityKind: "import",
                plan: directoryURL?.path,
                externalRef: directoryURL?.path
            )
        )
    }
}
