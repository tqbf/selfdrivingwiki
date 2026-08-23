#if os(macOS)
import AppKit
import SwiftUI

// pattern: Imperative Shell — owns AppKit child-view layout, clipping, hit testing, and teardown.

/// The native reader host. The WebView remains the document-layout and scrolling
/// authority; this sibling overlay is only a clipped projection for trusted
/// attachment rectangles.
@MainActor
final class WikiReaderContainerView: NSView {
    let webView: WikiReaderWebView
    private let attachmentOverlay = RendererAttachmentOverlayView()
    private var attachmentChildren: [RendererAttachmentPlaceholderID: RendererAttachmentNativeChildView] = [:]
    private var visibleAttachmentRects: [RendererAttachmentPlaceholderID: CGRect] = [:]
    private var attachmentOrder: [RendererAttachmentPlaceholderID] = []
    private var focusedAttachmentID: RendererAttachmentPlaceholderID?

    init(webView: WikiReaderWebView) {
        self.webView = webView
        super.init(frame: .zero)
        addSubview(webView)
        addSubview(attachmentOverlay)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        webView.frame = bounds
        attachmentOverlay.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let visibleIDs = attachmentOrder.filter { placeholderID in
            visibleAttachmentRects[placeholderID]?.contains(point) == true
        }
        if let placeholderID = preferredHitAttachment(in: visibleIDs),
           let attachmentChild = attachmentChildren[placeholderID] {
            let overlayPoint = attachmentOverlay.convert(point, from: self)
            if let hitView = attachmentChild.hitTest(overlayPoint) {
                return hitView
            }
        }
        return webView
    }

    /// Retains each placeholder's latest visible rect before it mounts, then
    /// updates only the matching child.
    func updateAttachmentViewport(
        _ rect: CGRect,
        for placeholderID: RendererAttachmentPlaceholderID
    ) {
        let clippedRect = rect.intersection(bounds)
        visibleAttachmentRects[placeholderID] = clippedRect
        attachmentChildren[placeholderID]?.frame = clippedRect
    }

    func activateAttachment(
        named placeholderID: RendererAttachmentPlaceholderID,
        title: String = "Interactive",
        content: AnyView? = nil,
        takesFocus: Bool = true,
        onExit: (() -> Void)? = nil
    ) {
        if let child = attachmentChildren[placeholderID] {
            if takesFocus { focusAttachment(named: placeholderID) }
            child.frame = visibleAttachmentRects[placeholderID] ?? .zero
            return
        }
        let child = RendererAttachmentNativeChildView(
            placeholderID: placeholderID,
            title: title,
            content: content,
            onFocus: { [weak self] in self?.markFocused(placeholderID) },
            onExit: { [weak self] in
                if let onExit { onExit() }
                else { self?.removeAttachment(named: placeholderID) }
            })
        attachmentOverlay.addSubview(child)
        attachmentChildren[placeholderID] = child
        attachmentOrder.append(placeholderID)
        child.frame = visibleAttachmentRects[placeholderID] ?? .zero
        if takesFocus {
            focusAttachment(named: placeholderID)
        }
    }

    func removeAttachment(named placeholderID: RendererAttachmentPlaceholderID) {
        guard let child = attachmentChildren.removeValue(forKey: placeholderID) else { return }
        let restoresReaderFocus = childContainsFirstResponder(child)
        child.removeFromSuperview()
        visibleAttachmentRects.removeValue(forKey: placeholderID)
        attachmentOrder.removeAll { $0 == placeholderID }
        if focusedAttachmentID == placeholderID { focusedAttachmentID = nil }
        if restoresReaderFocus { window?.makeFirstResponder(webView) }
    }

    func removeAllAttachments() {
        let restoresReaderFocus = attachmentChildren.values.contains(where: childContainsFirstResponder)
        for child in attachmentChildren.values {
            child.removeFromSuperview()
        }
        attachmentChildren.removeAll()
        visibleAttachmentRects.removeAll()
        attachmentOrder.removeAll()
        focusedAttachmentID = nil
        if restoresReaderFocus { window?.makeFirstResponder(webView) }
    }

    func ownsMountedAttachment(named placeholderID: RendererAttachmentPlaceholderID) -> Bool {
        attachmentChildren[placeholderID] != nil
    }

    func focusAttachment(named placeholderID: RendererAttachmentPlaceholderID) {
        guard let attachmentChild = attachmentChildren[placeholderID] else { return }
        markFocused(placeholderID)
        window?.makeFirstResponder(attachmentChild)
    }

    var hasMountedAttachment: Bool { !attachmentChildren.isEmpty }
    var mountedAttachmentCount: Int { attachmentChildren.count }

    func attachmentChild(named placeholderID: RendererAttachmentPlaceholderID) -> NSView? {
        attachmentChildren[placeholderID]
    }

    private func preferredHitAttachment(
        in visibleIDs: [RendererAttachmentPlaceholderID]
    ) -> RendererAttachmentPlaceholderID? {
        guard visibleIDs.count > 1 else { return visibleIDs.first }
        if let focusedAttachmentID, visibleIDs.contains(focusedAttachmentID) {
            return focusedAttachmentID
        }
        return visibleIDs.last
    }

    private func markFocused(_ placeholderID: RendererAttachmentPlaceholderID) {
        guard attachmentChildren[placeholderID] != nil else { return }
        focusedAttachmentID = placeholderID
        attachmentOrder.removeAll { $0 == placeholderID }
        attachmentOrder.append(placeholderID)
        if let child = attachmentChildren[placeholderID] {
            attachmentOverlay.addSubview(child, positioned: .above, relativeTo: nil)
        }
    }

    private func childContainsFirstResponder(_ child: RendererAttachmentNativeChildView) -> Bool {
        guard var responder = window?.firstResponder as? NSView else { return false }
        while true {
            if responder === child { return true }
            guard let superview = responder.superview else { return false }
            responder = superview
        }
    }

    func teardown() {
        removeAllAttachments()
        attachmentOverlay.removeFromSuperview()
        webView.removeFromSuperview()
    }
}

@MainActor
private final class RendererAttachmentOverlayView: NSView {
}

@MainActor
private final class RendererAttachmentNativeChildView: NSView {
    let placeholderID: RendererAttachmentPlaceholderID
    private let onFocus: () -> Void
    private let onExit: () -> Void
    private let hostedContent: NSHostingView<AnyView>?

    init(
        placeholderID: RendererAttachmentPlaceholderID,
        title: String,
        content: AnyView?,
        onFocus: @escaping () -> Void,
        onExit: @escaping () -> Void
    ) {
        self.placeholderID = placeholderID
        self.onFocus = onFocus
        self.onExit = onExit
        hostedContent = content.map(NSHostingView.init(rootView:))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
        updateKeyboardFocusIndicator()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(title) renderer")
        setAccessibilityIdentifier("renderer-attachment-\(placeholderID.rawValue)")

        if let hostedContent {
            addSubview(hostedContent)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus() }
        updateKeyboardFocusIndicator()
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        // AppKit invokes this callback before it updates window.firstResponder,
        // so consulting the window here still sees this child as focused. A
        // successful resignation is the authoritative transition; clear the
        // indicator immediately and let viewDidMoveToWindow re-check when the
        // child is attached to a new window.
        if resigned {
            layer?.borderWidth = 0
        } else {
            updateKeyboardFocusIndicator()
        }
        return resigned
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateKeyboardFocusIndicator()
    }

    override func layout() {
        super.layout()
        hostedContent?.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        guard bounds.contains(localPoint) else { return nil }
        guard let hostedContent else { return self }
        return hostedContent.hitTest(localPoint) ?? self
    }

    private func updateKeyboardFocusIndicator() {
        layer?.borderWidth = isSelfOrDescendantFirstResponder() ? 2 : 0
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onExit() }
        else { super.keyDown(with: event) }
    }
}
#endif
