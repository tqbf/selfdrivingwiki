import AppKit

/// Shows an `NSSharingServicePicker` anchored at the current mouse location over
/// the key window's content view. Shared by the pages and sources sidebar
/// tables (single + batch share) — formerly inlined 4× (pages single/batch,
/// sources single/batch).
@MainActor
enum SidebarSharing {
    static func present(items: [Any]) {
        guard !items.isEmpty,
              let window = NSApplication.shared.keyWindow,
              let contentView = window.contentView else { return }
        let picker = NSSharingServicePicker(items: items)
        let mouseScreen = NSEvent.mouseLocation
        let windowPoint = window.convertPoint(fromScreen: mouseScreen)
        let viewPoint = contentView.convert(windowPoint, from: nil)
        picker.show(
            relativeTo: NSRect(origin: viewPoint, size: NSSize(width: 1, height: 1)),
            of: contentView, preferredEdge: .minY)
    }
}
