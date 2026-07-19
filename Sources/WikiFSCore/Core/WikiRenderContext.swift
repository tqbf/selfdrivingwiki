import Foundation

// MARK: - WikiRenderContext

/// Pure-data snapshot of everything a markdown render needs from the store.
///
/// Built on the main actor (from `WikiStoreModel`), safe to hand to a detached
/// render task. This is the extracted, shared form of the precompute that
/// `WikiReaderView.startLoad` historically built inline (reader lines ~815–892).
/// Lifting it here means chat transcripts (Phase A.2) can render through the
/// *same* link-resolution / embed / pin / display-name seam the reader uses,
/// instead of growing a second copy-paste precompute.
///
/// **Threading / SQLite discipline.** `build(from:)` runs on the main actor and
/// performs the batched store reads (existence sets, `embedDescriptors()`,
/// `sourceDerivedChains()`, `siblingImageResolvers()`) exactly once, capturing
/// pure value-type data. The four closures (`isResolved`, `embedInfo`,
/// `displayName`, `pinnedExtractionID`) are derived from that captured data —
/// they NEVER touch the store, so a detached render task can call them off-main
/// without crossing an actor boundary or holding a SQLite connection
/// (`plans/graph-model-and-versioning.md` §8; `sqlite-concurrency` skill: no
/// statement handle or column pointer may cross a method boundary, and no
/// inference/network runs inside a transaction). This is the same
/// compute-once/capture-pure-data discipline the reader already follows — just
/// lifted to a shareable value type.
///
/// **Memoization.** `WikiStoreModel.renderContext()` memoizes an instance and
/// invalidates it by subscribing to `WikiEventBus`: any page/source mutation
/// bumps a generation counter, and the next `renderContext()` call rebuilds.
/// Per-delta renders therefore reuse the snapshot and never touch SQLite.
public struct WikiRenderContext: Sendable {

    // MARK: - Existence / display-at-render / loose-match sets
    //
    // Mirrors `WikiReaderView.startLoad` reader lines ~820–846. Sources match by
    // either display name or filename (lowercased, case-insensitive), AND each
    // name with its path extension stripped — mirroring
    // `resolveSourceByName`'s fallback, so a `[[source:Paper]]` link also
    // resolves against a source whose filename is "Paper.pdf".

    /// Lowercased page titles — drives legacy/forward `[[page:Name]]` existence.
    public let pageTitles: Set<String>
    /// `PageID` → current title, for canonical `[[page:ULID|…]]` display-at-render.
    public let pageIDToName: [PageID: String]
    /// Lowercased source name variants (displayName, filename, ext-stripped) —
    /// drives legacy/forward `[[source:Name]]` existence.
    public let sourceNames: Set<String>
    /// `PageID` → current display name (or filename fallback), for canonical
    /// `[[source:ULID|…]]` display-at-render.
    public let sourceIDToName: [PageID: String]
    /// Lowercased chat titles — drives legacy/forward `[[chat:Name]]` existence.
    public let chatTitles: Set<String>
    /// `PageID` → current title, for canonical `[[chat:ULID|…]]` display-at-render.
    public let chatIDToName: [PageID: String]
    /// Loose-match keys (extension + trailing "(…)" stripped) that are UNIQUE
    /// across sources — the lenient tier mirroring `resolveSourceByName` pass 3,
    /// so ghost styling agrees with navigation.
    public let uniqueLooseKeys: Set<String>

    // MARK: - Embed map
    //
    // Lowercased source name variants (displayName, filename, ext-stripped) AND
    // the source's own id (lowercased) → `SourceEmbedInfo`. Uses the same name
    // variants as `sourceNames` but NOT the loose-match tier — embeds are
    // exact-match-only by design (a loose match might embed the wrong source).
    // Phase 4b: each byteless source carries an optional external `EmbedTarget`
    // resolved from the batched `embedDescriptors()` query, merged here so the
    // render closure stays pure (no store access in the detached task).
    public let embedMap: [String: WikiLinkMarkdown.SourceEmbedInfo]

    // MARK: - Phase 6 @vN chain
    //
    // `sourceID` → ULID-asc `[smvID]` (chronological; index 0 = v1). Built once
    // so `linkified` can resolve an `@vN` ordinal per occurrence without
    // per-link SQL.
    public let sourceDerivedChain: [PageID: [PageID]]

    // MARK: - Phase 4 sibling-image resolver maps
    //
    // Per source, `[original_path → sibling sourceID]`. Captured as pure data
    // (same pattern as `embedMap` / `sourceDerivedChain`). The reader consults
    // only the rendered source's own map (nil for pages — no sibling images);
    // that selection-specific pick stays in the reader, NOT here, because it
    // depends on *which* document is being rendered.
    public let siblingMaps: [PageID: [String: PageID]]

    /// The `wiki-blob://` scheme string, captured on the main actor (the static
    /// property is main-actor-isolated; the detached task can't read it). Exposed
    /// so a transcript render (Phase A.2) can rewrite relative image srcs the same
    /// way the reader does.
    public let blobScheme: String

    /// Initialize with pre-built pure-data snapshots. Prefer
    /// ``WikiRenderContext/build(from:)`` which constructs the sets/maps from a
    /// `WikiStoreModel`.
    public init(
        pageTitles: Set<String>,
        pageIDToName: [PageID: String],
        sourceNames: Set<String>,
        sourceIDToName: [PageID: String],
        chatTitles: Set<String>,
        chatIDToName: [PageID: String],
        uniqueLooseKeys: Set<String>,
        embedMap: [String: WikiLinkMarkdown.SourceEmbedInfo],
        sourceDerivedChain: [PageID: [PageID]],
        siblingMaps: [PageID: [String: PageID]],
        blobScheme: String
    ) {
        self.pageTitles = pageTitles
        self.pageIDToName = pageIDToName
        self.sourceNames = sourceNames
        self.sourceIDToName = sourceIDToName
        self.chatTitles = chatTitles
        self.chatIDToName = chatIDToName
        self.uniqueLooseKeys = uniqueLooseKeys
        self.embedMap = embedMap
        self.sourceDerivedChain = sourceDerivedChain
        self.siblingMaps = siblingMaps
        self.blobScheme = blobScheme
    }

    // MARK: - Build (main actor)

    /// Build a `WikiRenderContext` from the current store state.
    ///
    /// Runs on the main actor and performs the batched store reads exactly once,
    /// capturing pure value-type data. Safe to hand the result to a detached
    /// render task — the derived closures never touch the store.
    @MainActor
    public static func build(from store: WikiStoreModel) -> WikiRenderContext {
        // Build the shared link index from the model's already-fetched rows.
        // Centralizes source name-variant / loose-key / sibling-image
        // computation so this and Projection.makeLinkMaps agree on normalization
        // (#511). Each consumer then adapts the neutral entries to its own shape.
        let index = WikiLinkIndex.build(
            pages: store.summaries.map {
                WikiLinkIndex.PageEntry(id: $0.id.rawValue, title: $0.title) },
            sources: store.sources.map {
                WikiLinkIndex.SourceEntry(
                    id: $0.id.rawValue, filename: $0.filename, ext: $0.ext,
                    mime: $0.mimeType, displayName: $0.displayName) },
            chats: store.chats.map {
                WikiLinkIndex.ChatEntry(id: $0.id.rawValue, title: $0.title) },
            siblingImages: store.siblingImageResolvers())

        // --- Existence sets + id→name dicts (derived from the shared index) ---
        let pageTitles = Set(index.pages.map { $0.title.lowercased() })
        let pageIDToName = Dictionary(
            uniqueKeysWithValues:
                index.pages.map { (PageID(rawValue: $0.id), $0.title) })

        let sourceNames = index.sourceLowerNameVariants
        let sourceIDToName = Dictionary(
            uniqueKeysWithValues:
                index.sources.map { (PageID(rawValue: $0.id), $0.humanName) })

        let chatTitles = Set(index.chats.map { $0.title.lowercased() })
        let chatIDToName = Dictionary(
            uniqueKeysWithValues:
                index.chats.map { (PageID(rawValue: $0.id), $0.title) })

        let uniqueLooseKeys = index.uniqueSourceLooseKeys

        // --- Embed map (reader lines ~848–873; WRC-specific — per-source) ---
        //
        // Two resolution paths compose here, in priority order:
        //   1. **Mermaid diagram** (#670): a source carrying `.mmd` /
        //      `text/mermaid` / `text/x-mermaid` (cheap detector arms —
        //      mime + filename only, no content scan) resolves to a `.diagram`
        //      EmbedTarget carrying the raw source text. The renderer emits
        //      `<div class='mermaid'>…</div>`; the bundled mermaid.min.js (v11)
        //      picks it up and inlines an SVG. Diagram takes precedence over
        //      the descriptor path because a `.mmd` source is byteful (it
        //      carries real text bytes) and therefore absent from
        //      `embedDescriptors()` (which is `WHERE sv.blob_hash IS NULL`) —
        //      a diagram source would otherwise fall through to the byteful
        //      blob branch and emit nothing (no image/audio/video/pdf).
        //   2. **Byteless external media** (Phase 4b): synthetic provider mimes
        //      + Apple Podcasts + direct-remote media, dispatched through
        //      `ExternalEmbed.target(for:)` as before.
        let embedDescriptorMap = store.embedDescriptors()
        var embedMap: [String: WikiLinkMarkdown.SourceEmbedInfo] = [:]
        for source in store.sources {
            let target: EmbedTarget? = {
                // 1. Mermaid diagram — #670.
                if MermaidSourceDetector.isMermaidSource(
                    mimeType: source.mimeType,
                    filename: source.filename,
                    content: nil),
                   let bytes = store.sourceBytes(id: source.id),
                   let text = String(data: bytes, encoding: .utf8) {
                    return EmbedTarget(
                        kind: .diagram, url: source.id.rawValue, content: text)
                }
                // 2. Byteless external media (provider iframes, direct-remote,
                //    Apple Podcasts).
                return embedDescriptorMap[source.id]
                    .flatMap { ExternalEmbed.target(for: $0) }
            }()
            let info = WikiLinkMarkdown.SourceEmbedInfo(
                id: source.id, mimeType: source.mimeType, target: target)
            let names = [source.displayName, source.filename].compactMap({ $0 })
            let stripped = names.map { ($0 as NSString).deletingPathExtension }
            for name in (names + stripped).map({ $0.lowercased() }) {
                embedMap[name] = info
            }
            embedMap[source.id.rawValue.lowercased()] = info
        }

        // --- Phase 6 chain + Phase 4 sibling maps (WRC-specific) ---
        let sourceDerivedChain = store.sourceDerivedChains()
        let siblingMaps = index.siblingImages

        return WikiRenderContext(
            pageTitles: pageTitles,
            pageIDToName: pageIDToName,
            sourceNames: sourceNames,
            sourceIDToName: sourceIDToName,
            chatTitles: chatTitles,
            chatIDToName: chatIDToName,
            uniqueLooseKeys: uniqueLooseKeys,
            embedMap: embedMap,
            sourceDerivedChain: sourceDerivedChain,
            siblingMaps: siblingMaps,
            blobScheme: WikiLinkMarkdown.blobScheme)
    }

    // MARK: - Render closures (pure — derived from captured data)

    /// `(name, kind) -> Bool`: resolves a link target against the captured
    /// existence sets. Canonical ULID targets check id-keyed existence;
    /// legacy/forward links check the name sets (plus the unique loose-key tier
    /// for sources). This is the exact `isResolved` closure
    /// `WikiReaderView.startLoad` passed to `ReaderMarkdown.prepared` — moved
    /// here verbatim so reader and transcript agree on ghost styling.
    public var isResolved: (String, ParsedLink.LinkType) -> Bool {
        { name, kind in
            if WikiLinkParser.isCanonicalULID(name) {
                let id = PageID(rawValue: name)
                switch kind {
                case .source: return sourceIDToName[id] != nil
                case .chat:   return chatIDToName[id] != nil
                case .page:   return pageIDToName[id] != nil
                }
            }
            switch kind {
            case .source: return sourceNames.contains(name.lowercased())
                || uniqueLooseKeys.contains(WikiNameRules.looseMatchKey(name))
            case .chat:   return chatTitles.contains(name.lowercased())
            case .page:   return pageTitles.contains(name.lowercased())
            }
        }
    }

    /// `name -> SourceEmbedInfo?`: resolves a `![[source:…]]` embed target name
    /// to its `(id, mimeType, target)` via the captured embed map (lowercased
    /// lookup). Pure — no store access at render time.
    public var embedInfo: (String) -> WikiLinkMarkdown.SourceEmbedInfo? {
        { name in embedMap[name.lowercased()] }
    }

    /// `(id, kind) -> String?`: display-at-render heal. A canonical
    /// `[[source:ULID|Stale Title]]` resolves ULID → the CURRENT display name
    /// here, so a rename self-heals visually without touching bytes. Returns
    /// `nil` when the id isn't known (the renderer keeps the alias).
    public var displayName: (PageID, ParsedLink.LinkType) -> String? {
        { id, kind in
            switch kind {
            case .source: return sourceIDToName[id]
            case .chat:   return chatIDToName[id]
            case .page:   return pageIDToName[id]
            }
        }
    }

    /// `(sourceID, ordinal) -> PageID?`: Phase 6 `@vN` pin resolution. Resolves a
    /// 1-based ordinal into the source's ULID-asc chain. Out-of-range → `nil`
    /// (the link opens HEAD).
    public var pinnedExtractionID: (PageID, Int) -> PageID? {
        { sourceID, ordinal in
            guard let chain = sourceDerivedChain[sourceID],
                  ordinal >= 1 else { return nil }
            let idx = ordinal - 1
            return idx < chain.count ? chain[idx] : nil
        }
    }
}
