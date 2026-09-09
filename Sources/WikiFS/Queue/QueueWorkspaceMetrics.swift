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
        /// is the only flexible child of the workspace's non-scrolling VStack
        /// (header + selector + content); without a floor, sibling demands
        /// (the optional Run Details inspector squeezing the center column at
        /// narrow widths) can starve the List to zero height and the workspace
        /// reads as a blank pane. The List always keeps at least this much
        /// scrollable region, whatever its siblings demand.
        static let minVisibleHeight: CGFloat = 96
        /// Vertical padding inside a target row (list rows own their height —
        /// no fixed-height text rows per plan).
        static let rowVerticalPadding: CGFloat = 5
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

    /// Run Details inspector panel geometry. The panel is an OPTIONAL
    /// trailing region inside the detail column — conditionally present, not
    /// a permanently visible third split-view column — opened and closed by
    /// the window toolbar's labeled toggle.
    enum Inspector {
        /// Fixed panel width. Wide enough for the longest fact pair
        /// (timestamp label + value) at callout size; narrow enough that the
        /// 640pt window minimum still leaves a visible center workspace next
        /// to the 220pt navigator minimum (640 − 220 − 280 = 140pt).
        static let width: CGFloat = 280
    }

    /// Recorded-outputs section bounds (ingestion Overview). The Outputs
    /// list is a bounded inventory, not a wiki enumeration: the store query
    /// stops at this row count (title order), so a wiki whose inputs are
    /// cited by huge numbers of pages still renders a finite section.
    enum Outputs {
        /// Row cap passed to `WikiStore.pagesCitingSources(limit:)`.
        static let maxRows = 200
    }
}
