import Foundation

/// Thrown by `WikiStore.saveWikiStrategy(name:instructions:expectedRevision:)`
/// when the compare-and-swap check fails: another editor committed since the
/// caller read. The write throws **before** any row changes — a conflict
/// leaves no trace. Carries the committed winner so the caller can offer
/// Reload without discarding the local draft.
public struct WikiStrategyConflictError: Error, Equatable {
    /// The revision the caller expected to write on top of; `nil` = the
    /// caller read a wiki where no strategy row had ever been written.
    public let expectedRevision: WikiStrategyRevision?

    /// The actually committed row revision at the failed write; `nil` = the
    /// row is still absent (the caller expected a revision that never was).
    public let currentRevision: WikiStrategyRevision?

    /// The committed strategy the caller's save would have overwritten;
    /// `nil` = the wiki is currently at the Default strategy.
    public let currentStrategy: WikiStrategy?

    public init(
        expectedRevision: WikiStrategyRevision?,
        currentRevision: WikiStrategyRevision?,
        currentStrategy: WikiStrategy?
    ) {
        self.expectedRevision = expectedRevision
        self.currentRevision = currentRevision
        self.currentStrategy = currentStrategy
    }
}
