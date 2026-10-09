import SwiftUI
import WikiFSCore

/// Horizontal tab strip at the top of the detail pane. Tabs share the available
/// width evenly, shrinking from `maxTabWidth` toward `minTabWidth` as more open.
/// Once even the minimum won't fit, the strip shows as many tabs as fit plus a
/// `⌄` overflow menu listing every open tab. The active tab is always kept
/// visible (pinned into the last visible slot if it would otherwise overflow).
struct TabBarView: View {
    @Bindable var store: WikiStoreModel

    /// In-flight drag-to-reorder (#1388): which tab is being dragged, its
    /// home position in the visible order, its horizontal translation, and the
    /// insertion slot it would land at. `nil` when no drag is active.
    @State private var drag: TabDrag?

    private struct TabDrag: Equatable {
        let tabID: UUID
        let fromIndex: Int
        var translation: CGFloat
        var slot: Int

        /// Whether the drag has passed the half-width swap threshold. The
        /// insertion indicator stays hidden until it has — no blue line for a
        /// drag that would land the tab back where it started.
        var wouldMove: Bool {
            TabBarLayout.targetIndex(fromIndex: fromIndex, slot: slot) != fromIndex
        }
    }

    var body: some View {
        GeometryReader { geo in
            let layout = TabBarLayout.compute(
                tabCount: store.tabs.count,
                availableWidth: geo.size.width - TabBarMetrics.horizontalPadding * 2,
                minTabWidth: TabBarMetrics.minTabWidth,
                maxTabWidth: TabBarMetrics.maxTabWidth,
                overflowWidth: TabBarMetrics.overflowWidth)
            let visible = visibleTabs(layout)

            HStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, tab in
                    // Insertion indicator lives IN the strip (net zero width, so
                    // no reflow) at zIndex 0 — the dragged tab (zIndex 1) slides
                    // over it instead of the line showing through the tab.
                    if drag?.wouldMove == true, drag?.slot == index {
                        insertionIndicator
                    }
                    TabBarItemView(
                        tab: tab,
                        isActive: tab.id == store.activeTabID,
                        isDragged: drag?.tabID == tab.id,
                        iconName: store.tabIcon(for: tab.selection),
                        width: layout.tabWidth,
                        onClick: { store.selectTab(id: tab.id) },
                        onTogglePin: { store.toggleTabPin(id: tab.id) },
                        onClose: { store.closeTab(id: tab.id) },
                        onCloseOthers: { store.closeOtherTabs(id: tab.id) },
                        onCloseAfter: { store.closeTabsAfter(id: tab.id) },
                        onCloseAll: { store.closeAllTabs() },
                        onDragChanged: { translation in
                            dragChanged(tabID: tab.id, visibleIndex: index,
                                        translation: translation, layout: layout,
                                        visibleCount: visible.count)
                        },
                        onDragEnded: { translation in
                            dragEnded(tabID: tab.id, visibleIndex: index,
                                      translation: translation, layout: layout,
                                      visible: visible)
                        }
                    )
                    // The dragged tab rides with the cursor above its neighbors;
                    // the strip itself doesn't reflow until the drop commits.
                    .offset(x: drag?.tabID == tab.id ? drag?.translation ?? 0 : 0)
                    .zIndex(drag?.tabID == tab.id ? 1 : 0)
                }
                if drag?.wouldMove == true, drag?.slot == visible.count {
                    insertionIndicator
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

    /// 2pt accent line at the drop slot's leading boundary. Net zero width
    /// (2pt wide with -2pt horizontal padding) so showing it never reflows
    /// the strip.
    private var insertionIndicator: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: TabBarMetrics.insertionIndicatorWidth)
            .padding(.horizontal, -TabBarMetrics.insertionIndicatorWidth)
            .padding(.vertical, TabBarMetrics.insertionIndicatorVerticalInset)
    }

    // MARK: - Drag-to-reorder (#1388)

    private func dragChanged(tabID: UUID, visibleIndex: Int, translation: CGFloat,
                             layout: TabBarLayout, visibleCount: Int) {
        let slot = TabBarLayout.insertionIndex(
            fromIndex: visibleIndex,
            dragOffset: translation,
            tabWidth: layout.tabWidth,
            tabCount: visibleCount)
        drag = TabDrag(tabID: tabID, fromIndex: visibleIndex, translation: translation, slot: slot)
    }

    private func dragEnded(tabID: UUID, visibleIndex: Int, translation: CGFloat,
                           layout: TabBarLayout, visible: [EditorTab]) {
        let slot = TabBarLayout.insertionIndex(
            fromIndex: visibleIndex,
            dragOffset: translation,
            tabWidth: layout.tabWidth,
            tabCount: visible.count)
        drag = nil
        // Map the visible-order slot onto the store's tab order. The two differ
        // only when the active tab is pinned into the last visible slot past an
        // overflow window, so anchor on neighbor tab IDs rather than raw indexes.
        guard let fromStore = store.tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let target: Int
        if slot < visible.count, let anchor = store.tabs.firstIndex(where: { $0.id == visible[slot].id }) {
            target = TabBarLayout.targetIndex(fromIndex: fromStore, slot: anchor)
        } else if let last = visible.last,
                  let lastStore = store.tabs.firstIndex(where: { $0.id == last.id }) {
            // Past the end of the visible strip: land right after the last
            // visible tab.
            target = lastStore >= fromStore ? lastStore : lastStore + 1
        } else {
            return
        }
        store.moveTab(id: tabID, to: target)
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
    /// Distance the pointer must travel before a press on a tab becomes a
    /// reorder drag instead of a click (#1388).
    static let dragStartDistance: CGFloat = 4
    /// Width of the accent insertion line shown at the drop slot mid-drag.
    static let insertionIndicatorWidth: CGFloat = 2
    /// Vertical inset so the insertion line doesn't touch the strip's edges.
    static let insertionIndicatorVerticalInset: CGFloat = 6
    /// Lift shadow on the dragged tab (solid background + shadow = the macOS
    /// "picked up" look, #1388).
    static let dragLiftShadowRadius: CGFloat = 4
    static let dragLiftShadowY: CGFloat = 2
}
