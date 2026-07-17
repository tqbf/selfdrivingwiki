import Foundation

// MARK: - WikiLinkIndex

/// Pure-data snapshot of all linkable entities (pages, sources, chats) with
/// pre-computed normalization maps, built once from pre-fetched rows.
///
/// Both `WikiRenderContext.build` (the in-app reader) and
/// `Projection.makeLinkMaps` (the File Provider projection) derive their own
/// shape from this shared core — the former builds existence sets and
/// `id → name` dicts, the latter builds `name → Target` and
/// `id → Target` dicts. Centralizing the iteration and normalization here
/// eliminates duplicate computation and ensures the two consumers apply the
/// same `WikiNameRules.looseMatchKey` / ext-stripping rules (issue #511).
///
/// **Threading.** The builder is a pure function over value-type entries —
/// no store access, no actor isolation. Each caller fetches rows on its own
/// thread/actor (main actor for `WikiRenderContext`, the File Provider's read
/// store for `Projection`) and passes the pre-fetched data here.
public struct WikiLinkIndex: Sendable, Equatable {

    // MARK: - Entry types

    /// A page's link-relevant fields.
    public struct PageEntry: Sendable, Equatable {
        public let id: String
        public let title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    /// A source's link-relevant fields.
    public struct SourceEntry: Sendable, Equatable {
        public let id: String
        public let filename: String
        /// Lowercased extension with no leading dot (`""` when the name has none).
        public let ext: String
        /// Best-effort MIME type; `nil` when unknown.
        public let mime: String?
        /// User-editable display name; `nil` falls back to `filename`.
        public let displayName: String?

        /// The name used for link resolution: display name if set, else filename.
        public var humanName: String { displayName ?? filename }

        public init(id: String, filename: String, ext: String,
                    mime: String?, displayName: String?) {
            self.id = id
            self.filename = filename
            self.ext = ext
            self.mime = mime
            self.displayName = displayName
        }
    }

    /// A chat's link-relevant fields.
    public struct ChatEntry: Sendable, Equatable {
        public let id: String
        public let title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    // MARK: - Raw entries

    /// All pages, in store iteration order (ULID-ascending).
    public let pages: [PageEntry]
    /// All sources, in store iteration order.
    public let sources: [SourceEntry]
    /// All chats, in store iteration order.
    public let chats: [ChatEntry]

    // MARK: - Pre-computed shared maps

    /// Lowercased source name variants (displayName, filename, and each with
    /// the path extension stripped) — the exact-match existence tier for the
    /// in-app reader's `isResolved` closure. Mirrors the variants the reader
    /// historically built inline.
    public let sourceLowerNameVariants: Set<String>

    /// Collision-free `looseMatchKey → humanName` map for sources. A key that
    /// two or more sources share is omitted (ambiguous → no match), mirroring
    /// `resolveSourceByName` pass 3 (unique-only constraint).
    ///
    /// The in-app reader derives `uniqueLooseKeys` as `Set(sourceByLooseKey.keys)`.
    /// The File Provider maps each humanName to its `RelativeLinkRewriter.Target`.
    public let sourceByLooseKey: [String: String]

    /// Collision-free `looseMatchKey → title` map for chats (same collision
    /// rule as `sourceByLooseKey`). The File Provider uses this for loose chat
    /// resolution; the in-app reader currently does not.
    public let chatByLooseKey: [String: String]

    /// Sibling-image maps: `sourceID → [originalPath → sibling sourceID]`.
    /// Both consumers consult these to rewrite relative image `src` attributes
    /// inside a source's own markdown.
    public let siblingImages: [PageID: [String: PageID]]

    // MARK: - Derived

    /// Loose-match keys unique across sources — the lenient tier mirroring
    /// `resolveSourceByName` pass 3. Equivalent to `Set(sourceByLooseKey.keys)`
    /// since a collision-free key is, by construction, unique.
    public var uniqueSourceLooseKeys: Set<String> {
        Set(sourceByLooseKey.keys)
    }

    // MARK: - Init

    /// Initialize with pre-built entries and pre-computed maps. Prefer
    /// ``WikiLinkIndex/build(pages:sources:chats:siblingImages:)`` which
    /// constructs the maps from the entries.
    public init(
        pages: [PageEntry],
        sources: [SourceEntry],
        chats: [ChatEntry],
        sourceLowerNameVariants: Set<String>,
        sourceByLooseKey: [String: String],
        chatByLooseKey: [String: String],
        siblingImages: [PageID: [String: PageID]]
    ) {
        self.pages = pages
        self.sources = sources
        self.chats = chats
        self.sourceLowerNameVariants = sourceLowerNameVariants
        self.sourceByLooseKey = sourceByLooseKey
        self.chatByLooseKey = chatByLooseKey
        self.siblingImages = siblingImages
    }

    // MARK: - Build (pure)

    /// Build a `WikiLinkIndex` from pre-fetched rows. Pure — performs no store
    /// access. Both `WikiRenderContext.build` and `Projection.makeLinkMaps`
    /// call this to share the normalization computation, then adapt the output
    /// to their own `Target` / existence-set shapes.
    public static func build(
        pages: [PageEntry],
        sources: [SourceEntry],
        chats: [ChatEntry],
        siblingImages: [PageID: [String: PageID]]
    ) -> WikiLinkIndex {
        // Lowercased source name variants (displayName, filename, ext-stripped).
        // Mirrors resolveSourceByName's fallback so a [[source:Paper]] link also
        // resolves against a source whose filename is "Paper.pdf".
        var sourceLowerNameVariants = Set<String>()
        for source in sources {
            let names = [source.displayName, source.filename].compactMap { $0 }
            let stripped = names.map { ($0 as NSString).deletingPathExtension }
            for name in (names + stripped).map({ $0.lowercased() }) {
                sourceLowerNameVariants.insert(name)
            }
        }

        // Source loose-key map: collision-free (unique-only), mirroring
        // resolveSourceByName pass 3 (unique-only).
        var sourceByLooseKey: [String: String] = [:]
        var seenSourceKeys = Set<String>()
        for source in sources {
            let key = WikiNameRules.looseMatchKey(source.humanName)
            if seenSourceKeys.contains(key) {
                sourceByLooseKey.removeValue(forKey: key)   // collision → ambiguous
            } else {
                seenSourceKeys.insert(key)
                sourceByLooseKey[key] = source.humanName
            }
        }

        // Chat loose-key map: same collision rule.
        var chatByLooseKey: [String: String] = [:]
        var seenChatKeys = Set<String>()
        for chat in chats {
            let key = WikiNameRules.looseMatchKey(chat.title)
            if seenChatKeys.contains(key) {
                chatByLooseKey.removeValue(forKey: key)
            } else {
                seenChatKeys.insert(key)
                chatByLooseKey[key] = chat.title
            }
        }

        return WikiLinkIndex(
            pages: pages,
            sources: sources,
            chats: chats,
            sourceLowerNameVariants: sourceLowerNameVariants,
            sourceByLooseKey: sourceByLooseKey,
            chatByLooseKey: chatByLooseKey,
            siblingImages: siblingImages
        )
    }
}
