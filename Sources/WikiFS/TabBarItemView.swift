import SwiftUI
import WikiFSCore

/// One tab button in the tab bar. Shows icon + truncated title + close button.
/// Active tab has an accent underline; inactive tabs have a subtle background on hover.
struct TabBarItemView: View {
    let tab: EditorTab
    let isActive: Bool
    let iconName: String
    let onClick: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false
    @State private var isCloseHovering = false

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 4) {
                closeButton
                icon
                titleText
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxHeight: .infinity)
            .background(background)
            .overlay(alignment: .bottom) {
                if isActive {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                        .padding(.horizontal, 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovering = hovering }
        .help(tab.title)
    }

    // MARK: - Subviews

    @ViewBuilder
    private var closeButton: some View {
        Group {
            if isHovering || isActive {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .background(isCloseHovering ? Color.primary.opacity(0.1) : .clear)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { h in isCloseHovering = h }
            } else {
                Color.clear.frame(width: 14, height: 14)
            }
        }
    }

    private var icon: some View {
        Image(systemName: iconName)
            .font(.caption)
            .foregroundStyle(isActive ? Color.accentColor : .secondary)
    }

    private var titleText: some View {
        Text(tab.title)
            .font(.caption)
            .fontWeight(isActive ? .semibold : .regular)
            .foregroundStyle(isActive ? .primary : .secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: ItemMetrics.maxTitleWidth, alignment: .leading)
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
}

private enum ItemMetrics {
    static let maxTitleWidth: CGFloat = 160
}
