import Foundation
import WikiFSCore
import WikiFSTypes

/// Pure resolver for authored embed syntax. Callers provide immutable exact
/// identity maps and pinned source facts; this type performs no store or package
/// reads.
struct DocumentEmbedResolver: Sendable {
    struct Inputs: Sendable {
        let pageIDByName: [String: PageID]
        let sourceByName: [String: DocumentSourceResolution]
        let pageTitlesByID: [PageID: String]
        let sourceNamesByID: [SourceID: String]
        let chatIDByName: [String: ChatID]
        let chatTitlesByID: [ChatID: String]
        let sourceDerivedChain: [SourceID: [SourceMarkdownVersionID]]
        let sourceRendererCandidates: [SourceID: RendererEmbedPlan]
        let markdownImageTargets: [String: ResolvedMarkdownImageTarget]
        let assumeLinksResolved: Bool

        init(
            pageIDByName: [String: PageID] = [:],
            sourceByName: [String: DocumentSourceResolution] = [:],
            pageTitlesByID: [PageID: String] = [:],
            sourceNamesByID: [SourceID: String] = [:],
            chatIDByName: [String: ChatID] = [:],
            chatTitlesByID: [ChatID: String] = [:],
            sourceDerivedChain: [SourceID: [SourceMarkdownVersionID]] = [:],
            sourceRendererCandidates: [SourceID: RendererEmbedPlan] = [:],
            markdownImageTargets: [String: ResolvedMarkdownImageTarget] = [:],
            assumeLinksResolved: Bool = false
        ) {
            self.pageIDByName = pageIDByName
            self.sourceByName = sourceByName
            self.pageTitlesByID = pageTitlesByID
            self.sourceNamesByID = sourceNamesByID
            self.chatIDByName = chatIDByName
            self.chatTitlesByID = chatTitlesByID
            self.sourceDerivedChain = sourceDerivedChain
            self.sourceRendererCandidates = sourceRendererCandidates
            self.markdownImageTargets = markdownImageTargets
            self.assumeLinksResolved = assumeLinksResolved
        }
    }

    let inputs: Inputs

    func projection(
        for prepared: PreparedMarkdownDocument,
        resolveEmbeds: Bool = true,
        ancestors: Set<DocumentTransclusionTarget> = []
    ) -> ResolvedDocumentProjection {
        var embeds: [MarkdownSourceRange: ResolvedDocumentEmbed] = [:]
        var links: [MarkdownSourceRange: ResolvedDocumentLink] = [:]
        for node in prepared.wikiSyntax {
            switch node {
            case .embed(let embed):
                if resolveEmbeds {
                    embeds[embed.sourceRange] = resolveWikiEmbed(embed, ancestors: ancestors)
                }
            case .link(let link):
                links[link.sourceRange] = resolveWikiLink(link)
            }
        }
        return ResolvedDocumentProjection(
            wikiEmbeds: embeds,
            wikiLinks: links,
            markdownImages: inputs.markdownImageTargets)
    }

    func resolveWikiLink(_ link: WikiMarkdownSyntaxNode.Link) -> ResolvedDocumentLink {
        let canonicalID = link.target.canonicalID
        let currentName: String?
        let resolved: Bool

        switch link.target.namespace {
        case .page:
            if let canonicalID {
                currentName = inputs.pageTitlesByID[PageID(rawValue: canonicalID)]
                resolved = currentName != nil
            } else {
                currentName = nil
                resolved = inputs.pageIDByName[link.target.literal.lowercased()] != nil
            }
        case .source:
            if let canonicalID {
                currentName = inputs.sourceNamesByID[SourceID(rawValue: canonicalID)]
                resolved = currentName != nil
            } else {
                currentName = nil
                resolved = exactSource(for: link.target.literal) != nil
            }
        case .chat:
            if let canonicalID {
                currentName = inputs.chatTitlesByID[ChatID(rawValue: canonicalID)]
                resolved = currentName != nil
            } else {
                currentName = nil
                resolved = inputs.chatIDByName[link.target.literal.lowercased()] != nil
            }
        }

        let pinnedSourceVersion: SourceMarkdownVersionID? = {
            guard link.target.namespace == .source,
                  canonicalID != nil,
                  link.target.fragment != nil,
                  let ordinal = link.target.sourceVersionPin,
                  ordinal > 0,
                  let canonicalID else { return nil }
            let chain = inputs.sourceDerivedChain[SourceID(rawValue: canonicalID)] ?? []
            guard chain.indices.contains(ordinal - 1) else { return nil }
            return chain[ordinal - 1]
        }()

        return ResolvedDocumentLink(
            namespace: link.target.namespace,
            title: currentName ?? link.target.literal,
            canonicalID: canonicalID,
            fragment: link.target.fragment,
            pinnedSourceVersion: pinnedSourceVersion,
            displayText: currentName ?? link.displayText,
            isResolved: inputs.assumeLinksResolved || resolved)
    }

    func resolveWikiEmbed(
        _ embed: WikiMarkdownSyntaxNode.Embed,
        ancestors: Set<DocumentTransclusionTarget> = []
    ) -> ResolvedDocumentEmbed {
        let fallback = DocumentEmbedFallback.literal(embed.authoredLiteral)

        switch embed.target.namespace {
        case .chat:
            return .missing(.chat(literal: embed.target.literal), fallback: fallback)
        case .page:
            // Explicit/canonical pages remain in the page namespace. A bare page
            // spelling falls back to an exact source only after page resolution
            // fails; callers construct pageIDByName and sourceByName with exact
            // normalized keys, so no loose source match can embed the wrong item.
            if let pageID = resolvedPageID(embed.target) {
                let title = embed.alias ?? inputs.pageTitlesByID[pageID] ?? embed.displayText
                return .transclusion(
                    target: .page(pageID),
                    display: .init(title: title, altText: title),
                    fragment: embed.target.fragment,
                    ancestors: ancestors)
            }
            if let source = exactSource(for: embed.target.literal) {
                return resolveSource(embed: embed, source: source, ancestors: ancestors)
            }
            return .missing(.page(literal: embed.target.literal), fallback: fallback)
        case .source:
            guard let source = resolvedSource(embed.target) else {
                return .missing(.source(literal: embed.target.literal), fallback: fallback)
            }
            return resolveSource(embed: embed, source: source, ancestors: ancestors)
        }
    }

    func resolveMarkdownImage(
        source: String,
        altText: String,
        target: ResolvedMarkdownImageTarget? = nil
    ) -> ResolvedDocumentEmbed {
        let syntax = DocumentEmbedSyntax.markdownImage(
            sourceRange: nil,
            source: source,
            altText: altText)
        let resolvedSource: DocumentInlineTarget
        switch target {
        case .renderer(let rendererReference, let pinnedSource):
            let fallback = DocumentEmbedFallback.image(
                source: "wiki-blob://source/\(pinnedSource.sourceID.rawValue)",
                altText: altText)
            let plan = RendererEmbedPlan(
                placeholderID: "sdw-inline-renderer-\(pinnedSource.digest.hex.prefix(16))",
                embeddingRole: .inlineContent,
                rendererReference: rendererReference,
                input: .source(pinnedSource),
                semanticContent: "Image source available as \(pinnedSource.mimeType.rawValue).",
                displayTitle: altText.isEmpty ? nil : altText,
                activationMetadata: .init(
                    controlLabel: "Open",
                    accessibilityLabel: "Open inline image renderer",
                    summary: "Open the image source in the renderer pane."))
            return .renderer(syntax: syntax, role: .inlineContent, plan: plan, fallback: fallback)
        case .blob(let sourceID):
            resolvedSource = .blob(sourceID)
        case nil:
            resolvedSource = .authored(source)
        }
        let fallbackSource = inlineImageSource(resolvedSource)
        return .inlineMedia(
            syntax: syntax,
            kind: .image,
            display: .init(title: nil, altText: altText),
            target: resolvedSource,
            fallback: .image(source: fallbackSource, altText: altText))
    }

    private func inlineImageSource(_ target: DocumentInlineTarget) -> String {
        switch target {
        case .source(let source): return "wiki-blob://source/\(source.sourceID.rawValue)"
        case .blob(let sourceID): return "wiki-blob://source/\(sourceID.rawValue)"
        case .external(let url): return url.absoluteString
        case .authored(let source): return source
        }
    }

    private func resolveSource(
        embed: WikiMarkdownSyntaxNode.Embed,
        source: DocumentSourceResolution,
        ancestors: Set<DocumentTransclusionTarget>
    ) -> ResolvedDocumentEmbed {
        let syntax = DocumentEmbedSyntax.wikiSourceMedia(embed)
        let literalFallback = DocumentEmbedFallback.literal(embed.authoredLiteral)
        let title = embed.alias ?? source.displayName
        let display = DocumentEmbedDisplayMetadata(title: title, altText: title)

        // Predicate order is load-bearing: Mermaid source first, then external
        // media, then byteful MIME media, then non-media transclusion.
        if source.isMermaidSource, let bytes = source.bytes,
           let text = String(data: bytes, encoding: .utf8) {
            return .inlineMedia(
                syntax: syntax,
                kind: .mermaidSource,
                display: display,
                target: .authored(text),
                fallback: .code(language: "mermaid", source: text))
        }
        if let external = source.externalTarget,
           let resolved = externalMedia(external) {
            return .inlineMedia(
                syntax: syntax,
                kind: resolved.kind,
                display: display,
                target: resolved.target,
                fallback: .media(label: embed.displayText, target: resolved.target))
        }
        if let rendererPlan = inputs.sourceRendererCandidates[source.sourceID],
           rendererPlan.embeddingRole == .inlineContent {
            return .renderer(
                syntax: syntax,
                role: .inlineContent,
                plan: rendererPlan,
                fallback: literalFallback)
        }
        if let mediaKind = bytefulMediaKind(mimeType: source.mimeType) {
            let target = DocumentInlineTarget.blob(source.sourceID)
            return .inlineMedia(
                syntax: syntax,
                kind: mediaKind,
                display: display,
                target: target,
                fallback: .media(label: embed.displayText, target: target))
        }
        return .transclusion(
            target: .source(source.sourceID),
            display: display,
            fragment: embed.target.fragment,
            ancestors: ancestors)
    }

    private func resolvedPageID(_ target: WikiMarkdownTarget) -> PageID? {
        if let canonicalID = target.canonicalID {
            let id = PageID(rawValue: canonicalID)
            return inputs.pageTitlesByID[id] == nil ? nil : id
        }
        return inputs.pageIDByName[target.literal.lowercased()]
    }

    private func resolvedSource(_ target: WikiMarkdownTarget) -> DocumentSourceResolution? {
        if let canonicalID = target.canonicalID {
            let sourceID = SourceID(rawValue: canonicalID)
            guard inputs.sourceNamesByID[sourceID] != nil else { return nil }
            return inputs.sourceByName[canonicalID.lowercased()]
        }
        return exactSource(for: target.literal)
    }

    private func exactSource(for literal: String) -> DocumentSourceResolution? {
        inputs.sourceByName[literal.lowercased()]
    }

    private func bytefulMediaKind(mimeType: String?) -> DocumentMediaKind? {
        guard let mime = mimeType?.lowercased() else { return nil }
        if mime.hasPrefix("image/") { return .image }
        if mime.hasPrefix("audio/") { return .audio }
        if mime.hasPrefix("video/") { return .video }
        if mime == MimeType.pdf { return .pdf }
        return nil
    }

    private func externalMedia(_ target: EmbedTarget) -> (kind: DocumentMediaKind, target: DocumentInlineTarget)? {
        guard let url = URL(string: target.url) else { return nil }
        let typed = DocumentInlineTarget.external(url)
        switch target.kind {
        case .audio: return (.audio, typed)
        case .video: return (.video, typed)
        case .iframe: return (.externalFrame, typed)
        case .diagram: return nil
        }
    }
}
