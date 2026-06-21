import SwiftUI
import WikiFSCore

/// Injects four invisible keyboard-shortcut buttons that mutate a zoom scale
/// binding using Safari-parity chords:
///
/// - ⌘+  zoom in
/// - ⌘=  zoom in  (same key as ⌘+ without Shift — matches Safari)
/// - ⌘−  zoom out
/// - ⌘0  reset to default
///
/// The buttons are rendered as a zero-size overlay so they never affect layout
/// or appearance. They are kept fully transparent with `.opacity(0)` rather than
/// `.hidden()`: a `.hidden()` view is dropped from the responder chain, so
/// `.keyboardShortcut` events attached to it never fire. `.opacity(0)` keeps the
/// button live in the chain while invisible. Attach this modifier only to the
/// subtree that should own the chord (reader subtree → reader zoom; editor
/// subtree → editor zoom).
///
/// ```swift
/// TextEditor(...)
///     .zoomShortcuts($editorZoom)
///
/// MarkdownPreview(...)
///     .zoomShortcuts($readerZoom)
/// ```
extension View {
    func zoomShortcuts(_ scale: Binding<Double>) -> some View {
        self.overlay(ZoomShortcutButtons(scale: scale).frame(width: 0, height: 0))
    }
}

// MARK: - Private implementation

/// Four invisible buttons that own the zoom keyboard shortcuts.
///
/// Placed in a zero-size frame so they never occupy layout space. Each button is
/// additionally `.opacity(0)` and `.accessibilityHidden(true)` so it is invisible
/// and not announced to VoiceOver. `.opacity(0)` (not `.hidden()`) is load-bearing:
/// a hidden view is removed from the responder chain, which silently prevents its
/// `.keyboardShortcut` from ever firing.
private struct ZoomShortcutButtons: View {
    @Binding var scale: Double

    var body: some View {
        // Group keeps the four buttons as a single opaque View while remaining
        // transparent to layout — each button is individually .opacity(0) and
        // .accessibilityHidden so it never shows or is announced, yet stays in
        // the responder chain so its keyboard shortcut fires.
        Group {
            // ⌘+ — zoom in (requires Shift on most keyboards)
            Button("Zoom In") { zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)

            // ⌘= — zoom in without Shift (the physical key Safari uses)
            Button("Zoom In") { zoomIn() }
                .keyboardShortcut("=", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)

            // ⌘− — zoom out
            Button("Zoom Out") { zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)

            // ⌘0 — reset
            Button("Reset Zoom") { reset() }
                .keyboardShortcut("0", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Actions (convert at the Double/CGFloat boundary here)

    private func zoomIn() {
        scale = Double(ZoomScale.zoomedIn(CGFloat(scale)))
    }

    private func zoomOut() {
        scale = Double(ZoomScale.zoomedOut(CGFloat(scale)))
    }

    private func reset() {
        scale = Double(ZoomScale.defaultScale)
    }
}
