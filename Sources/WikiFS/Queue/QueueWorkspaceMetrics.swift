import CoreGraphics

/// Centralized geometry for the queue workspace components (plan §1 "Centralize
/// spacing and width metrics"). Values only — no view logic — so both windows
/// (Agent Queue, Extraction Queue) and their hosted tests read identical numbers
/// from one place. Mirrors the `PageEditorMetrics` / `SettingsTableMetrics`
/// pattern.
///
/// Spacing follows the plan's restrained 8/12/16/24-point scale; the navigator
/// and window bounds are the plan's layout contract values (usable at the
/// existing 640×400 minimum, preferred new-window size 1040×720).
enum QueueWorkspaceMetrics {
    /// The only horizontal/vertical paddings and gaps the workspace uses.
    enum Spacing {
        /// Row-internal gaps: symbol ↔ text, stacked meta lines.
        static let xs: CGFloat = 8
        /// Group gaps: status block ↔ reason text, action button spacing.
        static let sm: CGFloat = 12
        /// Section insets: header/overview horizontal padding.
        static let md: CGFloat = 16
        /// Region separation: header ↔ content selector ↔ inventory.
        static let lg: CGFloat = 24
    }

    /// Job-navigator sidebar column widths (plan: minimum 220, ideal 280,
    /// maximum 360). The parent `NavigationSplitView` reads these; kept here so
    /// the contract lives with the rest of the workspace geometry.
    enum Navigator {
        static let minWidth: CGFloat = 220
        static let idealWidth: CGFloat = 280
        static let maxWidth: CGFloat = 360
    }

    /// Window sizing: the existing usability minimum and the plan's preferred
    /// new-window size. Restored frames still win over the preferred size.
    enum Window {
        static let minWidth: CGFloat = 640
        static let minHeight: CGFloat = 400
        static let preferredWidth: CGFloat = 1040
        static let preferredHeight: CGFloat = 720
    }

    /// Target-inventory list geometry.
    enum Inventory {
        /// Rows at or above this count surface the local inventory search field.
        /// Below it every target is visible at once and search is noise.
        static let localSearchThreshold = 12
        /// The inventory's visible height floor. The Overview's scrolling List
        /// is the only flexible child of a non-scrolling VStack that also
        /// carries the pinned Run Details disclosure; without a floor, an
        /// expanded disclosure starves the List to zero height and the
        /// workspace reads as a blank pane. The List always keeps at least
        /// this much scrollable region, whatever the disclosure demands.
        static let minVisibleHeight: CGFloat = 96
        /// Vertical padding inside a target row (list rows own their height —
        /// no fixed-height text rows per plan).
        static let rowVerticalPadding: CGFloat = 5
        /// Left indent of a row's expanded full-name/reason/actions block so it
        /// reads as belonging to the row's text column, not the status symbol.
        static let disclosedIndent: CGFloat = 28
        /// Line count a row title wraps to before truncating (plan: long names
        /// wrap to two lines).
        static let titleLineLimit = 2
    }

    /// Selected-job header bounds so large error text cannot push all workspace
    /// content off-window (plan: bound header and expanded metadata).
    enum Header {
        static let errorLineLimit = 4
        static let titleLineLimit = 2
        /// Gap between the title block and the wrapped action row in the
        /// narrow (stacked) layout.
        static let actionRowTopSpacing: CGFloat = Spacing.sm
        /// Vertical inset of the header's content, matching the transcript's
        /// 16pt horizontal inset.
        static let verticalPadding: CGFloat = 10
    }

    /// Run Details disclosure bounds. The disclosure is pinned BELOW the
    /// inventory List inside the Overview's non-scrolling VStack (plan §1),
    /// so its expanded content must never demand unbounded height: an
    /// uncapped Grid starves the flexible List to zero height (the blank
    /// workspace pane) and pushes the workspace's ideal height past the
    /// window, which also collapses the sidebar's window-toolbar inset
    /// (#835) — sidebar rows then scroll under the traffic lights.
    enum RunDetails {
        /// Ceiling for the disclosure's expanded region. Taller grids scroll
        /// inside it instead of growing the demand.
        static let maxExpandedHeight: CGFloat = 320
    }
}
