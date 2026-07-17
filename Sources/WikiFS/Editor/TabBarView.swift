import SwiftUI
import WikiFSCore

/// Horizontal tab strip at the top of the detail pane. Tabs share the available
/// width evenly, shrinking from `maxTabWidth` toward `minTabWidth` as more open.
/// Once even the minimum won't fit, the strip shows as many tabs as fit plus a
/// `⌄` overflow menu listing every open tab. The active tab is always kept
/// visible (pinned into the last visible slot if it would otherwise overflow).
struct TabBarView: View {
    @Bindable var store: WikiStoreModel

    var body: some View {
        GeometryReader { geo in
            let layout = TabBarLayout.compute(
                tabCount: store.tabs.count,
                availableWidth: geo.size.width - TabBarMetrics.horizontalPadding * 2,
                minTabWidth: TabBarMetrics.minTabWidth,
                maxTabWidth: TabBarMetrics.maxTabWidth,
                overflowWidth: TabBarMetrics.overflowWidth)

            HStack(spacing: 0) {
                ForEach(visibleTabs(layout)) { tab in
                    TabBarItemView(
                        tab: tab,
                        isActive: tab.id == store.activeTabID,
                        iconName: store.tabIcon(for: tab.selection),
                        width: layout.tabWidth,
                        onClick: { store.selectTab(id: tab.id) },
                        onClose: { store.closeTab(id: tab.id) },
                        onCloseOthers: { store.closeOtherTabs(id: tab.id) },
                        onCloseAfter: { store.closeTabsAfter(id: tab.id) },
                        onCloseAll: { store.closeAllTabs() }
                    )
                }
                if layout.showsOverflow {
                    overflowMenu
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, TabBarMetrics.horizontalPadding)
        }
        .frame(height: TabBarMetrics.height)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider().opacity(PageEditorMetrics.dividerOpacity)
        }
    }

    /// The tabs to draw in the strip, in order. When the active tab would fall
    /// past the visible window, it's pinned into the last visible slot so the
    /// document you're editing is never hidden (the chevron menu still lists
    /// everything).
    private func visibleTabs(_ layout: TabBarLayout) -> [EditorTab] {
        let head = Array(store.tabs.prefix(layout.visibleCount))
        guard layout.showsOverflow,
              let active = store.activeTab,
              !head.contains(where: { $0.id == active.id })
        else { return head }
        return Array(store.tabs.prefix(max(0, layout.visibleCount - 1))) + [active]
    }

    /// `⌄` menu: a complete tab switcher listing every open tab with a checkmark
    /// on the active one.
    private var overflowMenu: some View {
        Menu {
            ForEach(store.tabs) { tab in
                Button {
                    store.selectTab(id: tab.id)
                } label: {
                    if tab.id == store.activeTabID {
                        Label(tab.title, systemImage: "checkmark")
                    } else {
                        Text(tab.title)
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: TabBarMetrics.overflowWidth)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show all tabs")
    }
}

enum TabBarMetrics {
    static let height: CGFloat = 34
    /// Tabs never grow past this (few tabs sit here).
    static let maxTabWidth: CGFloat = 200
    /// Tabs never shrink past this (beyond it, they spill into the overflow menu).
    static let minTabWidth: CGFloat = 110
    /// Reserved for the `⌄` overflow menu when present.
    static let overflowWidth: CGFloat = 28
    /// Inset on each end of the strip.
    static let horizontalPadding: CGFloat = 4
}
