import SwiftUI
import WikiFSCore

/// Horizontal tab strip at the top of the detail pane. Tabs share the available
/// width evenly, shrinking from `maxTabWidth` toward `minTabWidth` as more open.
/// Once even the minimum won't fit, the strip shows as many tabs as fit plus a
/// `⌄` overflow menu listing every open tab. The active tab is always kept
/// visible (pinned into the last visible slot if it would otherwise overflow).
///
/// Tabs reorder by press-and-drag (#1388), Safari-style: the dragged tab rides
/// with the cursor and its neighbors SLIDE ASIDE live as its center crosses
/// theirs. The store is touched once, on drop — mid-drag reordering happens in
/// local state so observers (ContentView's editor subtree) don't re-render per
/// drag event.
struct TabBarView: View {
    @Bindable var store: WikiStoreModel

    /// In-flight drag-to-reorder (#1388). `nil` when no drag is active.
    @State private var drag: TabDrag?

    private struct TabDrag: Equatable {
        let tabID: UUID
        /// Pointer x − tab leading edge, captured at grab. Keeps the tab glued
        /// to the cursor at the point it was grabbed.
        let grabOffset: CGFloat
        /// Tab width at grab time (immune to mid-drag layout changes).
        let tabWidth: CGFloat
        /// Current pointer x in strip coordinates.
        var pointerX: CGFloat
        /// Live visible-order tab IDs; neighbors slide as this reorders.
        var order: [UUID]
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
            let displayed = displayedTabs(visible)

            HStack(spacing: 0) {
                ForEach(Array(displayed.enumerated()), id: \.element.id) { index, tab in
                    let isDragged = drag?.tabID == tab.id
                    TabBarItemView(
                        tab: tab,
                        isActive: tab.id == store.activeTabID,
                        isDragged: isDragged,
                        iconName: store.tabIcon(for: tab.selection),
                        width: layout.tabWidth,
                        onClick: { store.selectTab(id: tab.id) },
                        onTogglePin: { store.toggleTabPin(id: tab.id) },
                        onClose: { store.closeTab(id: tab.id) },
                        onCloseOthers: { store.closeOtherTabs(id: tab.id) },
                        onCloseAfter: { store.closeTabsAfter(id: tab.id) },
                        onCloseAll: { store.closeAllTabs() },
                        onDragChanged: { value in
                            dragChanged(value, tabID: tab.id, visibleIndex: index,
                                        layout: layout, visible: displayed)
                        },
                        onDragEnded: { value in
                            dragEnded(value, tabID: tab.id, visible: displayed)
                        }
                    )
                    // The dragged tab rides with the cursor above its
                    // neighbors; its layout-position animation is suppressed so
                    // the offset correction cancels the slot change exactly.
                    .offset(x: dragOffset(for: tab.id, at: index))
                    .zIndex(isDragged ? 1 : 0)
                    .transaction { tx in
                        if isDragged { tx.animation = nil }
                    }
                }
                if layout.showsOverflow {
                    overflowMenu
                }
                Spacer(minLength: 0)
            }
            .coordinateSpace(name: TabBarMetrics.stripCoordinateSpace)
            .padding(.horizontal, TabBarMetrics.horizontalPadding)
        }
        .frame(height: TabBarMetrics.height)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider().opacity(PageEditorMetrics.dividerOpacity)
        }
        // Defensive reset: if the dragged tab vanishes mid-drag (closed
        // externally, window deactivation skipping onEnded), drop the drag
        // state rather than stranding a tab at an offset.
        .onChange(of: store.tabs) { _, tabs in
            let tabIDs = Set(tabs.map(\.id))
            if let drag,
               !tabIDs.contains(drag.tabID) || !Set(drag.order).isSubset(of: tabIDs) {
                self.drag = nil
            }
        }
        .onChange(of: store.activeTabID) { _, _ in
            // The visible window can change when the active tab is pinned into
            // an overflow slot. Its displayed order is no longer the order
            // captured at drag start, so cancel rather than commit stale math.
            if drag != nil { drag = nil }
        }
    }

    /// Horizontal offset gluing the dragged tab to the cursor: desired
    /// leading edge (pointerX − grabOffset) minus its current home slot.
    private func dragOffset(for tabID: UUID, at index: Int) -> CGFloat {
        guard let drag, drag.tabID == tabID else { return 0 }
        return drag.pointerX - drag.grabOffset - CGFloat(index) * drag.tabWidth
    }

    /// The order to draw. Mid-drag, the drag's live order wins (looked up
    /// against ALL tabs so the dragged tab can't fall out of the strip when
    /// the active tab is pinned into the last visible slot past an overflow
    /// window). If the tab set changed externally since the grab, the drag is
    /// stale — ignore it.
    private func displayedTabs(_ visible: [EditorTab]) -> [EditorTab] {
        guard let drag else { return visible }
        guard Set(drag.order) == Set(visible.map(\.id)) else { return visible }
        let byID = Dictionary(store.tabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return drag.order.compactMap { byID[$0] }
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

    // MARK: - Drag-to-reorder (#1388)

    private func dragChanged(_ value: DragGesture.Value, tabID: UUID, visibleIndex: Int,
                             layout: TabBarLayout, visible: [EditorTab]) {
        if drag?.tabID != tabID {
            // First event of the drag: capture home, grab offset, and the
            // visible order ONCE — rebuilding these per event would let the
            // tab's own reorder shift the reference frame out from under the
            // math.
            drag = TabDrag(
                tabID: tabID,
                grabOffset: value.location.x - CGFloat(visibleIndex) * layout.tabWidth,
                tabWidth: layout.tabWidth,
                pointerX: value.location.x,
                order: visible.map(\.id))
            return
        }
        guard let current = drag,
              current.tabID == tabID,
              Set(current.order) == Set(visible.map(\.id)) else {
            drag = nil
            return
        }
        drag?.pointerX = value.location.x
        guard let index = current.order.firstIndex(of: tabID) else { return }
        let center = Double(current.pointerX - current.grabOffset) + Double(current.tabWidth) / 2
        let target = TabBarLayout.liveSlot(
            currentIndex: index,
            centerX: center,
            tabWidth: Double(current.tabWidth),
            tabCount: current.order.count)
        guard target != index else { return }
        withAnimation(.easeOut(duration: TabBarMetrics.reorderAnimationDuration)) {
            drag?.order.move(fromOffsets: IndexSet(integer: index),
                             toOffset: target > index ? target + 1 : target)
        }
    }

    private func dragEnded(_ value: DragGesture.Value, tabID: UUID, visible: [EditorTab]) {
        guard let current = drag, current.tabID == tabID,
              let fromStore = store.tabs.firstIndex(where: { $0.id == tabID }),
              let finalIndex = current.order.firstIndex(of: tabID) else {
            drag = nil
            return
        }
        drag = nil
        // Map the final visible-order position onto the store's tab order,
        // anchored on neighbor tab IDs (the orders differ when the active tab
        // is pinned into the last visible slot past an overflow window).
        let target: Int
        if finalIndex < current.order.count - 1,
           let anchor = store.tabs.firstIndex(where: { $0.id == current.order[finalIndex + 1] }) {
            target = TabBarLayout.targetIndex(fromIndex: fromStore, slot: anchor)
        } else if finalIndex > 0,
                  let prev = store.tabs.firstIndex(where: { $0.id == current.order[finalIndex - 1] }) {
            // Last in the visible strip: land right after the previous tab.
            target = prev >= fromStore ? prev : prev + 1
        } else {
            return
        }
        store.moveTab(id: tabID, to: target)
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
    /// Named coordinate space for the strip: drag gestures resolve pointer
    /// positions here so a mid-drag reorder doesn't shift the reference frame.
    static let stripCoordinateSpace = "tabStrip"
    /// Neighbor slide duration on a live reorder. Short and non-springy so
    /// fast drags don't stack overlapping animations.
    static let reorderAnimationDuration: Double = 0.15
    /// Lift shadow on the dragged tab (solid background + shadow = the macOS
    /// "picked up" look, #1388).
    static let dragLiftShadowRadius: CGFloat = 4
    static let dragLiftShadowY: CGFloat = 2
}
