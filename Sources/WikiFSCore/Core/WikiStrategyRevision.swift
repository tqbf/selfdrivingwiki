import Foundation

/// The revision counter of a wiki's strategy document
/// (`wiki_strategy`, the per-wiki editorial singleton).
///
/// The revision is **monotonic for the lifetime of the wiki**: every changed
/// save — including a save that resets the wiki back to the Default strategy —
/// advances it by exactly one, and nothing ever moves it backwards. A reset
/// does not delete the row; it keeps a tombstone row so the counter survives
/// (see `WikiStore.saveWikiStrategy(name:instructions:expectedRevision:)`).
///
/// `rawValue` is the SQLite-stored `INTEGER`. `0` is the floor, used by the
/// change-token fold for "no strategy row has ever been written"; the first
/// committed save writes revision `1`.
///
/// Compare-and-swap expectations use `WikiStrategyRevision?`:
/// - `nil` — the editor read a wiki where **no row has ever been written**
///   (true absence, not a reset tombstone).
/// - `.some(revision)` — the editor read exactly this committed revision,
///   whether that revision holds a live strategy or a Default tombstone.
///
/// This keeps one comparison rule at the write boundary: the expected value
/// must equal the committed row's revision exactly, with `nil` matching only
/// an absent row (`plans/wiki-strategies-and-cumulative-ingestion.md`).
public struct WikiStrategyRevision: RawRepresentable, Hashable, Sendable, Codable {
    /// The committed revision number. Non-negative; `0` only as the floor.
    public let rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    /// The never-written floor. A committed row never stores this value; the
    /// change-token fold uses it when the `wiki_strategy` table has no row.
    public static let absent = WikiStrategyRevision(rawValue: 0)

    /// The revision a changed save commits after this one.
    public var next: WikiStrategyRevision {
        WikiStrategyRevision(rawValue: rawValue + 1)
    }
}

extension WikiStrategyRevision: CustomStringConvertible {
    public var description: String { "WikiStrategyRevision(\(rawValue))" }
}
