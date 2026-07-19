import AppKit
import SwiftUI
import WikiFSSearch

// MARK: - ChatAutocompletePanel

/// A borderless, non-activating `NSPanel` that hosts the chat composer's
/// `[[kind:partial` autocomplete results list. Mirrors the omnibox's
/// `SuggestionsPanel` pattern (`OmniboxSearchField.swift:284`) so the composer's
/// `NSTextView` keeps first responder while the dropdown floats above — the
/// exact property the omnibox relies on for typing-while-navigating.
///
/// Positioning: anchored relative to the **caret line** of the composer
/// (`present(caretRect:in:placement:)`), not the composer's view bounds —
/// a multi-line composer is several lines tall, so positioning relative to the
/// view bounds would put the panel far above the caret. The composer uses
/// ``Placement/above`` (the composer sits near the bottom of the chat window,
/// so a below-caret dropdown would be clipped); the editor autocomplete (#680,
/// not yet implemented) will reuse this panel with `.below` or `.auto`.
/// Tracks the parent window via `addChildWindow(_:ordered:)` so it follows
/// window moves.
@MainActor
final class ChatAutocompletePanel: NSPanel {
    private var hosting: NSHostingView<AnyView>?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = true
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Re-render the panel with the current result set + keyboard highlight.
    /// Idempotent: the first call installs the hosting view, later calls
    /// update its `rootView` in place.
    func update(
        results: [TantivyShadowSearchResult],
        selectedIndex: Int?,
        width: CGFloat,
        onSelect: @escaping (TantivyShadowSearchResult) -> Void
    ) {
        let content = ChatAutocompleteResultsList(
            results: results,
            selectedIndex: selectedIndex,
            onSelect: onSelect)
            .frame(width: width)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
        let root = AnyView(content)

        let host: NSHostingView<AnyView>
        if let existing = hosting {
            existing.rootView = root
            host = existing
        } else {
            host = NSHostingView(rootView: root)
            contentView = host
            hosting = host
        }
        host.frame = NSRect(x: 0, y: 0, width: width, height: host.fittingSize.height)
        setContentSize(NSSize(width: width, height: host.fittingSize.height))
    }

    /// Preferred placement of the dropdown relative to the caret. Extracted as
    /// a type so the editor autocomplete (#680) can reuse the chat panel with
    /// different placement heuristics than the chat composer.
    ///
    /// - `.above`: chat composer convention (composer lives near the bottom of
    ///   the chat window, so below-caret would be clipped against the window's
    ///   bottom edge).
    /// - `.below`: editor convention (the editor is a tall NSTextView in the
    ///   middle of the window, so there's more room below the caret than
    ///   above).
    /// - `.auto`: pick whichever side has more room between the caret and the
    ///   parent window's edges — same idea as the original chat panel logic,
    ///   but measured against the CARET rect, not the entire text view's
    ///   bounds.
    enum Placement: Sendable {
        case above
        case below
        case auto
    }

    /// Pure, testable: compute the panel's screen-coordinate origin (bottom-
    /// left corner) given a caret rect (in screen coordinates), the panel's
    /// own size, the parent window's frame, and a preferred placement.
    ///
    /// macOS screen coordinates are bottom-left origin, so "above the caret"
    /// = larger Y, "below" = smaller Y. The panel's origin is its bottom-left
    /// corner, so:
    ///   - above → origin.y = `caretRect.maxY + gap` (panel bottom sits `gap`
    ///     above the caret's top edge, extends upward).
    ///   - below → origin.y = `caretRect.minY - height - gap` (panel top sits
    ///     `gap` below the caret's bottom edge, extends downward).
    ///
    /// The 8pt margin matches the historical behavior — don't visually touch
    /// the parent window's title bar (top) or bottom edge. When the preferred
    /// side doesn't have room, fall back to the other side (matches the
    /// original chat behavior; preserves the "panel still appears" property).
    nonisolated static func origin(
        caretRect: NSRect,
        panelSize: NSSize,
        windowFrame: NSRect,
        placement: Placement,
        gap: CGFloat = 4,
        horizontalOffset: CGFloat = 0
    ) -> NSPoint {
        let aboveOriginY = caretRect.maxY + gap
        let belowOriginY = caretRect.minY - panelSize.height - gap
        let roomAbove = (windowFrame.maxY - 8) - panelSize.height - caretRect.maxY - gap
        let roomBelow = caretRect.minY - (windowFrame.minY + 8) - panelSize.height - gap
        let x = caretRect.minX + horizontalOffset
        switch placement {
        case .above:
            return roomAbove >= 0
                ? NSPoint(x: x, y: aboveOriginY)
                : NSPoint(x: x, y: belowOriginY)
        case .below:
            return roomBelow >= 0
                ? NSPoint(x: x, y: belowOriginY)
                : NSPoint(x: x, y: aboveOriginY)
        case .auto:
            // Tie → above (chat composer is the more common consumer).
            if roomBelow > roomAbove {
                return NSPoint(x: x, y: belowOriginY)
            }
            return NSPoint(x: x, y: aboveOriginY)
        }
    }

    /// Position the panel relative to a caret rect (in screen coordinates) and
    /// attach it as a child window so it tracks window moves. The composer
    /// coordinator computes the caret rect via ``caretRect(in:)`` and passes it
    /// here; the panel itself stays free of NSTextView/AppKit-layout concerns.
    ///
    /// - Parameters:
    ///   - caretRect: rect (screen coordinates) of the line containing the
    ///     caret. Passing a 0-height rect (just the caret point) is fine — the
    ///     positioning math measures "above/below the caret point" rather than
    ///     "above/below the caret's line", but `.auto` still has both sides to
    ///     compare against.
    ///   - window: the parent window to attach to (and to measure room
    ///     against).
    ///   - placement: preferred direction (default `.above` — chat composer
    ///     convention).
    ///   - gap: vertical gap between the caret rect and the panel (default
    ///     4pt).
    ///   - horizontalOffset: extra horizontal offset added to the computed
    ///     origin (default 0).
    func present(
        caretRect: NSRect,
        in window: NSWindow,
        placement: Placement = .above,
        gap: CGFloat = 4,
        horizontalOffset: CGFloat = 0
    ) {
        let origin = Self.origin(
            caretRect: caretRect,
            panelSize: frame.size,
            windowFrame: window.frame,
            placement: placement,
            gap: gap,
            horizontalOffset: horizontalOffset)
        setFrameOrigin(origin)
        if parent == nil {
            window.addChildWindow(self, ordered: .above)
        }
        orderFront(nil)
    }

    /// Compute the rect (in screen coordinates) of the line that contains an
    /// `NSTextView`'s caret. Returns nil if the live AppKit state is unusable
    /// (no `layoutManager`, `textContainer`, or `window`), in which case the
    /// caller should fall back to positioning relative to the text view's
    /// bounds (see `ComposerTextView.Coordinator.presentPanel()`).
    ///
    /// Canonical AppKit recipe:
    /// 1. `ensureLayout(for: textContainer)` so the layout manager has line
    ///    fragments for the current text.
    /// 2. Map the caret's character location → glyph location via
    ///    `glyphRange(forCharacterRange:)` (a 0-length character range → 0-
    ///    length glyph range, but the location is what we need).
    /// 3. `lineFragmentRect(forGlyphAt:effectiveRange:)` returns the line's
    ///    rect in text-container coordinate space (with the line's full
    ///    height — important so "above vs below" measures against the full
    ///    line, not a 0-height point).
    /// 4. Offset by `textContainerOrigin` → text-view coordinate space.
    /// 5. `convert(_:to: nil)` → window coordinate space.
    /// 6. `convertToScreen(_:)` → screen coordinate space.
    @MainActor
    static func caretRect(in textView: NSTextView) -> NSRect? {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let window = textView.window else { return nil }
        let sel = textView.selectedRange()  // (location, 0) for a plain caret
        let stringLength = (textView.string as NSString).length
        guard sel.location >= 0, sel.location <= stringLength else { return nil }
        layoutManager.ensureLayout(for: textContainer)

        // Empty document: no glyphs to anchor a line fragment rect to. Use
        // the text container origin (top of the text area) so the caller can
        // still position the panel at the right vertical location.
        let glyphCount = layoutManager.numberOfGlyphs
        guard glyphCount > 0 else {
            let originInTextView = textView.textContainerOrigin
            let rectInWindow = textView.convert(
                NSRect(origin: originInTextView, size: .zero),
                to: nil)
            return window.convertToScreen(rectInWindow)
        }

        // Map the caret's character location → glyph location. For a 0-length
        // character range this returns a 0-length glyph range, but the
        // location is what we want.
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: sel.location, length: 0),
            actualCharacterRange: nil)
        // Caret at end-of-document: glyphRange.location may equal glyphCount.
        // Clamp to the last valid glyph index so lineFragmentRect doesn't
        // return .zero.
        let safeGlyphIndex: Int
        if glyphRange.location != NSNotFound, glyphRange.location < glyphCount {
            safeGlyphIndex = glyphRange.location
        } else {
            safeGlyphIndex = glyphCount - 1
        }
        let lineFragmentRect = layoutManager.lineFragmentRect(
            forGlyphAt: safeGlyphIndex,
            effectiveRange: nil)
        let textContainerOrigin = textView.textContainerOrigin
        let rectInTextView = NSRect(
            x: lineFragmentRect.minX + textContainerOrigin.x,
            y: lineFragmentRect.minY + textContainerOrigin.y,
            width: lineFragmentRect.width,
            height: lineFragmentRect.height)
        let rectInWindow = textView.convert(rectInTextView, to: nil)
        return window.convertToScreen(rectInWindow)
    }
}

// MARK: - SwiftUI results list

/// The ranked autocomplete rows shown in `ChatAutocompletePanel`. Mirrors the
/// omnibox `AddressResultsList` (`AddressBarView.swift:465`) — icon + title +
/// kind caption, hover + keyboard highlight, `↩` glyph on the Enter target —
/// but is fed by `[TantivyShadowSearchResult]` rather than `[OmniboxResult]`.
private struct ChatAutocompleteResultsList: View {
    let results: [TantivyShadowSearchResult]
    /// The arrow-key-selected row, pushed in from the AppKit coordinator. `nil`
    /// means nothing is explicitly selected and Enter targets the top row.
    let selectedIndex: Int?
    let onSelect: (TantivyShadowSearchResult) -> Void

    @State private var hoveredID: String?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(results.enumerated()), id: \.element.documentID) { index, result in
                row(result, index: index)
                if result.documentID != results.last?.documentID {
                    Divider()
                        .padding(.leading, 34)
                        .opacity(0.25)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func row(_ result: TantivyShadowSearchResult, index: Int) -> some View {
        let hovered = hoveredID == result.documentID
        let keyboardSelected = selectedIndex == index
        // Hover wins over keyboard (same as the omnibox) so the two don't fight.
        let highlighted = hovered || (hoveredID == nil && keyboardSelected)
        let isEnterTarget = keyboardSelected || (selectedIndex == nil && index == 0)
        Button {
            onSelect(result)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: result.kind.systemImageName)
                    .font(.caption)
                    .foregroundStyle(highlighted ? Color.accentColor : .secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.title)
                        .lineLimit(1)
                        .font(.callout)
                    Text(result.kind.rawValue.capitalized)
                        .lineLimit(1)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                if isEnterTarget {
                    Image(systemName: "return")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(highlighted ? Color.accentColor.opacity(0.14) : Color.clear)
                    .padding(.horizontal, 4)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hoveredID = result.documentID
            } else if hoveredID == result.documentID {
                hoveredID = nil
            }
        }
    }
}

// MARK: - Kind → icon mapping

private extension TantivyDocumentKind {
    /// SF Symbol name for this kind — matches `ResourceKind.systemImageName`'s
    /// choices for the three linkable kinds (page/source/chat) so the dropdown
    /// row icons match the sidebar/omnibox. Duplicated here as a small leaf
    /// (`WikiFSSearch` doesn't depend on the app layer's `ResourceKind`); the
    /// shapes are stable (a kind-prefix rename is a breaking change).
    var systemImageName: String {
        switch self {
        case .page:   "doc.text"
        case .source: "tray.full"
        case .chat:   "bubble.left.and.bubble.right"
        }
    }
}

// MARK: - Selection advancement (pure, testable)

/// Pure, testable keyboard-highlight advancement for the chat autocomplete
/// dropdown. Mirrors `OmniboxSelection.advance` (`OmniboxSearchField.swift:270`)
/// — same clamping behavior (no wrap, first ↓ → row 0, first ↑ → last row) —
/// extracted as its own type so the chat composer's tests don't need to reach
/// into the omnibox's namespace. Stays in this file because there's only one
/// caller (the composer coordinator); if a third consumer emerges, promote it
/// to a shared file.
enum ChatAutocompleteSelection {
    /// Returns the new selected index, or `nil` if there is nothing to select
    /// (empty list). When `current == nil`, the first down selects row 0 and
    /// the first up selects the last row.
    static func advance(current: Int?, count: Int, delta: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return delta > 0 ? 0 : count - 1 }
        return max(0, min(count - 1, current + delta))
    }
}
