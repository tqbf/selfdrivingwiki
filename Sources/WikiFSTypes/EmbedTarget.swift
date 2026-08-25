import Foundation

/// A resolved external media or Mermaid source target.
///
/// `ExternalEmbed` creates this shared value. The typed document resolver uses
/// it without coupling `WikiFSCore` to the reader layer.
public struct EmbedTarget: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A provider player `<iframe>` (YouTube, Vimeo, Spotify, SoundCloud,
        /// Apple Podcasts).
        case iframe
        /// A native `<audio>` pointed at a direct-remote media URL.
        case audio
        /// A native `<video>` pointed at a direct-remote media URL.
        case video
        /// A Mermaid source that the typed document resolver lowers as inline
        /// content. `content` carries exact source text. `url` carries source
        /// identity for compatibility and is not an authorization input.
        case diagram
    }

    public let kind: Kind
    public let url: String
    /// The exact Mermaid source for `.diagram`. This value is `nil` for media
    /// targets, which use `url` only.
    public let content: String?

    public init(kind: Kind, url: String, content: String? = nil) {
        self.kind = kind
        self.url = url
        self.content = content
    }
}
