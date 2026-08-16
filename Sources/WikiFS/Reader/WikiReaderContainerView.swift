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
    private var attachmentChild: RendererAttachmentNativeChildView?

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
        if attachmentOverlay.attachmentClipRect.contains(point), let attachmentChild {
            let childPoint = attachmentChild.convert(point, from: self)
            if let hitView = attachmentChild.hitTest(childPoint) {
                return hitView
            }
        }
        return webView
    }

    func updateAttachmentViewport(_ rect: CGRect) {
        attachmentOverlay.attachmentClipRect = rect.intersection(bounds)
        attachmentChild?.frame = attachmentOverlay.attachmentClipRect
    }

    func activateAttachment(named placeholderID: RendererAttachmentPlaceholderID, content: AnyView? = nil) {
        removeAttachmentChild()
        let child = RendererAttachmentNativeChildView(placeholderID: placeholderID, content: content) { [weak self] in
            self?.collapseAttachment()
        }
        attachmentOverlay.addSubview(child)
        attachmentChild = child
        child.frame = attachmentOverlay.attachmentClipRect
        window?.makeFirstResponder(child)
    }

    func collapseAttachment() {
        removeAttachmentChild()
        window?.makeFirstResponder(webView)
    }

    private func removeAttachmentChild() {
        attachmentChild?.removeFromSuperview()
        attachmentChild = nil
    }

    func teardown() {
        removeAttachmentChild()
        attachmentOverlay.attachmentClipRect = .zero
        attachmentOverlay.removeFromSuperview()
        webView.removeFromSuperview()
    }
}

@MainActor
private final class RendererAttachmentOverlayView: NSView {
    /// A zero rectangle is fully pass-through. Attachment children added in a
    /// later renderer factory are constrained to this exact visible rectangle.
    fileprivate var attachmentClipRect: CGRect = .zero {
        didSet { needsDisplay = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard attachmentClipRect.contains(point) else { return nil }
        return super.hitTest(point)
    }
}

@MainActor
private final class RendererAttachmentNativeChildView: NSView {
    private let placeholderID: RendererAttachmentPlaceholderID
    private let onExit: () -> Void
    private let hostedContent: NSHostingView<AnyView>?

    init(
        placeholderID: RendererAttachmentPlaceholderID,
        content: AnyView?,
        onExit: @escaping () -> Void
    ) {
        self.placeholderID = placeholderID
        self.onExit = onExit
        hostedContent = content.map(NSHostingView.init(rootView:))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Interactive renderer attachment")
        setAccessibilityIdentifier("renderer-attachment-\(placeholderID.rawValue)")
        if let hostedContent {
            hostedContent.frame = bounds
            hostedContent.autoresizingMask = [.width, .height]
            addSubview(hostedContent)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        guard let hostedContent else { return self }
        return hostedContent.hitTest(hostedContent.convert(point, from: self)) ?? self
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onExit() }
        else { super.keyDown(with: event) }
    }
}
#endif
