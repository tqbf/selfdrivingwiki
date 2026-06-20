import CoreGraphics

/// Centralized layout constants for the page reading/editing surfaces
/// (SWIFTUI-RULES §2.4 — no scattered magic numbers).
enum PageEditorMetrics {
    static let sidebarMinWidth: CGFloat = 200
    static let sidebarIdealWidth: CGFloat = 260
    static let detailMinWidth: CGFloat = 420
    static let readableContentWidth: CGFloat = 760

    /// Padding around the article / editor content.
    static let contentInset: CGFloat = 12
    /// Vertical gap between the title field, the editor, and the preview.
    static let sectionSpacing: CGFloat = 12
    /// Minimum height for the markdown editor before the preview takes over.
    static let editorMinHeight: CGFloat = 160
    static let previewMinHeight: CGFloat = 120
    static let dividerOpacity: Double = 0.5
}
