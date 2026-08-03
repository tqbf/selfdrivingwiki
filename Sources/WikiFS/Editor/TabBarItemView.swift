import SwiftUI
import WikiFSCore

/// One tab button in the tab bar. Shows icon + truncated title + close button.
/// Active tab has an accent underline; inactive tabs get a subtle background on
/// hover. Pinned tabs show a pin and preserve their selection during ordinary
/// navigation. Right-click opens a native `.contextMenu` for pin and close actions.
struct TabBarItemView: View {
    let tab: EditorTab
    let isActive: Bool
    let iconName: String
    /// Uniform width the tab is drawn at, computed by `TabBarLayout`. Tabs shrink
    /// as more open; the title truncates within.
    let width: CGFloat
    let onClick: () -> Void
    let onTogglePin: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onCloseAfter: () -> Void
    let onCloseAll: () -> Void

    @State private var isHovering = false
    @State private var isCloseHovering = false

    var body: some View {
        HStack(spacing: 4) {
            closeButton
            icon
            pinIndicator
            titleText
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(background)
        .overlay(alignment: .bottom) { activeUnderline }
        .contentShape(Rectangle())
        .onTapGesture { onClick() }
        .onHover { isHovering = $0 }
        .help(tab.title)
        .contextMenu { contextMenuItems }
    }

    // MARK: - Subviews

    /// Always present so the tab width never reflows on hover — faded out via
    /// opacity, and hit-testing disabled while invisible (SWIFTUI-RULES §4.5:
    /// opacity-fade, never insert-on-hover).
    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
                .background(isCloseHovering ? Color.primary.opacity(0.1) : .clear)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isCloseHovering = $0 }
        .opacity(isHovering || isActive ? 1 : 0)
        .allowsHitTesting(isHovering || isActive)
    }

    private var icon: some View {
        Image(systemName: iconName)
            .font(.caption)
            .foregroundStyle(isActive ? Color.accentColor : .secondary)
    }

    @ViewBuilder
    private var pinIndicator: some View {
        if tab.isPinned {
            Image(systemName: "pin.fill")
                .font(.caption)
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
                .accessibilityLabel("Pinned")
        }
    }

    private var titleText: some View {
        Text(tab.title)
            .font(.caption)
            .fontWeight(isActive ? .semibold : .regular)
            .foregroundStyle(isActive ? .primary : .secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var activeUnderline: some View {
        if isActive {
            Capsule()
                .fill(Color.accentColor)
                .frame(height: 2)
                .padding(.horizontal, 2)
        }
    }

    @ViewBuilder
    private var background: some View {
        if isActive {
            Color(nsColor: .controlBackgroundColor)
        } else if isHovering {
            Color.primary.opacity(0.06)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button(tab.isPinned ? "Unpin" : "Pin", systemImage: tab.isPinned ? "pin.slash" : "pin") {
            onTogglePin()
        }
        Divider()
        Button("Close", systemImage: "xmark") { onClose() }
        Button("Close Others", systemImage: "xmark.circle") { onCloseOthers() }
        Button("Close Tabs After", systemImage: "arrow.right.to.line") { onCloseAfter() }
        Divider()
        Button("Close All", systemImage: "xmark.circle.fill") { onCloseAll() }
    }
}
