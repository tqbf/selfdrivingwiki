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
    /// `SourceID` → current display name (or filename fallback), for canonical
    /// `[[source:ULID|…]]` display-at-render.
    public let sourceIDToName: [SourceID: String]
    /// Lowercased chat titles — drives legacy/forward `[[chat:Name]]` existence.
    public let chatTitles: Set<String>
    /// `ChatID` → current title, for canonical `[[chat:ULID|…]]` display-at-render.
    public let chatIDToName: [ChatID: String]
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
    public let sourceDerivedChain: [SourceID: [SourceMarkdownVersionID]]

    // MARK: - Phase 4 sibling-image resolver maps
    //
    // Per source, `[original_path → sibling sourceID]`. Captured as pure data
    // (same pattern as `embedMap` / `sourceDerivedChain`). The reader consults
    // only the rendered source's own map (nil for pages — no sibling images);
    // that selection-specific pick stays in the reader, NOT here, because it
    // depends on *which* document is being rendered.
    public let siblingMaps: [SourceID: [String: SourceID]]

    /// Immutable renderer-facing projection built on the main actor and handed
    /// to the detached markdown conversion path.
    public let rendererEmbedProjection: RendererEmbedProjection

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
        sourceIDToName: [SourceID: String],
        chatTitles: Set<String>,
        chatIDToName: [ChatID: String],
        uniqueLooseKeys: Set<String>,
        embedMap: [String: WikiLinkMarkdown.SourceEmbedInfo],
        sourceDerivedChain: [SourceID: [SourceMarkdownVersionID]],
        siblingMaps: [SourceID: [String: SourceID]],
        blobScheme: String,
        rendererFenceClaims: [RendererFenceAlias: RendererFenceClaimAssignment] = [:],
        unavailableFenceAliases: Set<RendererFenceAlias> = []
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
        self.rendererEmbedProjection = RendererEmbedProjection(
            sourceEmbeds: embedMap,
            richFenceClaims: rendererFenceClaims,
            unavailableFenceAliases: unavailableFenceAliases)
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
        let siblingMaps = store.siblingImageResolvers()
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
            siblingImages: siblingMaps)

        // --- Existence sets + id→name dicts (derived from the shared index) ---
        let pageTitles = Set(index.pages.map { $0.title.lowercased() })
        let pageIDToName: [PageID: String] = Dictionary(
            uniqueKeysWithValues:
                index.pages.map { (PageID(rawValue: $0.id), $0.title) })

        let sourceNames = index.sourceLowerNameVariants
        let sourceIDToName: [SourceID: String] = Dictionary(
            uniqueKeysWithValues:
                index.sources.map { (SourceID(rawValue: $0.id), $0.humanName) })

        let chatTitles = Set(index.chats.map { $0.title.lowercased() })
        let chatIDToName: [ChatID: String] = Dictionary(
            uniqueKeysWithValues:
                index.chats.map { (ChatID(rawValue: $0.id), $0.title) })

        let uniqueLooseKeys = index.uniqueSourceLooseKeys

        // --- Embed map (reader lines ~848–873; WRC-specific — per-source) ---
        //
        // One resolution path: byteless external media (synthetic provider
        // mimes + Apple Podcasts + direct-remote media) dispatched through
        // `ExternalEmbed.target(for:)` as before. Byteful sources (text,
        // diagrams, documents) never resolve an embed target here — the
        // generic source-renderer and transclusion arms handle them, keyed
        // by descriptor data rather than a host-side format branch.
        let embedDescriptorMap = store.embedDescriptors()
        let normalizedEmbedNamesBySource: [SourceID: Set<String>] = Dictionary(
            uniqueKeysWithValues: store.sources.map { source in
                let names = [source.displayName, source.filename].compactMap { $0 }
                let stripped = names.map { ($0 as NSString).deletingPathExtension }
                return (source.id, Set((names + stripped).map { $0.lowercased() }))
            })
        var embedNameCounts: [String: Int] = [:]
        for names in normalizedEmbedNamesBySource.values {
            for name in names { embedNameCounts[name, default: 0] += 1 }
        }

        var embedMap: [String: WikiLinkMarkdown.SourceEmbedInfo] = [:]
        for source in store.sources {
            let target: EmbedTarget? = embedDescriptorMap[source.id]
                .flatMap { ExternalEmbed.target(for: $0) }
            let info = WikiLinkMarkdown.SourceEmbedInfo(
                id: source.id, mimeType: source.mimeType, target: target)
            for name in normalizedEmbedNamesBySource[source.id] ?? []
            where embedNameCounts[name] == 1 {
                embedMap[name] = info
            }
            embedMap[source.id.rawValue.lowercased()] = info
        }

        // --- Phase 6 chain + Phase 4 sibling maps (WRC-specific) ---
        let sourceDerivedChain = store.sourceDerivedChains()
        // Registry-derived rich-fence claims. The descriptor lists are injected
        // by the app wiring (the built-in table lives above this layer), so
        // every `renderContext()` consumer — reader, chat transcripts, activity
        // windows — sees the same claim map with no per-view wiring.
        let rendererFenceClaims = RendererFenceClaimResolver.resolve(
            builtInDescriptors: store.rendererBuiltInDescriptors,
            enabledInstalledDescriptors: store.rendererEnabledDescriptors)
        // Remember every alias this store has seen claimed. A later registry
        // refresh that drops a claimant (removal or safe-mode suppression)
        // then explains its fences' fallback instead of rendering silently.
        store.noteResolvedFenceAliases(Set(rendererFenceClaims.keys))
        let unavailableFenceAliases = store.resolvedFenceAliases
            .subtracting(rendererFenceClaims.keys)
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
            blobScheme: WikiLinkMarkdown.blobScheme,
            rendererFenceClaims: rendererFenceClaims,
            unavailableFenceAliases: unavailableFenceAliases)
    }

    // MARK: - Render closures (pure — derived from captured data)

    /// `(name, kind) -> Bool`: resolves a link target against the captured
    /// existence sets. Canonical ULID targets check id-keyed existence;
    /// legacy/forward links check the name sets (plus the unique loose-key tier
    /// for sources). This is the exact `isResolved` closure
    /// `WikiReaderView.startLoad` used for legacy resolution — moved
    /// here verbatim so reader and transcript agree on ghost styling.
    public var isResolved: (String, ParsedLink.LinkType) -> Bool {
        { name, kind in
            if WikiLinkParser.isCanonicalULID(name) {
                let pageID = PageID(rawValue: name)
                let sourceID = SourceID(rawValue: name)
                let chatID = ChatID(rawValue: name)
                switch kind {
                case .source: return sourceIDToName[sourceID] != nil
                case .chat:   return chatIDToName[chatID] != nil
                case .page:   return pageIDToName[pageID] != nil
                }
            }
            switch kind {
            case .source:
                return sourceNames.contains(name.lowercased())
                    || uniqueLooseKeys.contains(WikiNameRules.looseMatchKey(name))
                    || WikiLinkResolver.legacySourceProjectionID(from: name)
                        .map { sourceIDToName[$0] != nil } == true
            case .chat:   return chatTitles.contains(name.lowercased())
            case .page:   return pageTitles.contains(name.lowercased())
            }
        }
    }

    /// `name -> SourceEmbedInfo?`: resolves a `![[source:…]]` embed target name
    /// to its `(id, mimeType, target)` via the captured embed map (lowercased
    /// lookup). Pure — no store access at render time.
    public var embedInfo: (String) -> WikiLinkMarkdown.SourceEmbedInfo? {
        { name in
            embedMap[name.lowercased()]
                ?? WikiLinkResolver.legacySourceProjectionID(from: name)
                    .flatMap { embedMap[$0.rawValue.lowercased()] }
        }
    }

    /// `(id, kind) -> String?`: display-at-render heal. A canonical
    /// `[[source:ULID|Stale Title]]` resolves ULID → the CURRENT display name
    /// here, so a rename self-heals visually without touching bytes. Returns
    /// `nil` when the id isn't known (the renderer keeps the alias).
    public var displayName: (String, ParsedLink.LinkType) -> String? {
        { id, kind in
            switch kind {
            case .source: return sourceIDToName[SourceID(rawValue: id)]
            case .chat:   return chatIDToName[ChatID(rawValue: id)]
            case .page:   return pageIDToName[PageID(rawValue: id)]
            }
        }
    }

    /// `(sourceID, ordinal) -> SourceMarkdownVersionID?`: Phase 6 `@vN` pin
    /// resolution. Resolves a
    /// 1-based ordinal into the source's ULID-asc chain. Out-of-range → `nil`
    /// (the link opens HEAD).
    public var pinnedExtractionID: (SourceID, Int) -> SourceMarkdownVersionID? {
        { sourceID, ordinal in
            guard let chain = sourceDerivedChain[sourceID],
                  ordinal >= 1 else { return nil }
            let idx = ordinal - 1
            return idx < chain.count ? chain[idx] : nil
        }
    }
}

/// Host-built projection of renderer-facing embed facts. It mirrors the source
/// embed map and the registry-derived rich-fence claim map: an alias is rich
/// exactly when some available descriptor claims it. Aliases this store has
/// seen claimed but that are no longer available (package removed or
/// safe-mode suppressed this session) ride along so their fences can explain
/// the fallback instead of silently becoming plain code.
public struct RendererEmbedProjection: Sendable {
    public let sourceEmbeds: [String: WikiLinkMarkdown.SourceEmbedInfo]
    public let richFenceClaims: [RendererFenceAlias: RendererFenceClaimAssignment]
    public let unavailableFenceAliases: Set<RendererFenceAlias>

    public init(
        sourceEmbeds: [String: WikiLinkMarkdown.SourceEmbedInfo],
        richFenceClaims: [RendererFenceAlias: RendererFenceClaimAssignment] = [:],
        unavailableFenceAliases: Set<RendererFenceAlias> = []
    ) {
        self.sourceEmbeds = sourceEmbeds
        self.richFenceClaims = richFenceClaims
        self.unavailableFenceAliases = unavailableFenceAliases
    }

    public func sourceEmbedInfo(for name: String) -> WikiLinkMarkdown.SourceEmbedInfo? {
        sourceEmbeds[name.lowercased()]
    }

    /// The claim answering one rich-fence alias, or `nil` when no available
    /// descriptor claims it (never installed, removed, or safe-mode suppressed).
    public func fenceClaim(for alias: RendererFenceAlias) -> RendererFenceClaimAssignment? {
        richFenceClaims[alias]
    }

    public func allowsRichFence(_ alias: RendererFenceAlias) -> Bool {
        fenceClaim(for: alias) != nil
    }
}
