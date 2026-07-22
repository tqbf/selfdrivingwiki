import Foundation

/// Pure layout math for the tab strip: given how many tabs are open and how much
/// horizontal room there is, decide how wide each visible tab should be, how many
/// fit, and whether an overflow ("show all tabs") menu is needed.
///
/// Lives in Core (no SwiftUI) so the fit/overflow arithmetic — the part prone to
/// off-by-one — is unit-testable without a running view.
///
/// Uses `Double` rather than `Double` so this file is portable across macOS and
/// Linux (Linux's CoreGraphics availability is inconsistent across toolchains;
/// `Double` is always available and is identical to `Double` on 64-bit).
public struct TabBarLayout: Equatable, Sendable {
    /// Width each *visible* tab is drawn at (uniform).
    public let tabWidth: Double
    /// How many tabs (from the left) are drawn in the strip.
    public let visibleCount: Int
    /// Whether to draw the overflow chevron menu after the visible tabs.
    public let showsOverflow: Bool

    public init(tabWidth: Double, visibleCount: Int, showsOverflow: Bool) {
        self.tabWidth = tabWidth
        self.visibleCount = visibleCount
        self.showsOverflow = showsOverflow
    }

    /// - Parameters:
    ///   - tabCount: number of open tabs.
    ///   - availableWidth: room for the tabs (already net of the strip's own
    ///     horizontal padding).
    ///   - minTabWidth / maxTabWidth: the per-tab width clamp. Tabs shrink from
    ///     `maxTabWidth` toward `minTabWidth` as more open.
    ///   - overflowWidth: width reserved for the chevron menu when overflowing.
    public static func compute(
        tabCount: Int,
        availableWidth: Double,
        minTabWidth: Double,
        maxTabWidth: Double,
        overflowWidth: Double
    ) -> TabBarLayout {
        guard tabCount > 0, availableWidth > 0 else {
            return TabBarLayout(tabWidth: maxTabWidth, visibleCount: 0, showsOverflow: false)
        }
        // Do all tabs fit at (at least) the minimum width? If so, share the room
        // evenly, clamped to [min, max] — few tabs sit at max, more tabs shrink.
        if Double(tabCount) * minTabWidth <= availableWidth {
            let width = min(maxTabWidth, max(minTabWidth, availableWidth / Double(tabCount)))
            return TabBarLayout(tabWidth: width, visibleCount: tabCount, showsOverflow: false)
        }
        // Overflow: reserve the chevron's width, then fit as many min-width tabs
        // as remain. Always show at least one tab.
        let widthForTabs = max(0, availableWidth - overflowWidth)
        let fit = max(1, Int((widthForTabs / minTabWidth).rounded(.down)))
        let visible = min(fit, tabCount)
        return TabBarLayout(
            tabWidth: minTabWidth,
            visibleCount: visible,
            showsOverflow: visible < tabCount)
    }
}
