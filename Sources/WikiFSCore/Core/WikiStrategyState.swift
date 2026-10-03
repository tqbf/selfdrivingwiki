import Foundation

/// One consistent snapshot of the committed strategy singleton: the strategy
/// document **and** its revision counter, read atomically in a single store
/// read.
///
/// This is the read an **editor** loads before offering a save. Reading
/// `getWikiStrategy()` and `wikiStrategyRevision()` as two separate calls can
/// straddle a concurrent write — associating an old body with a new revision —
/// which would hand the save a compare-and-swap expectation that passes while
/// the draft was built from stale content. `getWikiStrategyState()` returns
/// both values from one committed row, so that pair can never disagree.
///
/// `saveExpectation` is the exact value to pass as
/// `WikiStore.saveWikiStrategy(name:instructions:expectedRevision:)`'s
/// `expectedRevision`:
/// - live strategy → its revision;
/// - Default via tombstone → the tombstone's retained revision;
/// - never written → `nil` (true absence).
public struct WikiStrategyState: Equatable, Sendable {
    /// The committed strategy, or `nil` when the wiki uses the Default
    /// strategy (absent row or reset tombstone).
    public let strategy: WikiStrategy?

    /// The committed row revision: `nil` when no row has ever been written,
    /// otherwise the live strategy's revision or a tombstone's retained one.
    /// When `strategy` is non-nil this equals `strategy?.revision`.
    public let revision: WikiStrategyRevision?

    public init(strategy: WikiStrategy?, revision: WikiStrategyRevision?) {
        self.strategy = strategy
        self.revision = revision
    }

    /// The compare-and-swap expectation derived from this snapshot. Pass it
    /// as the save's `expectedRevision`; a mismatch means another editor
    /// committed since this state was read.
    public var saveExpectation: WikiStrategyRevision? {
        strategy?.revision ?? revision
    }
}
