import Foundation
import WikiFSCore

/// Display sort for the Chats sidebar list, mirroring the "Sort by" menu in
/// the Pages/Sources/Bookmarks sections. View-level only — the store's
/// `chats` array (native `ORDER BY updated_at DESC`) is never rewritten;
/// `.lastUpdated` is the default and reproduces that native order.
enum ChatSortOrder: String, CaseIterable, Sendable {
    /// Most recently updated first — the store's native order (default).
    /// `updatedAt` bumps on every message append, so this is
    /// "most recently active".
    case lastUpdated
    /// Most recently created first (`createdAt` descending).
    case newestFirst
    /// Displayed title, localized case-insensitive, A–Z. Uses the row's
    /// displayed title (`ChatsCellView.rowTitle`, empty → "New Chat") so the
    /// A–Z order matches what is on screen.
    case titleAZ

    /// Sorts the chat list for display. Pure; unit-tested without a live
    /// store. Equal keys tie-break on `id.rawValue` (a ULID, so monotonic
    /// by creation time) for a deterministic order — the same rule as
    /// `SourcesContainerView.SourceSortOrder`.
    nonisolated func sorted(_ chats: [ChatSummary]) -> [ChatSummary] {
        switch self {
        case .lastUpdated:
            return chats.sorted { a, b in
                if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
                return a.id.rawValue < b.id.rawValue
            }
        case .newestFirst:
            return chats.sorted { a, b in
                if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
                return a.id.rawValue < b.id.rawValue
            }
        case .titleAZ:
            return chats.sorted { a, b in
                let order = ChatsCellView.rowTitle(for: a)
                    .localizedCaseInsensitiveCompare(ChatsCellView.rowTitle(for: b))
                if order == .orderedSame { return a.id.rawValue < b.id.rawValue }
                return order == .orderedAscending
            }
        }
    }
}

/// Date-window "Show" filter for the Chats sidebar list, mirroring
/// `PagesContainerView.PageDateFilter`. Chats carry no kind dimension
/// (`ChatKind` has a single case), so activity recency — `updatedAt`,
/// bumped on every message append — is the filter axis. Display-only;
/// `now` and `calendar` are injectable so the predicate is unit-testable
/// without real time.
enum ChatDateFilter: String, CaseIterable, Sendable {
    case all
    case today
    case week
    case month

    func matches(
        _ date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        switch self {
        case .all: return true
        case .today: return calendar.isDate(date, equalTo: now, toGranularity: .day)
        case .week: return calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear)
        case .month: return calendar.isDate(date, equalTo: now, toGranularity: .month)
        }
    }

    /// Pure: chats whose `updatedAt` falls inside the window. `all`
    /// returns the input unchanged.
    func filtered(
        _ chats: [ChatSummary],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [ChatSummary] {
        guard self != .all else { return chats }
        return chats.filter { matches($0.updatedAt, now: now, calendar: calendar) }
    }
}
