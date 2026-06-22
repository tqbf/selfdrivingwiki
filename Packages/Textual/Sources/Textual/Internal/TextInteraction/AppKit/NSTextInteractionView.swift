#if TEXTUAL_ENABLE_TEXT_SELECTION && canImport(AppKit) && !targetEnvironment(macCatalyst)
  import SwiftUI

  // MARK: - Overview
  //
  // `NSTextInteractionView` implements selection and link interaction on macOS.
  //
  // The view sits in an overlay above one or more rendered `Text` fragments. It uses
  // `TextSelectionModel` for hit testing and range manipulation, and it respects `exclusionRects`
  // so embedded scrollable regions continue to receive input events. Link taps are forwarded to
  // `openURL`.

  final class NSTextInteractionView: NSView {
    var model: TextSelectionModel
    var exclusionRects: [CGRect]
    var openURL: OpenURLAction
    var linkContextMenu: LinkContextMenuBuilder?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var dragStart: TextPosition?
    private var selectionAnchor: TextPosition?

    // The location of the most recent right-click, so `makeContextMenu` can
    // resolve the link (if any) under the cursor.
    private var lastContextMenuLocation: CGPoint?
    // Strong references to the closure-backed menu-item targets for the menu
    // currently being built (NSMenuItem.target is weak).
    private var menuItemTargets: [LinkMenuItemTarget] = []

    init(
      model: TextSelectionModel,
      exclusionRects: [CGRect],
      openURL: OpenURLAction,
      linkContextMenu: LinkContextMenuBuilder? = nil
    ) {
      self.model = model
      self.exclusionRects = exclusionRects
      self.openURL = openURL
      self.linkContextMenu = linkContextMenu

      super.init(frame: .zero)
      self.wantsLayer = false
    }

    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
      let localPoint = convert(point, from: superview)
      let isExcluded = exclusionRects.contains {
        $0.contains(localPoint)
      }

      if isExcluded {
        return nil
      } else {
        return super.hitTest(point)
      }
    }

    override func mouseDown(with event: NSEvent) {
      window?.makeFirstResponder(self)
      let location = convert(event.locationInWindow, from: nil)

      switch event.clickCount {
      case 1:
        if let url = model.url(for: location) {
          openURL(url)
        } else {
          resetSelection()
        }
        dragStart = model.closestPosition(to: location)
      case 2:
        if let position = model.closestPosition(to: location) {
          model.selectedRange = model.wordRange(for: position)
        }
        dragStart = nil
      case 3:
        if let position = model.closestPosition(to: location) {
          model.selectedRange = model.blockRange(for: position)
        }
        dragStart = nil
      default:
        break
      }
    }

    override func mouseDragged(with event: NSEvent) {
      guard let dragStart else {
        return
      }

      let location = convert(event.locationInWindow, from: nil)

      guard let currentPosition = model.closestPosition(to: location) else {
        return
      }

      model.selectedRange = TextRange(from: dragStart, to: currentPosition)
      autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
      dragStart = nil
    }

    override func rightMouseDown(with event: NSEvent) {
      let location = convert(event.locationInWindow, from: nil)
      lastContextMenuLocation = location
      updateSelectionForContextMenu(at: location)

      NSMenu.popUpContextMenu(makeContextMenu(), with: event, for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
      let location = convert(event.locationInWindow, from: nil)
      lastContextMenuLocation = location
      updateSelectionForContextMenu(at: location)

      return makeContextMenu()
    }

    override func selectAll(_ sender: Any?) {
      model.selectedRange = TextRange(start: model.startPosition, end: model.endPosition)
    }

    override func keyDown(with event: NSEvent) {
      interpretKeyEvents([event])
    }

    override func moveRightAndModifySelection(_ sender: Any?) {
      modifySelection { position, _ in
        model.position(from: position, offset: 1)
      }
    }

    override func moveLeftAndModifySelection(_ sender: Any?) {
      modifySelection { position, _ in
        model.position(from: position, offset: -1)
      }
    }

    override func moveUpAndModifySelection(_ sender: Any?) {
      modifySelection { position, anchor in
        model.positionAbove(position, anchor: anchor)
      }
    }

    override func moveDownAndModifySelection(_ sender: Any?) {
      modifySelection { position, anchor in
        model.positionBelow(position, anchor: anchor)
      }
    }

    override func moveWordRightAndModifySelection(_ sender: Any?) {
      modifySelection { position, _ in
        model.nextWord(from: position)
      }
    }

    override func moveWordLeftAndModifySelection(_ sender: Any?) {
      modifySelection { position, _ in
        model.previousWord(from: position)
      }
    }

    override func moveParagraphBackwardAndModifySelection(_ sender: Any?) {
      modifySelection { position, _ in
        model.blockStart(for: position)
      }
    }

    override func moveParagraphForwardAndModifySelection(_ sender: Any?) {
      modifySelection { position, _ in
        model.blockEnd(for: position)
      }
    }

    private func updateSelectionForContextMenu(at location: CGPoint) {
      guard let position = model.closestPosition(to: location) else {
        resetSelection()
        return
      }

      // Right-clicking a link selects the whole link run, not just the word
      // under the cursor.
      if model.url(for: location) != nil,
        let linkRange = model.linkRange(for: position)
      {
        model.selectedRange = linkRange
        return
      }

      if let selectedRange = model.selectedRange, selectedRange.contains(position) {
        // do nothing
        return
      }

      model.selectedRange = model.wordRange(for: position)
    }

    private func makeContextMenu() -> NSMenu {
      let contextMenu = NSMenu()
      menuItemTargets = []

      // Link-specific items, if the right-click landed on a link and a builder
      // is set. The host app's builder decides what to show per link URL.
      if let location = lastContextMenuLocation,
        let url = model.url(for: location),
        let linkContextMenu
      {
        var addedLinkItems = false
        for item in linkContextMenu(url) {
          contextMenu.addItem(makeNSMenuItem(from: item))
          addedLinkItems = true
        }
        // Keep Share/Copy available for the selected link text.
        if addedLinkItems, model.selectedRange?.isCollapsed == false {
          contextMenu.addItem(.separator())
          addShareCopyItems(to: contextMenu)
        }
        return contextMenu
      }

      // Default: Share/Copy of the current selection.
      guard model.selectedRange?.isCollapsed == false else {
        return contextMenu
      }
      addShareCopyItems(to: contextMenu)
      return contextMenu
    }

    private func addShareCopyItems(to contextMenu: NSMenu) {
      // Get the localized title for the share action
      let sharingPicker = NSSharingServicePicker(items: [])
      let shareActionTitle = sharingPicker.standardShareMenuItem.title

      // Get the localized title for the copy action
      let copyActionTitle =
        if let defaultMenu = NSTextView.defaultMenu,
          let copyAction = defaultMenu.items.first(where: { $0.action == #selector(copy(_:)) })
        {
          copyAction.title
        } else {
          NSLocalizedString("Copy", bundle: .main, comment: "")
        }

      contextMenu.addItem(
        .init(
          title: shareActionTitle,
          action: #selector(share(_:)),
          keyEquivalent: ""
        )
      )
      contextMenu.addItem(.separator())
      contextMenu.addItem(
        .init(
          title: copyActionTitle,
          action: #selector(copy(_:)),
          keyEquivalent: ""
        )
      )
    }

    private func makeNSMenuItem(from item: LinkMenuItem) -> NSMenuItem {
      if item.isSeparator {
        return NSMenuItem.separator()
      }

      let nsItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")

      if let submenu = item.submenu, !submenu.isEmpty {
        let submenuMenu = NSMenu()
        for sub in submenu {
          submenuMenu.addItem(makeNSMenuItem(from: sub))
        }
        nsItem.submenu = submenuMenu
        nsItem.isEnabled = item.isEnabled
      } else if let action = item.action {
        // Closure-backed item: a retained target forwards the menu choice to
        // the main-actor action.
        let target = LinkMenuItemTarget(action: action)
        menuItemTargets.append(target)
        nsItem.target = target
        nsItem.action = #selector(LinkMenuItemTarget.invoke(_:))
        nsItem.isEnabled = item.isEnabled
      } else {
        nsItem.isEnabled = false
      }

      return nsItem
    }

    private func modifySelection(
      _ transform: (_ position: TextPosition, _ anchor: TextPosition) -> TextPosition?
    ) {
      guard let selectedRange = model.selectedRange else {
        return
      }

      // set anchor on first move
      selectionAnchor = selectionAnchor ?? selectedRange.start

      guard let selectionAnchor else {
        return
      }

      // modify the non-anchor end of the selection
      let position =
        selectionAnchor == selectedRange.start
        ? selectedRange.end
        : selectedRange.start

      guard let newPosition = transform(position, selectionAnchor) else {
        return
      }
      model.selectedRange = TextRange(from: selectionAnchor, to: newPosition)

      // scroll to make the new position visible
      let caretRect = model.caretRect(for: newPosition)
      scrollToVisible(caretRect)
    }

    private func resetSelection() {
      model.selectedRange = nil
      selectionAnchor = nil
    }

    @objc private func share(_ sender: Any?) {
      guard let selectedRange = model.selectedRange else {
        return
      }

      let attributedText = model.attributedText(in: selectedRange)
      let transferableText = TransferableText(attributedString: attributedText)
      let itemProvider = NSItemProvider(object: transferableText)

      let sharingPicker = NSSharingServicePicker(items: [itemProvider])
      let rect =
        model.selectionRects(for: selectedRange)
        .last?.rect.integral ?? .zero

      sharingPicker.show(relativeTo: rect, of: self, preferredEdge: .maxY)
    }

    @objc private func copy(_ sender: Any?) {
      guard let selectedRange = model.selectedRange else {
        return
      }

      let attributedText = model.attributedText(in: selectedRange)

      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()

      let formatter = Formatter(attributedText)
      pasteboard.setString(formatter.plainText(), forType: .string)
      pasteboard.setString(formatter.html(), forType: .html)
    }
  }

  // Retained target that bridges a context-menu choice to a main-actor closure.
  private final class LinkMenuItemTarget: NSObject, NSUserInterfaceValidations {
    private let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
      self.action = action
    }

    @objc func invoke(_ sender: NSMenuItem) {
      // NSMenu invokes actions on the main thread (AppKit), so assuming main-
      // actor isolation to call the @MainActor closure is sound. Capture the
      // (Sendable) action into a local so we don't send non-Sendable `self`.
      let action = action
      MainActor.assumeIsolated { action() }
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
      true
    }
  }

  extension NSTextInteractionView: NSUserInterfaceValidations {
    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
      switch item.action {
      case #selector(selectAll(_:)):
        return model.hasText
      case #selector(copy(_:)):
        guard let selectedRange = model.selectedRange else {
          return false
        }
        return !selectedRange.isCollapsed
      case #selector(moveRightAndModifySelection(_:)),
        #selector(moveLeftAndModifySelection(_:)),
        #selector(moveUpAndModifySelection(_:)),
        #selector(moveDownAndModifySelection(_:)),
        #selector(moveWordRightAndModifySelection(_:)),
        #selector(moveWordLeftAndModifySelection(_:)),
        #selector(moveParagraphBackwardAndModifySelection(_:)),
        #selector(moveParagraphForwardAndModifySelection(_:)):
        return model.selectedRange != nil
      default:
        return true
      }
    }
  }
#endif
