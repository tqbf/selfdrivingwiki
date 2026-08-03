import Foundation

/// Pure synthesizer that renders a readable synthetic-markdown page for a
/// **byteless** source (YouTube / Vimeo / Spotify / SoundCloud / remote-media)
/// from the pasted URL, optional oEmbed metadata, and an optional transcript.
///
/// The output is stored as the source's processed-markdown head via
/// `appendProcessedMarkdown(origin: .transcript)`, so the reader, the File
/// Provider's `.md` sibling, and Tantivy all see it through the existing
/// storage path (Projection.swift emits the sibling automatically because the
/// synthetic mimes — `video/youtube`, `audio/spotify`, … — are non-`text/*`).
///
/// Why a pure function: the synthesizer has no I/O, no actor hops, no error
/// paths — the same fixture-driven discipline as `MediaEmbedURL` and
/// `MediaTitleFetcher.parseMetadata`. Issue #646.
public enum MediaMarkdownSynthesizer {

    /// Render the synthetic markdown.
    ///
    /// - Parameters:
    ///   - url: The pasted source URL (always present). Rendered as a clickable
    ///     link near the top, and used as the heading fallback when no title is
    ///     available.
    ///   - metadata: The oEmbed metadata blob, when the provider's oEmbed
    ///     endpoint was reachable. `nil` for `remote-media` (no oEmbed) or a
    ///     best-effort fetch failure.
    ///   - fallbackTitle: A fallback heading when `metadata.title` is nil —
    ///     typically the source's display name or filename. The caller already
    ///     has this; passing it in keeps the synthesizer pure.
    ///   - transcript: Optional transcript markdown body (e.g. YouTube captions
    ///     already rendered as markdown, or podcast TTML → markdown). When
    ///     present, appended under a `## Transcript` heading.
    /// - Returns: The synthesized markdown string. Always non-empty.
    public static func synthesize(
        url: String,
        metadata: MediaTitleFetcher.MediaOEmbedMetadata?,
        fallbackTitle: String,
        transcript: String? = nil
    ) -> String {
        let title = metadata?.title ?? fallbackTitle
        var lines: [String] = []
        lines.append("# \(title)")
        lines.append("")
        lines.append("[\(url)](\(url))")
        lines.append("")

        // Metadata block — bold "key: value" pairs, only for fields we have.
        // Track whether we wrote anything so the trailing blank line is
        // conditional (avoids a double-blank gap when the block is empty).
        var wroteMetadata = false
        if let provider = metadata?.providerName, !provider.isEmpty {
            lines.append("**Provider:** \(provider)")
            wroteMetadata = true
        }
        if let author = metadata?.authorName, !author.isEmpty {
            if let authorURL = metadata?.authorURL, !authorURL.isEmpty {
                lines.append("**Author:** [\(author)](\(authorURL))")
            } else {
                lines.append("**Author:** \(author)")
            }
            wroteMetadata = true
        }
        if let seconds = metadata?.durationSeconds, seconds > 0 {
            lines.append("**Duration:** \(formatDuration(seconds))")
            wroteMetadata = true
        }
        if wroteMetadata {
            lines.append("")
        }

        if let description = metadata?.descriptionText, !description.isEmpty {
            lines.append(description)
            lines.append("")
        }

        if let transcript, !transcript.isEmpty {
            lines.append("---")
            lines.append("")
            lines.append("## Transcript")
            lines.append("")
            lines.append(transcript)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Format a duration in seconds as `H:MM:SS` (or `M:SS` when under an hour).
    /// Pure.
    static func formatDuration(_ totalSeconds: Int) -> String {
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
