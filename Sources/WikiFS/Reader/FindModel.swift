import Foundation
import Observation

/// Reactive find state shared between the find bar and the content view.
/// Drives the find bar UI (search field, match count, next/prev) and exposes
/// the current match range so the content view can scroll to / highlight it.
@MainActor
@Observable
public final class FindModel {

    /// Current search text typed in the find bar.
    public var query = ""

    /// Case-sensitive toggle.
    public var caseSensitive = false

    /// Whether the find bar is visible. Cmd+F toggles.
    public var isShowing = false

    /// All match ranges found in the current content.
    private(set) public var matches: [Range<String.Index>] = []

    /// 1-based index into `matches` (0 when no matches).
    private(set) public var currentMatchIndex = 0

    /// The content text being searched. Set by the owning detail view before
    /// the find bar opens. When `nil`, find is a no-op (no content to search).
    public var content: String?

    /// Callback the content view sets to scroll to / select a given match
    /// (usually the range within the source markdown string that the view is
    /// rendering). The caller maps the character range to a view scroll position.
    public var onNavigateToMatch: ((Range<String.Index>) -> Void)?

    // MARK: - Navigation

    public func nextMatch() {
        guard !matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex % matches.count) + 1
        notifyCurrentMatch()
    }

    public func previousMatch() {
        guard !matches.isEmpty else { return }
        currentMatchIndex = currentMatchIndex <= 1 ? matches.count : currentMatchIndex - 1
        notifyCurrentMatch()
    }

    public func toggle() {
        isShowing.toggle()
        if isShowing { performFind() }
        else { clear() }
    }

    public func dismiss() {
        isShowing = false
        clear()
    }

    // MARK: - Count display string

    /// "2 of 14" when matches exist, or "0 matches" when query is non-empty with
    /// no results, or empty for an empty query.
    public var countLabel: String {
        if query.isEmpty { return "" }
        if matches.isEmpty { return "0 matches" }
        return "\(currentMatchIndex) of \(matches.count)"
    }

    /// Called by FindBarView when query or case sensitivity changes, or when
    /// content is set by the owning detail view. Re-runs the search.
    public func search() { performFind() }

    // MARK: - Private

    private func performFind() {
        guard let content, !query.isEmpty else {
            matches = []
            currentMatchIndex = 0
            return
        }
        let options: NSString.CompareOptions = caseSensitive
            ? [.literal]
            : [.caseInsensitive]
        var found: [Range<String.Index>] = []
        var searchStart = content.startIndex
        while let range = content.range(of: query, options: options, range: searchStart..<content.endIndex) {
            found.append(range)
            searchStart = range.upperBound
        }
        matches = found
        currentMatchIndex = found.isEmpty ? 0 : 1
        if !found.isEmpty { notifyCurrentMatch() }
    }

    private func notifyCurrentMatch() {
        guard currentMatchIndex > 0, currentMatchIndex <= matches.count else { return }
        onNavigateToMatch?(matches[currentMatchIndex - 1])
    }

    private func clear() {
        matches = []
        currentMatchIndex = 0
    }
}
