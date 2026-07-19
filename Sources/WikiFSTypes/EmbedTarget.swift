import Foundation

/// The resolved embed target for a byteless source: which HTML element to
/// render and the URL it points at.
///
/// Lives in `WikiFSTypes` (the shared leaf target) so the link-cluster renderer
/// `WikiLinkMarkdown.embedHTML` (in `WikiFSLinks`) can return one without a
/// circular dependency, while the dispatch table that *produces* it
/// (`ExternalEmbed`, in `WikiFSCore`) also references it (module restructuring
/// Phase 1, #532). Extracted from `ExternalEmbed.swift`.
public struct EmbedTarget: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A provider player `<iframe>` (YouTube, Vimeo, Spotify, SoundCloud,
        /// Apple Podcasts).
        case iframe
        /// A native `<audio>` pointed at a direct-remote media URL.
        case audio
        /// A native `<video>` pointed at a direct-remote media URL.
        case video
        /// A Mermaid diagram rendered inline by the reader's bundled
        /// `mermaid.min.js` (v11). The diagram source text travels in
        /// `content`; `url` carries the source id (informational — the
        /// renderer dispatches on `kind`, not `url`). `WikiLinkMarkdown
        /// .embedHTML` emits the source as a fenced ```mermaid code block
        /// (so it survives the markdown→HTML converter in every context —
        /// #736), and the reader's `mermaidBootstrapJS` converts the
        /// resulting `code.language-mermaid` element into a
        /// `<div class="mermaid">` whose `textContent` is the raw diagram
        /// source, then invokes `mermaid.run` — no per-embed JS. Issue #670.
        case diagram
    }

    public let kind: Kind
    public let url: String
    /// For `.diagram` targets, the raw Mermaid source text. `WikiLinkMarkdown
    /// .embedHTML` emits it inside a fenced ```mermaid code block, and the
    /// reader's `mermaidBootstrapJS` turns that into a `<div class="mermaid">`
    /// before running mermaid (#736). `nil` for all media embeds
    /// (`.iframe` / `.audio` / `.video`) — those dispatch on `url` alone.
    /// Issue #670.
    public let content: String?

    public init(kind: Kind, url: String, content: String? = nil) {
        self.kind = kind
        self.url = url
        self.content = content
    }
}
