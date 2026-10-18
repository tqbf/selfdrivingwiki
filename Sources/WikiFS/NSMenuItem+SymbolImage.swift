import AppKit

/// Sets an SF Symbol image on a menu item and forces it to render.
///
/// Apps linked against the macOS 27 SDK hide menu-item symbol images by
/// default — Apple's release notes: "By default, `NSMenu` hides all menu
/// item symbol images — non-symbol images remain visible." That default is
/// why the sidebar context menus rendered without icons. The sidebar menu
/// builders route every symbol image through this helper so the icon shows
/// on macOS 27 and newer; on macOS 26 the visibility property does not
/// exist and the symbols stay hidden, as before.
extension NSMenuItem {
    func setSymbolImage(_ systemImage: String) {
        image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        if #available(macOS 27.0, *) {
            preferredImageVisibility = .visible
        }
    }
}
