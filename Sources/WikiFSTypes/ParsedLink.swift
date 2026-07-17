import Foundation

/// A single parsed wiki-link reference: the kind + the bare target
/// (prefix-stripped) and the display text to record in the link tables.
///
/// Lives in `WikiFSTypes` (the shared leaf target) so the `WikiStore` protocol
/// (in `WikiFSCore`) can reference `[ParsedLink]` in its `replaceLinks` method
/// without a circular dependency on the `WikiFSLinks` target — the parser that
/// *produces* these values lives in `WikiFSLinks` (module restructuring Phase 1,
/// #532 / design §5). Extracted from `WikiLinkParser` where it was previously
/// nested as `ParsedLink`.
public struct ParsedLink: Equatable, Sendable {
    public enum LinkType: String, Equatable, Sendable, CaseIterable {
        case page, source, chat

        /// Bridge to the shared ``ResourceKind`` vocabulary (#489). The three
        /// linkable link-types map directly to their `ResourceKind`
        /// counterparts, so link-kind prefixes and host strings come from one
        /// source of truth.
        public var resourceKind: ResourceKind {
            switch self {
            case .page:   return .page
            case .source: return .source
            case .chat:   return .chat
            }
        }

        /// The `[[kind:Target]]` wiki-link prefix for this kind (`"page:"`,
        /// `"source:"`, `"chat:"`). Never nil — all `LinkType` cases are
        /// linkable. Delegates to ``ResourceKind/linkPrefix``, so there is
        /// exactly one place where prefix strings are defined (#489).
        public var linkPrefix: String { resourceKind.linkPrefix! }
    }

    public let linkType: LinkType
    public let target: String       // prefix-stripped, whitespace-collapsed (BASE only)
    public let fragment: String?    // everything after the first "#", verbatim; nil if none
    public let linkText: String     // alias verbatim (never prefix-stripped)
    /// True when the link has a `!` embed prefix (`![[source:…]]`). Embeds are
    /// source-only — `![[Page]]` is not valid and is skipped at parse time.
    /// Defaults to `false` so every existing call site compiles unchanged.
    public let isEmbed: Bool
    /// The digits of a trailing `@vN` version pin (e.g. `"3"` for
    /// `[[source:X@v3]]`), or `nil` when the link is unpinned. Phase 6: pins a
    /// specific derived-markdown extraction so a quote highlight survives
    /// re-extraction. The pin is stripped from `target` (resolution is
    /// pin-free); it is re-attached to the raw form / canonical target where
    /// needed. Defaults to `nil` so every existing call site compiles and
    /// equality holds.
    public let versionPin: String?

    /// `linkType` defaults to `.page`, `isEmbed` to `false`, and `versionPin`
    /// to `nil` so every existing `ParsedLink(target:linkText:)` call site
    /// compiles unchanged and equality holds.
    public init(linkType: LinkType = .page, target: String,
                fragment: String? = nil, linkText: String,
                isEmbed: Bool = false, versionPin: String? = nil) {
        self.linkType = linkType
        self.target = target
        self.fragment = fragment
        self.linkText = linkText
        self.isEmbed = isEmbed
        self.versionPin = versionPin
    }
}
