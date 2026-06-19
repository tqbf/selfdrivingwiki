import SwiftUI
import WikiFSCore

/// Horizontal tab strip displayed at the top of the detail pane. Mirrors
/// Obsidian's tab bar: each tab shows icon + truncated title + close button.
/// Scrolls horizontally when there are many tabs.
struct TabBarView: View {
    @Bindable var store: WikiStoreModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(store.tabs.enumerated()), id: \.element.id) { index, tab in
                    TabBarItemView(
                        tab: tab,
                        isActive: index == store.activeTabIndex,
                        iconName: store.tabIcon(for: tab.selection),
                        onClick: { store.selectTab(at: index) },
                        onClose: { store.closeTab(at: index) }
                    )
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: TabBarMetrics.height)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider().opacity(PageEditorMetrics.dividerOpacity)
        }
    }
}

enum TabBarMetrics {
    static let height: CGFloat = 34
}
