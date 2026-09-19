#if os(macOS)
import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSCore

/// Tests for `PagesContainerView.PageDateFilter` — the pure "Show"
/// date-window filter for the Pages sidebar list (All / Edited Today /
/// This Week / This Month, display-only). `now` and `calendar` are
/// injected so the windows are tested against fixed dates.
@Suite struct PagesDateFilterTests {

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

    private func page(_ id: String, updatedAt: Date) -> WikiPageSummary {
        WikiPageSummary(id: PageID(rawValue: id), title: id, updatedAt: updatedAt, createdAt: Self.epoch)
    }

    private static let epoch = Date(timeIntervalSince1970: 0)

    private var pages: [WikiPageSummary] {
        [
            page("now", updatedAt: Self.now),                                // today
            page("yesterday", updatedAt: Self.date(2026, 9, 18)),            // same week
            page("three-days", updatedAt: Self.date(2026, 9, 16)),           // same week
            page("prev-week", updatedAt: Self.date(2026, 9, 12)),            // prev week, same month
            page("prev-month", updatedAt: Self.date(2026, 8, 10)),           // prev month
        ]
    }

    private func filtered(_ filter: PagesContainerView.PageDateFilter) -> [String] {
        filter.filtered(pages, now: Self.now, calendar: Self.calendar).map { $0.id.rawValue }
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
        // September: includes the previous-week page, excludes August.
        #expect(filtered(.month) == ["now", "yesterday", "three-days", "prev-week"])
    }

    @Test func updatedAtExactlyNowMatchesEveryWindow() {
        let page = [page("edge", updatedAt: Self.now)]
        for filter in PagesContainerView.PageDateFilter.allCases {
            #expect(filter.filtered(page, now: Self.now, calendar: Self.calendar).count == 1)
        }
    }
}
#endif
