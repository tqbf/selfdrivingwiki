import Foundation

/// One wiki's registry entry: an independent knowledge base (its own SQLite DB
/// and File Provider domain). The smallest stable identity the multi-wiki
/// foundation needs (`plans/llm-wiki.md` Phase 0).
///
/// **Identity is the ULID `id`, never `displayName`.** The DB filename and the
/// File Provider domain identifier both derive from `id`, so a rename changes
/// only the human label — the on-disk file and the mount keep working. This is
/// the doc's explicit open-risk ("Wiki identity must be stable — survive
/// rename"); encoding it in `dbFileName`/`domainIdentifier` makes drift
/// impossible by construction.
public struct WikiDescriptor: Codable, Identifiable, Equatable, Sendable {
    /// The wiki's stable ULID. Lexicographically sortable == creation order.
    public let id: String

    /// Human-facing label, shown in the switcher and used to name the Finder
    /// mount (`~/Library/CloudStorage/Self Driving Wiki-<displayName>`). Mutable — a rename
    /// changes ONLY this, never `id`.
    public var displayName: String

    /// When the wiki was created (the ULID also encodes this, kept explicit for
    /// display + stable decoding).
    public let createdAt: Date

    /// Last time the wiki was selected — drives "most-recently-used" ordering in
    /// the switcher and which wiki the app opens on launch.
    public var lastUsedAt: Date

    /// The page this wiki's home button navigates to. `nil` means no home page
    /// has been set (the button is hidden). References a page's stable ID, not
    /// its title, so a page rename doesn't orphan the setting.
    public var homePageID: PageID?

    public init(id: String, displayName: String, createdAt: Date, lastUsedAt: Date, homePageID: PageID? = nil) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.homePageID = homePageID
    }

    /// Mint a fresh descriptor with a new ULID. `createdAt`/`lastUsedAt` are the
    /// same instant the ULID encodes.
    public static func make(displayName: String, now: Date = Date()) -> WikiDescriptor {
        WikiDescriptor(
            id: ULID.generate(at: now),
            displayName: displayName,
            createdAt: now,
            lastUsedAt: now
        )
    }

    /// The SQLite filename for this wiki, derived from the ULID — NEVER the
    /// display name (so a rename doesn't orphan the file). `<ulid>.sqlite`.
    public var dbFileName: String { "\(id).sqlite" }

    /// The File Provider domain identifier for this wiki: the bare ULID. The
    /// extension maps `domain.identifier` → `<ulid>.sqlite` with no registry
    /// read, so this string and `dbFileName` must stay in lockstep — both are
    /// `id`, by construction.
    public var domainIdentifier: String { id }
}
