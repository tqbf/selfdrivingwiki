#if os(macOS)
import CoreGraphics

// pattern: Functional Core

/// The height of a Settings table, in one place because a `Table` has no
/// intrinsic content size: SwiftUI cannot ask an `NSTableView`-backed table how
/// tall its rows are, so each pane has to compute it.
///
/// The height follows the row count between a floor and a ceiling. A short list
/// leaves no dead space under its rows, and a long one scrolls inside the
/// table's own scroll area rather than growing the Settings window.
enum SettingsTableMetrics {
    /// A row whose cells are text or labels.
    static let textRowHeight: CGFloat = 24
    /// A row whose cells hold a control. A `Picker` is taller than the text
    /// inside it and sets the row's height, so a table of pop-ups needs this
    /// instead — assuming the text height clips the last row out of view.
    static let controlRowHeight: CGFloat = 32
    static let headerHeight: CGFloat = 28
    /// A one-row table reads as a stray strip next to the action bar, so two
    /// rows is the floor even when only one package is installed.
    static let minimumVisibleRows = 2
    static let maximumVisibleRows = 8
    /// The empty state is a `ContentUnavailableView` with an image, a title,
    /// and a description. It needs more room than the row floor gives.
    static let emptyHeight: CGFloat = 148

    /// Both row heights are measured from a live pane's accessibility
    /// geometry, so a caller picks the one matching its cells rather than
    /// guessing a number.
    static func height(forRowCount count: Int, rowHeight: CGFloat = textRowHeight) -> CGFloat {
        guard count > 0 else { return emptyHeight }
        let visibleRows = min(max(count, minimumVisibleRows), maximumVisibleRows)
        return headerHeight + CGFloat(visibleRows) * rowHeight
    }
}
#endif
