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
    }

    public let kind: Kind
    public let url: String

    public init(kind: Kind, url: String) {
        self.kind = kind
        self.url = url
    }
}
