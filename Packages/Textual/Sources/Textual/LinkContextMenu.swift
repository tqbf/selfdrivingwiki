import SwiftUI

// MARK: - Overview
//
// Right-click link context menus.
//
// Textual owns the text view's right-click handling. These types let the host
// app contribute link-specific menu items: set a builder via
// `.textual.linkContextMenu { url in [...] }`. When the user right-clicks a
// link, Textual selects the whole link run and builds the context menu from the
// builder's items (followed by the existing Share/Copy items when there is a
// text selection). See the host app's `plans/link-context-menus.md`.

/// A single item in a right-click link context menu.
///
/// Build items with ``LinkMenuItem/item(_:isEnabled:submenu:action:)`` or
/// ``LinkMenuItem/separator``, and return them from a
/// ``LinkContextMenuBuilder``.
public struct LinkMenuItem: Sendable {
  private(set) var isSeparator = false
  public var title: String = ""
  public var isEnabled: Bool = true
  public var submenu: [LinkMenuItem]?
  var action: (@MainActor () -> Void)?

  private init() {}

  /// A separator line between groups of items.
  public static let separator: LinkMenuItem = {
    var item = LinkMenuItem()
    item.isSeparator = true
    item.isEnabled = false
    return item
  }()

  /// A clickable menu item.
  ///
  /// - Parameters:
  ///   - title: The item's localized title.
  ///   - isEnabled: Whether the item is enabled. Defaults to `true`.
  ///   - submenu: An optional submenu of further items. When non-empty, the item
  ///     acts as a submenu parent and `action` is ignored.
  ///   - action: The main-actor action to run when the item is chosen.
  public static func item(
    _ title: String,
    isEnabled: Bool = true,
    submenu: [LinkMenuItem]? = nil,
    action: @escaping @MainActor () -> Void = {}
  ) -> LinkMenuItem {
    var item = LinkMenuItem()
    item.title = title
    item.isEnabled = isEnabled
    item.submenu = submenu
    item.action = action
    return item
  }
}

/// Builds the items for a right-click link context menu from the link's URL.
///
/// The closure is invoked on the main actor when the user right-clicks a link.
/// Return the items to show, or an empty array for none. The type is
/// `@unchecked Sendable` because the builder is only ever invoked on the main
/// actor (AppKit's context-menu path); the closure may capture main-actor-
/// isolated app state such as an `@Observable` model.
public struct LinkContextMenuBuilder: @unchecked Sendable {
  private let build: @MainActor (URL) -> [LinkMenuItem]

  public init(_ build: @escaping @MainActor (URL) -> [LinkMenuItem]) {
    self.build = build
  }

  @MainActor public func callAsFunction(_ url: URL) -> [LinkMenuItem] {
    build(url)
  }
}

#if TEXTUAL_ENABLE_TEXT_SELECTION
  // Manual EnvironmentKey (rather than `@Entry`) so the value is `public` and
  // settable from the host app module.
  private enum LinkContextMenuKey: EnvironmentKey {
    static let defaultValue: LinkContextMenuBuilder? = nil
  }

  extension EnvironmentValues {
    /// When set, right-clicking a link shows a link-specific context menu built
    /// from the returned items (in addition to Share/Copy when text is selected).
    public var linkContextMenu: LinkContextMenuBuilder? {
      get { self[LinkContextMenuKey.self] }
      set { self[LinkContextMenuKey.self] = newValue }
    }
  }
#endif
