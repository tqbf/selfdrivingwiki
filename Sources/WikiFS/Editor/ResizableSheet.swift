import AppKit
import SwiftUI

/// Makes the host window of a SwiftUI view user-resizable.
///
/// macOS `.sheet`s are presented in a backing `NSWindow` whose style mask omits
/// `.resizable`, so a flexible SwiftUI content frame alone never gives the user
/// drag-to-resize handles. This reaches that window once it exists and inserts
/// `.resizable`, plus a sane min/max content size, so the sheet can be dragged.
private struct ResizableWindowAccessor: NSViewRepresentable {
    let minSize: CGSize
    let maxSize: CGSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        applyWhenWindowAvailable(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Re-assert in case the sheet swapped/reset its window after first layout.
        applyWhenWindowAvailable(to: nsView)
    }

    private func applyWhenWindowAvailable(to view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.styleMask.insert(.resizable)
            window.contentMinSize = minSize
            window.contentMaxSize = maxSize
            window.minSize = minSize
        }
    }
}

extension View {
    /// Allow the host sheet/window to be resized between `minSize` and `maxSize`.
    func resizableHostWindow(
        minSize: CGSize,
        maxSize: CGSize = CGSize(width: 5000, height: 5000)
    ) -> some View {
        background(ResizableWindowAccessor(minSize: minSize, maxSize: maxSize))
    }
}
