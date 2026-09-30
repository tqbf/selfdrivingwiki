#if os(macOS)
import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSCore

/// Tests for `ChatSortOrder.sorted` and `ChatDateFilter.filtered` — the pure
/// display sort and date-window filter for the Chats sidebar list.
/// `lastUpdated` is the store's native `ORDER BY updated_at DESC` order and
/// the default; equal keys tie-break on `id.rawValue` (a ULID, monotonic by
/// creation time).
@Suite struct ChatsSortFilterTests {

    private func chat(
        _ id: String,
        title: String,
        createdAt: Date,
        updatedAt: Date
    ) -> ChatSummary {
        ChatSummary(
            id: ChatID(rawValue: id),
            kind: .edit,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            messageCount: 1)
    }

    private static let epoch = Date(timeIntervalSince1970: 0)

    // MARK: - Sort

    @Test func lastUpdatedSortsByUpdatedAtDescending() {
        let chats = [
            chat("a", title: "Alpha", createdAt: Self.epoch, updatedAt: Date(timeIntervalSince1970: 100)),
            chat("b", title: "Beta", createdAt: Self.epoch, updatedAt: Date(timeIntervalSince1970: 300)),
            chat("c", title: "Gamma", createdAt: Self.epoch, updatedAt: Date(timeIntervalSince1970: 200)),
        ]
        let result = ChatSortOrder.lastUpdated.sorted(chats)
        #expect(result.map { $0.id.rawValue } == ["b", "c", "a"])
    }

    @Test func newestFirstSortsByCreatedAtDescending() {
        let chats = [
            chat("a", title: "Alpha", createdAt: Date(timeIntervalSince1970: 100), updatedAt: Self.epoch),
            chat("b", title: "Beta", createdAt: Date(timeIntervalSince1970: 300), updatedAt: Self.epoch),
            chat("c", title: "Gamma", createdAt: Date(timeIntervalSince1970: 200), updatedAt: Self.epoch),
        ]
        let result = ChatSortOrder.newestFirst.sorted(chats)
        #expect(result.map { $0.id.rawValue } == ["b", "c", "a"])
    }

    @Test func titleAZSortsByDisplayedTitleCaseInsensitively() {
        // The empty title renders as "New Chat" (`ChatsCellView.rowTitle`),
        // so it sorts there — between "Alpha" and "zeta" — not under "".
        let chats = [
            chat("z", title: "zeta", createdAt: Self.epoch, updatedAt: Self.epoch),
            chat("empty", title: "", createdAt: Self.epoch, updatedAt: Self.epoch),
            chat("a", title: "Alpha", createdAt: Self.epoch, updatedAt: Self.epoch),
        ]
        let result = ChatSortOrder.titleAZ.sorted(chats)
        #expect(result.map { $0.id.rawValue } == ["a", "empty", "z"])
    }

    @Test func equalUpdatedAtTieBreaksOnID() {
        let stamp = Date(timeIntervalSince1970: 500)
        let chats = [
            chat("b", title: "Beta", createdAt: Self.epoch, updatedAt: stamp),
            chat("a", title: "Alpha", createdAt: Self.epoch, updatedAt: stamp),
        ]
        let result = ChatSortOrder.lastUpdated.sorted(chats)
        #expect(result.map { $0.id.rawValue } == ["a", "b"])
    }

    @Test func lastUpdatedMatchesStoreOrder() {
        // The default order must reproduce the store's
        // `ORDER BY updated_at DESC` exactly — today's behavior.
        let chats = [
            chat("old", title: "Old", createdAt: Self.epoch, updatedAt: Date(timeIntervalSince1970: 10)),
            chat("new", title: "New", createdAt: Self.epoch, updatedAt: Date(timeIntervalSince1970: 90)),
            chat("mid", title: "Mid", createdAt: Self.epoch, updatedAt: Date(timeIntervalSince1970: 50)),
        ]
        let result = ChatSortOrder.lastUpdated.sorted(chats)
        #expect(result.map { $0.id.rawValue } == ["new", "mid", "old"])
    }

    // MARK: - Date filter

    /// Fixed reference: Saturday 2026-09-19 12:00 UTC.
    /// Gregorian, firstWeekday = Sunday → the week started Sunday 09-13.
    private static let now: Date = date(2026, 9, 19, 12)
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func date(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12
    ) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private var chats: [ChatSummary] {
        [
            chat("now", title: "Now", createdAt: Self.epoch, updatedAt: Self.now),          // today
            chat("yesterday", title: "Y", createdAt: Self.epoch, updatedAt: Self.date(2026, 9, 18)),  // same week
            chat("three-days", title: "T", createdAt: Self.epoch, updatedAt: Self.date(2026, 9, 16)), // same week
            chat("prev-week", title: "P", createdAt: Self.epoch, updatedAt: Self.date(2026, 9, 12)),  // prev week, same month
            chat("prev-month", title: "M", createdAt: Self.epoch, updatedAt: Self.date(2026, 8, 10)), // prev month
        ]
    }

    private func filtered(_ filter: ChatDateFilter) -> [String] {
        filter.filtered(chats, now: Self.now, calendar: Self.calendar).map { $0.id.rawValue }
    }

    @Test func allReturnsInputUnchanged() {
        #expect(filtered(.all) == ["now", "yesterday", "three-days", "prev-week", "prev-month"])
    }

    @Test func todayKeepsOnlyToday() {
        #expect(filtered(.today) == ["now"])
    }

    @Test func weekKeepsThisWeekOnly() {
        // Sep 13–19 (Sunday-start week): today, yesterday, and three days ago
        // are in; Sep 12 (previous week) and Aug 10 are out.
        #expect(filtered(.week) == ["now", "yesterday", "three-days"])
    }

    @Test func monthKeepsThisMonthOnly() {
        // September: includes the previous-week chat, excludes August.
        #expect(filtered(.month) == ["now", "yesterday", "three-days", "prev-week"])
    }

    @Test func updatedAtExactlyNowMatchesEveryWindow() {
        let one = [chat("edge", title: "Edge", createdAt: Self.epoch, updatedAt: Self.now)]
        for filter in ChatDateFilter.allCases {
            #expect(filter.filtered(one, now: Self.now, calendar: Self.calendar).count == 1)
        }
    }
}
#endif
