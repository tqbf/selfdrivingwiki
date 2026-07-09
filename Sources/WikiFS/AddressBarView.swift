import AppKit
import SwiftUI
import WikiFSCore

/// A Safari-style omnibox that lives in the window's **toolbar** (a principal
/// toolbar item), replacing the window title. Serves two roles depending on
/// focus state — no explicit mode switch required:
///
/// 1. **Idle (not focused):** shows the active page's wikilink (`[[Page Title]]`)
///    as the field's text — the "where am I" indicator, like a browser URL bar.
/// 2. **Focused / typing:** semantic search. Typing debounces into
///    `store.searchSimilar(query:)` and shows a ranked suggestions panel below
///    the field. Selecting a result (or pressing Enter) navigates to it.
///
/// The editable field is an AppKit `NSSearchField` (`OmniboxSearchField`) —
/// SwiftUI `TextField` can't take first responder inside an `NSToolbar` item —
/// and the suggestions live in a non-activating child panel.
struct AddressBarView: View {
    @Bindable var store: WikiStoreModel
    @Binding var isFocused: Bool
    /// The active wiki's display name, shown in the trailing switcher. A longer
    /// name widens that switcher, so the omnibox reserves extra room for it and
    /// shrinks — keeping the switcher on-screen instead of overflowing.
    var wikiName: String
    /// The width of the detail column (the region the toolbar spans), measured by a
    /// `GeometryReader` in `ContentView`. This shrinks when the left sidebar opens
    /// and is unaffected by the right transcript panel — exactly the omnibox's
    /// usable toolbar span. Measuring the detail region (never in toolbar overflow)
    /// instead of the field's own leading edge (which overflow strands) is what
    /// keeps the width from getting stuck. See `OmniboxLayout`.
    var detailWidth: CGFloat
    /// Whether the left sidebar is shown. Selects the fixed leading chrome ahead of
    /// the field (`OmniboxLayout.leadingChrome`): with the sidebar hidden the detail
    /// region spans the whole window and includes the traffic-light + toggle zone.
    var sidebarVisible: Bool
    /// The active wiki's configured home page (issue #280). `nil` hides the home
    /// button — there's nowhere to navigate to yet.
    var homePageID: PageID?

    @State private var queryText = ""
    @State private var results: [WikiPageSummary] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var focusToken = 0
    /// Pointer is over the omnibox — reveals the trailing "add to bookmarks" plus.
    @State private var isHovering = false
    @State private var showReaderMenu = false
    /// The shared find model (injected via environment by `ContentView`). The
    /// "Find on Page…" menu item toggles this, matching Cmd+F in the detail
    /// views — both drive the same `FindBarView` overlay (issue #157).
    @Environment(FindModel.self) private var findModel
    /// Fired when the omnibox "+" is clicked. `ContentView` presents the
    /// `BookmarkTargetPickerSheet` (sheets can't be reliably presented from a
    /// toolbar item's SwiftUI hierarchy).
    var onAddToBookmarks: (BookmarkTargetPickerContext) -> Void

    // The reader/page zoom is a persisted global (`@AppStorage`), so the toolbar
    // can drive the same value the detail views read — no binding to thread.
    @AppStorage("reader.zoom") private var readerZoom = Double(ZoomScale.defaultScale)

    var body: some View {
        // Back / Forward + the omnibox are one `.navigation` group, flush-left in
        // the detail region. The nav buttons are fixed-width; the field is given an
        // explicit width (`fieldWidth`) so it stretches from just after them to the
        // trailing wiki switcher, shrinking as the window narrows / the wiki name
        // grows and expanding once the switcher overflows (see `OmniboxLayout`).
        HStack(spacing: 6) {
            navButton("chevron.left", help: "Go back", enabled: store.canNavigateBack) {
                store.navigateBack()
            }
            .keyboardShortcut("[", modifiers: .command)

            navButton("chevron.right", help: "Go forward", enabled: store.canNavigateForward) {
                store.navigateForward()
            }
            .keyboardShortcut("]", modifiers: .command)

            if let homePageID {
                navButton("house", help: "Go to home page", enabled: true) {
                    _ = store.selectPage(byID: homePageID)
                }
            }

            omniboxField
        }
        // Cmd-L flips `isFocused`; turn that into a focus request for the field.
        .onChange(of: isFocused) { _, focused in
            if focused { focusToken &+= 1 }
        }
        // Empty state (no content loaded): focus the field so the user can type
        // a search immediately — at launch and whenever the last tab closes.
        .onAppear { focusIfEmpty() }
        .onChange(of: hasContentLoaded) { _, loaded in
            if !loaded { focusIfEmpty() }
        }
    }

    /// The search field itself, sized to fill from its leading edge to the switcher.
    private var omniboxField: some View {
        OmniboxSearchField(
            text: $queryText,
            locationText: addressString,
            results: results,
            focusToken: focusToken,
            onTextChange: { runSearch(query: $0) },
            onSubmit: submitTopResult,
            onEscape: cancel,
            onBlur: handleBlur,
            onSelect: navigate,
            // Reserve the "+" gap whenever a page/source is shown (not just on
            // hover) so the text has a stable position and the "+" fades into
            // the reserved space.
            textLeadingInset: bookmarkTarget != nil
                ? AddressBarMetrics.textLeadingInsetWithBookmark
                : AddressBarMetrics.textLeadingInset
        )
        // Explicit, measurement-driven width: stretches to the switcher and
        // reclaims its space when it overflows.
        .frame(width: fieldWidth)
        // The Page Menu icon and add-bookmark "+" live inside the pill on the
        // leading edge (Safari-style), inset from the rounded left edge. The
        // field's text is inset to match (see `AddressSearchFieldCell`).
        .overlay(alignment: .leading) {
            HStack(spacing: 4) {
                if hasContentLoaded {
                    readerMenuButton
                    // Reserve the "+" slot whenever a page/source is showing so the
                    // text doesn't jump; reveal it on hover.
                    if let target = bookmarkTarget {
                        addBookmarkButton(target)
                            .opacity(isHovering ? 1 : 0)
                            .allowsHitTesting(isHovering)
                    }
                } else {
                    // Empty state (no content loaded): a plain search glyph in the
                    // slot the Page Menu would occupy, signalling the bar's role.
                    searchGlyph
                }
            }
            .padding(.leading, AddressBarMetrics.iconLeadingInset)
        }
        // Hover anywhere in the pill so moving onto the "+" keeps it visible.
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
        }
    }

    /// A toolbar-styled chevron button for Back / Forward, rendered inside the
    /// principal group (so it needs its own borderless styling to read as a
    /// toolbar control rather than a bordered push button).
    private func navButton(_ symbol: String, help: String, enabled: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 22, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.35))
        .disabled(!enabled)
        .help(help)
    }

    // MARK: - Reader menu (Safari-style page controls)

    /// The leading page-menu button (Safari's "Page Menu" glyph); opens a
    /// dropdown with Zoom and Find on Page.
    private var readerMenuButton: some View {
        Button {
            showReaderMenu.toggle()
        } label: {
            Image(systemName: "text.page.badge.magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Page controls")
        .popover(isPresented: $showReaderMenu, arrowEdge: .bottom) {
            ReaderControlsMenu(zoom: $readerZoom, onFind: findOnPage)
        }
    }

    /// The leading glyph shown in the empty state (no content loaded): a plain
    /// magnifier where the Page Menu would sit, signalling the bar is a search.
    private var searchGlyph: some View {
        Image(systemName: "magnifyingglass")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 22)
    }

    /// The "+" affordance shown on hover when a bookmarkable page or source is
    /// showing. Click adds it to the Bookmarks root.
    private func addBookmarkButton(_ target: BookmarkTarget) -> some View {
        Button {
            addToBookmarks(target)
        } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Add to Bookmarks")
        .transition(.opacity)
    }

    /// The omnibox field's width, from the measured detail-region width, the sidebar
    /// state, and the wiki name. The arithmetic (stretch, shrink, overflow-expand)
    /// lives in `OmniboxLayout` so it can be unit-tested; here we only supply the
    /// measurements. `switcherExtra` is how much wider the current wiki name renders
    /// than the baseline name — the switcher's fixed icon/chevron overhead cancels
    /// out, so only text width matters.
    private var fieldWidth: CGFloat {
        let switcherExtra = headlineTextWidth(wikiName)
            - headlineTextWidth(AddressBarMetrics.baselineSwitcherName)
        return OmniboxLayout.fieldWidth(
            detailWidth: detailWidth,
            sidebarVisible: sidebarVisible,
            switcherExtra: switcherExtra)
    }

    /// Rendered width of `text` in the switcher's font (`.headline`). Only the
    /// *difference* from the baseline name is used, so the switcher's fixed
    /// icon/chevron overhead cancels out and this need only be accurate for the text.
    private func headlineTextWidth(_ text: String) -> CGFloat {
        let font = NSFont.preferredFont(forTextStyle: .headline)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    // MARK: - Actions

    /// In the empty state (no content loaded), request field focus so the user
    /// can begin typing a search immediately.
    private func focusIfEmpty() {
        guard !hasContentLoaded else { return }
        focusToken &+= 1
    }

    private func runSearch(query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return }
            results = store.searchSimilar(query: trimmed, limit: 8)
        }
    }

    private func submitTopResult() {
        guard let first = results.first else { return }
        navigate(to: first)
    }

    private func navigate(to result: WikiPageSummary) {
        store.selectPage(byTitle: result.title)
        queryText = ""
        results = []
        isFocused = false
    }

    private func cancel() {
        queryText = ""
        results = []
        isFocused = false
    }

    /// The field lost focus to another responder — snap back to the idle
    /// location display.
    private func handleBlur() {
        queryText = ""
        results = []
        isFocused = false
    }

    // MARK: - Bookmark / find actions

    private enum BookmarkTarget {
        case page(PageID)
        case source(PageID)
        case chat(PageID)
    }

    /// The current selection, when it's something that can be bookmarked (a page,
    /// a source, or a chat). Non-bookmarkable selections (log, ask, …) return
    /// `nil` so no plus appears.
    private var bookmarkTarget: BookmarkTarget? {
        switch store.activeTab?.selection {
        case .page(let id): return .page(id)
        case .source(let id): return .source(id)
        case .chat(let id): return .chat(id)
        default: return nil
        }
    }

    private func addToBookmarks(_ target: BookmarkTarget) {
        switch target {
        case .page(let id):
            onAddToBookmarks(BookmarkTargetPickerContext(kind: .pages, ids: [id]))
        case .source(let id):
            onAddToBookmarks(BookmarkTargetPickerContext(kind: .sources, ids: [id]))
        case .chat(let id):
            onAddToBookmarks(BookmarkTargetPickerContext(kind: .chats, ids: [id]))
        }
    }

    /// Open the find bar by toggling the shared `FindModel` — the same model
    /// Cmd+F toggles inside the active detail view. Previously this sent the
    /// legacy `performTextFinderAction` down the responder chain, which no view
    /// implemented, so the menu item was a no-op (issue #157).
    private func findOnPage() {
        showReaderMenu = false
        findModel.toggle()
    }

    // MARK: - Address string

    /// Whether readable content (a page, source, chat, or document) is loaded in
    /// the active tab. When false (no tab, or a non-content selection), the bar is
    /// in its empty / search-first state: a leading search glyph, auto-focus, and
    /// the "Search for pages" placeholder.
    private var hasContentLoaded: Bool {
        !addressString.isEmpty
    }

    /// Resolves the active selection to its wikilink notation. Non-page
    /// selections (source, chat, …) show a best-effort pseudo-wikilink so the
    /// bar is never blank when something is open.
    private var addressString: String {
        guard let selection = store.activeTab?.selection else { return "" }
        switch selection {
        case .page(let id):
            let title = store.summaries.first { $0.id == id }?.title ?? ""
            return title.isEmpty ? "" : "[[\(title)]]"
        case .source(let id):
            let name = store.sources.first { $0.id == id }?.effectiveName ?? ""
            return name.isEmpty ? "" : "[[source:\(name)]]"
        case .systemPrompt:
            return "[[system-prompt]]"
        case .changeLog:
            return "[[log]]"
        case .ask:
            return "[[ask]]"
        case .edit:
            return "[[edit]]"
        case .lint:
            return "[[lint]]"
        case .bookmark:
            return ""
        case .chat(let id):
            let title = store.chats.first { $0.id == id }?.title ?? ""
            return title.isEmpty ? "" : "[[chat:\(title)]]"
        }
    }
}

// MARK: - Suggestions list

/// The ranked results list shown in the omnibox suggestions panel. Rows
/// highlight on hover (accent tint) and the top row shows a `↩` glyph — the
/// Enter target.
struct AddressResultsList: View {
    let results: [WikiPageSummary]
    /// The arrow-key-selected row, pushed in from the AppKit coordinator. `nil`
    /// means nothing is explicitly selected and Enter targets the top row.
    let selectedIndex: Int?
    let onSelect: (WikiPageSummary) -> Void

    @State private var hoveredResultID: PageID?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                row(result, index: index)
                if result.id != results.last?.id {
                    Divider()
                        .padding(.leading, 34)
                        .opacity(0.25)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func row(_ result: WikiPageSummary, index: Int) -> some View {
        let hovered = hoveredResultID == result.id
        let keyboardSelected = selectedIndex == index
        // The keyboard highlight yields to the mouse: once the pointer is over a
        // row, that row wins, so hover and arrow selection don't fight.
        let highlighted = hovered || (hoveredResultID == nil && keyboardSelected)
        // Enter targets the arrow-selected row, or the top row when nothing is.
        let isEnterTarget = keyboardSelected || (selectedIndex == nil && index == 0)
        Button {
            onSelect(result)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.caption)
                    .foregroundStyle(highlighted ? Color.accentColor : .secondary)
                    .frame(width: 16)
                Text(result.title)
                    .lineLimit(1)
                    .font(.callout)
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
                hoveredResultID = result.id
            } else if hoveredResultID == result.id {
                hoveredResultID = nil
            }
        }
    }
}

// MARK: - Metrics

enum AddressBarMetrics {
    /// The wiki-switcher name the trailing reservation is tuned against. A name
    /// wider than this reserves the extra width (the omnibox yields it); a narrower
    /// one lets the omnibox reclaim it. Only the width *difference* is used, so the
    /// switcher's fixed icon/chevron overhead cancels out. See `OmniboxLayout`.
    static let baselineSwitcherName = "My Wiki"
    /// Left padding from the pill's rounded edge to the Page Menu icon, so the
    /// icon sits inside the omnibox rather than hugging the edge.
    static let iconLeadingInset: CGFloat = 8
    /// Where the field's editable text begins when nothing bookmarkable is shown
    /// — clears just the Page Menu icon.
    static let textLeadingInset: CGFloat = 28
    /// Text inset while a page/source is shown: leaves a persistent gap after the
    /// Page Menu icon for the add-bookmark "+" (revealed on hover), so the text
    /// doesn't shift when it appears.
    static let textLeadingInsetWithBookmark: CGFloat = 54
}

// MARK: - Reader controls popover

/// Safari-style page-controls dropdown: a Zoom row (with a −/+ stepper) and a
/// highlightable "Find on Page…" row, styled like the reader menu in Safari.
/// Zoom writes the shared `reader.zoom` value the detail views render from.
private struct ReaderControlsMenu: View {
    @Binding var zoom: Double
    let onFind: () -> Void

    @State private var findHovered = false

    private var percent: Int { Int((zoom * 100).rounded()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Zoom row — leading icon, label, and a stepper on the trailing edge.
            HStack(spacing: 0) {
                menuIcon("plus.magnifyingglass")
                Text("Zoom")
                Spacer(minLength: 16)
                HStack(spacing: 2) {
                    stepButton("minus", help: "Zoom Out") {
                        zoom = Double(ZoomScale.zoomedOut(CGFloat(zoom)))
                    }
                    // Tap the percentage to snap back to Actual Size.
                    Button { zoom = Double(ZoomScale.defaultScale) } label: {
                        Text("\(percent)%")
                            .monospacedDigit()
                            .frame(minWidth: 42)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Actual Size")
                    stepButton("plus", help: "Zoom In") {
                        zoom = Double(ZoomScale.zoomedIn(CGFloat(zoom)))
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()
                .padding(.horizontal, 8)
                .padding(.vertical, 2)

            // Find on Page row — a full-width menu item that highlights on hover.
            Button(action: onFind) {
                HStack(spacing: 0) {
                    menuIcon("text.magnifyingglass")
                    Text("Find on Page…")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(findHovered ? Color.accentColor : Color.clear))
                .foregroundStyle(findHovered ? Color.white : Color.primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { findHovered = $0 }
        }
        .font(.system(size: 13))
        .padding(6)
        .frame(width: 260)
    }

    /// A fixed-width leading glyph so labels align in a column, menu-style.
    private func menuIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(width: 26, alignment: .leading)
    }

    private func stepButton(_ symbol: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
