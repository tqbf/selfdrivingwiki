import Foundation

/// The result of `WikiStore.saveWikiStrategy(name:instructions:expectedRevision:)`.
public enum WikiStrategySaveOutcome: Equatable, Sendable {
    /// A changed write committed: the revision advanced by exactly one and
    /// exactly one `ResourceChangeEvent` (kind `.strategy`) was emitted.
    ///
    /// `strategy` is the committed strategy, or `nil` when the save reset the
    /// wiki to the Default strategy (whitespace-only instructions) — the row
    /// is then a tombstone that keeps `revision` for the next save.
    case saved(revision: WikiStrategyRevision, strategy: WikiStrategy?)

    /// The committed state already equals the request. Nothing was written,
    /// the revision did not advance, and **no event was emitted**.
    case unchanged
}
