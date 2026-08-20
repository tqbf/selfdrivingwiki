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

    /// Updates the one mounted attachment only when the report belongs to it.
    /// Before mounting, the latest candidate rect is retained so the child can
    /// be positioned before it enters the view hierarchy.
    func updateAttachmentViewport(
        _ rect: CGRect,
        for placeholderID: RendererAttachmentPlaceholderID? = nil
    ) {
        guard placeholderID == nil || attachmentChild == nil || attachmentChild?.placeholderID == placeholderID else {
            return
        }
        attachmentOverlay.attachmentClipRect = rect.intersection(bounds)
        attachmentChild?.frame = attachmentOverlay.attachmentClipRect
    }

    func activateAttachment(
        named placeholderID: RendererAttachmentPlaceholderID,
        content: AnyView? = nil,
        takesFocus: Bool = true,
        onOpen: (() -> Void)? = nil,
        onExit: (() -> Void)? = nil
    ) {
        removeAttachmentChild()
        let child = RendererAttachmentNativeChildView(
            placeholderID: placeholderID,
            content: content,
            onOpen: onOpen,
            onExit: { [weak self] in
                if let onExit { onExit() }
                else { self?.collapseAttachment() }
            })
        attachmentOverlay.addSubview(child)
        attachmentChild = child
        child.frame = attachmentOverlay.attachmentClipRect
        if takesFocus {
            window?.makeFirstResponder(child)
        }
    }

    func collapseAttachment() {
        removeAttachmentChild()
        window?.makeFirstResponder(webView)
    }

    /// The mounted child is the sole native attachment shown by this container.
    func ownsMountedAttachment(named placeholderID: RendererAttachmentPlaceholderID) -> Bool {
        attachmentChild?.placeholderID == placeholderID
    }

    func focusAttachment(named placeholderID: RendererAttachmentPlaceholderID) {
        guard attachmentChild?.placeholderID == placeholderID,
              let attachmentChild
        else { return }
        window?.makeFirstResponder(attachmentChild)
    }

    var hasMountedAttachment: Bool { attachmentChild != nil }

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
    let placeholderID: RendererAttachmentPlaceholderID
    private let onOpen: () -> Void
    private let onExit: () -> Void
    private let hostedContent: NSHostingView<AnyView>?
    private let toolbar: NSVisualEffectView
    private let toolbarStack: NSStackView

    init(
        placeholderID: RendererAttachmentPlaceholderID,
        content: AnyView?,
        onOpen: (() -> Void)?,
        onExit: @escaping () -> Void
    ) {
        self.placeholderID = placeholderID
        self.onOpen = onOpen ?? {}
        self.onExit = onExit
        hostedContent = content.map(NSHostingView.init(rootView:))
        toolbar = NSVisualEffectView()
        toolbarStack = NSStackView()
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
        updateKeyboardFocusIndicator()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Interactive renderer attachment")
        setAccessibilityIdentifier("renderer-attachment-\(placeholderID.rawValue)")

        toolbar.material = .headerView
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active
        toolbar.setAccessibilityElement(true)
        toolbar.setAccessibilityRole(.toolbar)
        toolbar.setAccessibilityLabel("Interactive renderer controls")
        toolbar.setAccessibilityIdentifier("renderer-attachment-toolbar-\(placeholderID.rawValue)")
        addSubview(toolbar)

        let title = NSTextField(labelWithString: "Interactive renderer")
        title.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.setAccessibilityElement(true)
        title.setAccessibilityRole(.staticText)
        title.setAccessibilityLabel("Interactive renderer")

        let openButton = NSButton(title: "Open in Window", target: self, action: #selector(openInWindow))
        openButton.bezelStyle = .texturedRounded
        openButton.controlSize = .small
        openButton.setAccessibilityLabel("Open in Window")
        openButton.setAccessibilityHelp("Open this renderer in a separate window.")
        openButton.setAccessibilityIdentifier("renderer-attachment-open-\(placeholderID.rawValue)")

        let collapseButton = NSButton(title: "Collapse", target: self, action: #selector(collapse))
        collapseButton.bezelStyle = .texturedRounded
        collapseButton.controlSize = .small
        collapseButton.setAccessibilityLabel("Collapse")
        collapseButton.setAccessibilityHelp("Hide this inline renderer and show the document card.")
        collapseButton.setAccessibilityIdentifier("renderer-attachment-collapse-\(placeholderID.rawValue)")

        toolbarStack.orientation = .horizontal
        toolbarStack.alignment = .centerY
        toolbarStack.distribution = .fill
        toolbarStack.spacing = 8
        toolbarStack.addArrangedSubview(title)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolbarStack.addArrangedSubview(spacer)
        toolbarStack.addArrangedSubview(openButton)
        toolbarStack.addArrangedSubview(collapseButton)
        toolbar.addSubview(toolbarStack)

        if let hostedContent {
            addSubview(hostedContent)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
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
        let toolbarHeight: CGFloat = 32
        toolbar.frame = CGRect(x: 0, y: bounds.height - toolbarHeight, width: bounds.width, height: toolbarHeight)
        toolbarStack.frame = toolbar.bounds.insetBy(dx: 8, dy: 4)
        hostedContent?.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - toolbarHeight))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        let toolbarPoint = toolbar.convert(point, from: self)
        if let toolbarHit = toolbar.hitTest(toolbarPoint) {
            return toolbarHit
        }
        guard let hostedContent else { return self }
        return hostedContent.hitTest(hostedContent.convert(point, from: self)) ?? self
    }

    @objc private func openInWindow() {
        onOpen()
    }

    @objc private func collapse() {
        onExit()
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
