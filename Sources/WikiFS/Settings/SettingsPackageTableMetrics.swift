#if os(macOS)
import CoreGraphics

// pattern: Functional Core

/// The height of a Settings package table, in one place because a `Table` has
/// no intrinsic content size: SwiftUI cannot ask an `NSTableView`-backed table
/// how tall its rows are, so each pane has to compute it.
///
/// The height follows the row count between a floor and a ceiling. A short list
/// leaves no dead space under its rows, and a long one scrolls inside the
/// table's own scroll area rather than growing the Settings window.
///
/// Shared by the renderer and extractor package tables: both are the same
/// control at the same control size, so the geometry has one definition.
enum SettingsPackageTableMetrics {
    /// One `Table` row at the regular control size, and the header above the
    /// rows. Both are measured from a live pane's accessibility geometry.
    static let rowHeight: CGFloat = 24
    static let headerHeight: CGFloat = 28
    /// A one-row table reads as a stray strip next to the action bar, so two
    /// rows is the floor even when only one package is installed.
    static let minimumVisibleRows = 2
    static let maximumVisibleRows = 8
    /// The empty state is a `ContentUnavailableView` with an image, a title,
    /// and a description. It needs more room than the row floor gives.
    static let emptyHeight: CGFloat = 148

    static func height(forRowCount count: Int) -> CGFloat {
        guard count > 0 else { return emptyHeight }
        let visibleRows = min(max(count, minimumVisibleRows), maximumVisibleRows)
        return headerHeight + CGFloat(visibleRows) * rowHeight
    }
}
#endif
