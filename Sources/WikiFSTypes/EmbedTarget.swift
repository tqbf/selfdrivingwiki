import Foundation

/// A resolved external media target.
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
    }

    public let kind: Kind
    public let url: String

    public init(kind: Kind, url: String) {
        self.kind = kind
        self.url = url
    }
}
