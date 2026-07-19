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
/// Anchored ABOVE the composer (the composer sits near the bottom of the chat
/// window, so a below-anchor dropdown would be clipped). Tracks the parent
/// window via `addChildWindow(_:ordered:)` so it follows window moves.
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

    /// Position the panel **above** the anchor view and attach it as a child
    /// window so it tracks window moves. The composer sits near the bottom of
    /// the chat window, so a below-anchor placement (the omnibox convention)
    /// would be clipped.
    ///
    /// `minY` floor: clamp the panel origin to at least the window's content
    /// min Y + a small margin so a very-tall dropdown (the composer just
    /// opened at the bottom of a short window) never overflows the title bar.
    /// If the panel doesn't fit above the anchor, fall back to below.
    func present(above anchor: NSView) {
        guard let window = anchor.window else { return }
        let rectInWindow = anchor.convert(anchor.bounds, to: nil)
        let rectOnScreen = window.convertToScreen(rectInWindow)
        let aboveOrigin = NSPoint(
            x: rectOnScreen.minX,
            y: rectOnScreen.maxY + frame.height + 4)
        // If above-origin places the panel's top above the parent window's top,
        // fall back to below (composer-height + 4pt gap).
        let parentTopY = window.convertToScreen(
            NSRect(x: 0, y: 0, width: 0, height: window.frame.height)).maxY
        let origin: NSPoint
        if aboveOrigin.y + frame.height > parentTopY - 8 {
            // Not enough room above — pop BELOW the anchor instead.
            origin = NSPoint(x: rectOnScreen.minX,
                             y: rectOnScreen.minY - frame.height - 4)
        } else {
            origin = aboveOrigin
        }
        setFrameOrigin(origin)
        if parent == nil {
            window.addChildWindow(self, ordered: .above)
        }
        orderFront(nil)
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
