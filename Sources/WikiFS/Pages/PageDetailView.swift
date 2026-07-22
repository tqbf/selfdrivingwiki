import SwiftUI
import WikiFSEngine
import WikiFSCore

/// Unified page surface. The header (title, date, action buttons) stays fixed
/// regardless of mode. The content area below the divider swaps between rendered
/// markdown and the monospaced source editor. Save/Cancel appear inline in the
/// header — same position as the Edit / Copy Path buttons they replace.
struct PageDetailView: View {
    @Bindable var store: WikiStoreModel
    @Bindable var launcher: AgentLauncher
    /// The per-active-wiki session (store + launchers + descriptor).
    var session: WikiSession
    let fileProvider: FileProviderFacade
    @State private var isEditing = false
    /// Pending scroll-to-heading for the editor (outline click while editing).
    @State private var editorScrollRequest: EditorScrollRequest?
    /// Caret position in the editor, for outline cursor tracking (issue #268).
    @State private var caretCharIndex: Int?
    /// Tracks the active tab ID at the end of the last resolved update cycle.
    /// Used to distinguish tab switches (activeTabID changes) from in-tab
    /// navigation (activeTabID stays, selection changes) when deciding whether
    /// to reset or restore edit mode.
    @State private var lastKnownActiveTabID: UUID? = nil
    @AppStorage("editor.zoom") private var editorZoom = Double(ZoomScale.defaultScale)
    @AppStorage("reader.zoom") private var readerZoom = Double(ZoomScale.defaultScale)
    @AppStorage("isOutlineExpanded") private var isOutlineExpanded = false
    @AppStorage("pageInspectorTab") private var inspectorTab: InspectorTab = .outline
    @AppStorage("pageOutlineWidth") private var outlineWidth: Double = 260
    /// Per-view collapse state for the header. Starts collapsed; persists
    /// across same-type tab switches (SwiftUI keeps the view alive).
    @State private var isHeaderExpanded = false
    /// Provenance for the inspector's History tab. Loaded via `.task(id:)`
    /// keyed on `currentPageID` so it re-fires on page navigation.
    @State private var provenanceOrigin: PageOrigin?
    @State private var provenanceHistory: [PageOrigin] = []

    // Find bar state. The model is shared (hoisted to `ContentView` and injected
    // via environment) so the address bar's "Find on Page…" menu item can drive
    // the same find bar that Cmd+F toggles here (issue #157).
    @Environment(FindModel.self) private var findModel
    @State private var findVersion = 0

    /// The app-wide queue activity tracker — used to reflect an in-flight lint
    /// on this page's "Lint" button (icon + disable + warning when tapped).
    @Environment(QueueActivityTracker.self) private var activityTracker
    /// Shown when the Lint button is tapped while a lint is already running on
    /// this page (whole-wiki or page-level). Explains the running state rather
    /// than silently enqueuing a duplicate.
    @State private var isShowingLintActiveAlert = false
    /// Opens the value-driven Versions `WindowGroup` (#817). Captured from the
    /// environment (only available inside a `WindowGroup`'s view hierarchy).
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — title always visible; date + provenance expandable.
            //
            // The action toolbar (Save/Cancel/Edit/Lint/Show in List/Share/
            // Reveal in Finder + outline toggle) is rendered as a SIBLING of
            // CollapsibleDetailHeader — NOT inside its content closure (which
            // constrains expanded content to readableContentWidth). The
            // sibling row spans the full view width so the trailing
            // Spacer/outline toggle reach the view's right edge instead of
            // the readable-column edge. This mirrors the ChatView reference
            // pattern (Sources/WikiFS/Chats/ChatView.swift:670-710); both
            // rows are gated on `isHeaderExpanded` for collapse behavior.
            VStack(alignment: .leading, spacing: PageEditorMetrics.sectionSpacing) {
                CollapsibleDetailHeader(
                    systemImage: ResourceKind.page.systemImageName,
                    title: store.draftTitle,
                    isExpanded: $isHeaderExpanded,
                    onTitleCommit: renameCurrentPage
                ) {
                    VStack(alignment: .leading, spacing: PageEditorMetrics.sectionSpacing) {
                        HStack(spacing: 12) {
                            if let date = pageUpdatedAt {
                                Text(date, style: .date)
                            }
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }

                if isHeaderExpanded {
                    pageActionBar
                        .frame(maxWidth: .infinity)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, PageEditorMetrics.contentInset)
            .padding(.top, PageEditorMetrics.contentInset)
            .padding(.bottom, PageEditorMetrics.sectionSpacing)

            Divider().opacity(PageEditorMetrics.dividerOpacity)

            // Non-blocking hints: a saved draft with a broken ```mermaid block
            // and/or cosmetic markdown issues. Surfaced on save; clear once the
            // issues are fixed and re-saved. Combined into a single banner when
            // both are present to avoid stacked notification noise.
            saveWarningBanner

            contentAndOutline
        }
        .background(Color(nsColor: .textBackgroundColor))
        .frame(minWidth: PageEditorMetrics.detailMinWidth)
        .alert("Lint Already Running", isPresented: $isShowingLintActiveAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("A lint job is already running on this page. It will appear in the Activity window when it finishes.")
        }
        .onAppear {
            lastKnownActiveTabID = store.activeTabID
            // Seed edit mode from the active tab on first mount. `.onChange(of:
            // store.activeTabID)` below only fires on *subsequent* tab switches,
            // so without this a freshly-created "start in editor" tab would
            // render the preview branch on first paint. Safe for navigation:
            // navigation-opened tabs default to `isEditing == false`.
            let editing = store.activeTab?.isEditing ?? false
            isEditing = editing
            // Ensure the header is expanded in the *first* paint when seeding
            // edit mode — `.onChange(of: isEditing)` may not fire synchronously
            // for a write made during `.onAppear`, and the editor branch needs
            // the Save/Cancel row visible immediately (defense in depth).
            if editing { isHeaderExpanded = true }
        }
        .onChange(of: store.selection) {
            // In-tab navigation (wiki-link click, sidebar navigation within the
            // same tab): exit edit mode. Tab switches are detected below via
            // activeTabID and restore per-tab state instead of always resetting.
            if store.activeTabID == lastKnownActiveTabID {
                isEditing = false
            }
        }
        .onChange(of: store.activeTabID) { _, newID in
            lastKnownActiveTabID = newID
            let tab = store.tabs.first(where: { $0.id == newID })
            isEditing = tab?.isEditing ?? false
        }
        .onChange(of: isEditing) { _, newValue in
            if let id = store.activeTabID {
                store.setTabEditing(tabID: id, isEditing: newValue)
            }
            if newValue { isHeaderExpanded = true } // reveal Save/Cancel
            if !newValue { caretCharIndex = nil }
        }
        .background { findShortcutButton }
        .overlay(alignment: .top) { findBarOverlay }
        .onChange(of: store.selection) { findModel.dismiss() }
        .onChange(of: store.draftBody) { _, newMarkdown in
            findModel.content = newMarkdown
            findModel.search()
        }
        .onChange(of: findModel.isShowing) { _, showing in
            if showing {
                findModel.content = store.draftBody
                findModel.search()
            }
        }
        .onChange(of: findModel.currentMatchIndex) { _, _ in
            guard findModel.currentMatchIndex > 0 else { return }
            findVersion &+= 1
        }
        .task(id: currentPageID) {
            guard let pageID = currentPageID else {
                provenanceOrigin = nil
                provenanceHistory = []
                return
            }
            provenanceOrigin = store.pageOrigin(for: pageID)
            provenanceHistory = store.pageEditHistory(for: pageID)
        }
        .alert(
            "Title Already Exists",
            isPresented: Binding(
                get: { store.renameConflictingTitle != nil },
                set: { if !$0 { store.clearRenameConflict() } }
            )
        ) {
            Button("OK", role: .cancel) { store.clearRenameConflict() }
        } message: {
            if let title = store.renameConflictingTitle {
                Text("A page with the title “\(title)” already exists. Please choose a different name.")
            }
        }
    }

    // MARK: - Header action bar (full-width toolbar row)

    /// The page detail action toolbar row. Rendered as a sibling of
    /// `CollapsibleDetailHeader` — NOT inside its expanded content — so this
    /// HStack spans the FULL view width. The trailing
    /// `Spacer(minLength: 0)`/`Spacer` therefore pushes the outline toggle
    /// all the way to the view's right edge (mirrors `ChatView.chatActionBar`).
    @ViewBuilder
    private var pageActionBar: some View {
        HStack(spacing: 10) {
            if isEditing {
                Button("Save Changes", systemImage: "checkmark.circle") {
                    DebugLog.tabs("PageDetailView: Save Changes tapped")
                    commitEdit()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(store.draftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Cancel", systemImage: "xmark.circle") {
                    DebugLog.tabs("PageDetailView: Cancel tapped")
                    cancelEdit()
                }
                .keyboardShortcut(.escape, modifiers: [])

                // Pin action buttons at the leading edge and the
                // outline toggle at the trailing edge so the row's
                // layout is independent of the parent's proposed width
                // (which changes when the outline pane or the header
                // expands/collapses — keeps "Show in List" and friends
                // in a fixed position).
                Spacer()
                Button {
                    DebugLog.tabs("PageDetailView: Toggle Inspector tapped (editing)")
                    isOutlineExpanded.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help("Toggle Inspector")
            } else {
                Button("Edit",
                       systemImage: "pencil") {
                    DebugLog.tabs("PageDetailView: Edit tapped")
                    isEditing = true
                }
                    .help("Edit this page manually")
                if case .page = store.selection {
                    lintButton
                }
                if case .page(let pageID) = store.selection {
                    Button("Show in List", systemImage: "sidebar.left") {
                        DebugLog.tabs("PageDetailView: Show in List tapped — id=\(pageID.rawValue)")
                        store.requestSidebarReveal(.page(pageID))
                    }
                    .help("Reveal this page in the sidebar")
                }
                if fileProvider.path != nil, case .page(let pageID) = store.selection {
                    Button("Share", systemImage: "square.and.arrow.up") {
                        DebugLog.fileprovider("PageDetailView: Share tapped — id=\(pageID.rawValue)")
                        Task {
                            guard let url = await fileProvider.resolvePageByTitleURL(id: pageID, wikiID: session.wikiID) else {
                                DebugLog.fileprovider("Share page detail: resolvePageByTitleURL returned nil — id=\(pageID.rawValue) wikiID=\(session.wikiID)")
                                return
                            }
                            DebugLog.fileprovider("Share page detail: \(url.lastPathComponent)")
                            let picker = NSSharingServicePicker(items: [url])
                            let mouseScreen = NSEvent.mouseLocation
                            guard let window = NSApplication.shared.keyWindow,
                                  let contentView = window.contentView else { return }
                            let windowPoint = window.convertPoint(fromScreen: mouseScreen)
                            let viewPoint = contentView.convert(windowPoint, from: nil)
                            picker.show(
                                relativeTo: NSRect(origin: viewPoint,
                                                   size: NSSize(width: 1, height: 1)),
                                of: contentView, preferredEdge: .minY)
                        }
                    }
                    .help("Share this page")
                    Button("Reveal in Finder", systemImage: "folder") {
                        DebugLog.fileprovider("PageDetailView: Reveal in Finder tapped — id=\(pageID.rawValue)")
                        Task { await fileProvider.revealPageInFinder(id: pageID, wikiID: session.wikiID) }
                    }
                    .help("Reveal this page file in Finder")
                }
                // Pin action buttons at the leading edge and the outline
                // toggle at the trailing edge (see the matching comment
                // in the editing branch above).
                Spacer()
                Button {
                    DebugLog.tabs("PageDetailView: Toggle Inspector tapped")
                    isOutlineExpanded.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help("Toggle Inspector")
            }
            }
            .frame(maxWidth: .infinity)
    }

    // MARK: - Lint button

    /// The page-level "Lint" action button. Reflects an in-flight lint on this
    /// page: when a lint (whole-wiki or page-level) is running, the button swaps
    /// to a filled "Linting…" state, disables itself, and would warn if tapped
    /// — though `.disabled` prevents the tap. The alert covers the keyboard /
    /// accessibility path where the action could still fire.
    @ViewBuilder
    private var lintButton: some View {
        if case .page(let id) = store.selection {
            let pageIsLinting = activityTracker.isLinting(
                pageID: id, wikiID: session.wikiID)
            Button(pageIsLinting ? "Linting…" : "Lint",
                   systemImage: pageIsLinting
                   ? "checkmark.seal.fill"
                   : "checkmark.seal") {
                if pageIsLinting {
                    // A lint is already active for this page (whole-wiki or
                    // page-level) — warn instead of enqueuing a duplicate.
                    isShowingLintActiveAlert = true
                    DebugLog.ingest("Lint button: already running for page \(id) in wiki \(session.wikiID.prefix(8)); warning shown")
                } else {
                    Task {
                        try? await session.queueEngine.enqueue(QueueItemRequest(
                            queue: .ingestion,
                            wikiID: session.wikiID,
                            payload: QueueItemPayload(sourceIDs: [], lintPageIDs: [id])
                        ))
                    }
                }
            }
            .disabled(pageIsLinting)
            .help(pageIsLinting
                  ? "A lint is already running on this page"
                  : "Fix [[wiki-link]] syntax and run LLM lint on this page")
        }
    }

    // MARK: - Content + Outline

    /// The main content area (reader or editor) plus the optional outline
    /// sidebar. Extracted from `body` so the type-checker can resolve each
    /// subtree independently.
    @ViewBuilder
    private var contentAndOutline: some View {
        HStack(spacing: 0) {
            Group {
                if isEditing {
                    editorContent
                } else {
                    readerContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if isOutlineExpanded {
                DetailInspectorView(
                    inspectorTab: $inspectorTab,
                    outlineWidth: $outlineWidth,
                    origin: provenanceOrigin?.provenanceEntry,
                    history: provenanceHistory.map(\.provenanceEntry),
                    store: store,
                    onCompareVersions: openVersionsWindow) {
                    PageOutlineView(markdown: store.draftBody,
                                    caretCharIndex: caretCharIndex) { heading in
                        if isEditing {
                            editorScrollRequest = EditorScrollRequest(
                                charOffset: heading.charOffset,
                                version: (editorScrollRequest?.version ?? 0) + 1)
                        } else {
                            store.jumpToAnchorInCurrentSelection(heading.id)
                        }
                    }
                }
            }
        }
    }

    private var editorContent: some View {
        ScrollableTextEditor(
            text: $store.draftBody,
            font: NSFont.monospacedSystemFont(
                ofSize: CGFloat(13 * editorZoom), weight: .regular),
            scrollRequest: editorScrollRequest,
            onCaretChange: { caretCharIndex = $0 },
            sidebarDropBuilder: { payloads in
                SidebarDropBuilder.insertionText(for: payloads, store: store)
            },
            // Issue #680: wiki-link autocomplete in the editor. Same hooks +
            // search backend as the chat composer (#684), re-pointed at the
            // editor's `ScrollableTextEditor`. Built from `store.tantivySearch`
            // so a wiki without one (no Tantivy service yet attached) gets
            // `nil` and the editor behaves as before.
            autocomplete: SidebarDropBuilder.wikiLinkAutocompleteHooks(store: store),
            autocompletePlacement: .below  // editor convention: tall NSTextView has more room below the caret
        )
        .padding(.horizontal, PageEditorMetrics.contentInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: PageEditorMetrics.editorMinHeight)
        .onChange(of: store.draftBody) { store.bodyChanged() }
        .zoomShortcuts($editorZoom)
        .zoomScroll($editorZoom)
    }

    private var readerContent: some View {
        WikiReaderView(markdown: store.draftBody,
                        currentSelection: store.selection,
                        store: store,
                        fileProvider: fileProvider,
                        findText: findText, findVersion: findVersion,
                        findOccurrence: findOccurrence)
            .frame(maxWidth: .infinity)
            .frame(minHeight: PageEditorMetrics.previewMinHeight)
            .zoomShortcuts($readerZoom)
            .zoomScroll($readerZoom)
    }

    // MARK: - Find bar

    @ViewBuilder
    private var findBarOverlay: some View {
        if findModel.isShowing {
            VStack(spacing: 0) {
                FindBarView(model: findModel)
                Divider()
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var findShortcutButton: some View {
        Button("") { findModel.toggle() }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0).allowsHitTesting(false)
    }

    // MARK: - Computed

    private var findText: String? {
        guard findModel.isShowing,
              let content = findModel.content,
              findModel.currentMatchIndex > 0,
              findModel.currentMatchIndex <= findModel.matches.count
        else { return nil }
        let range = findModel.matches[findModel.currentMatchIndex - 1]
        return String(content[range])
    }

    /// 1-based current match index, forwarded to the reader so next/previous
    /// navigation targets distinct occurrences instead of always the first.
    private var findOccurrence: Int { findModel.currentMatchIndex }

    private var displayTitle: String {
        store.draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled" : store.draftTitle
    }

    private var pageUpdatedAt: Date? {
        guard let selection = store.selection,
              case .page(let id) = selection else { return nil }
        return store.summaries.first(where: { $0.id == id })?.updatedAt
    }

    // MARK: - Inspector support

    /// The id of the page currently shown in this detail view — the key the
    /// `DetailInspectorView` uses to load provenance via
    /// `WikiStoreModel.pageOrigin(for:)` / `pageEditHistory(for:)`.
    private var currentPageID: PageID? {
        guard case .page(let id) = store.selection else { return nil }
        return id
    }

    /// Open the Versions window for the current page (#817). Injected into the
    /// inspector's `ProvenancePanel` as `onCompareVersions` (page-only). The
    /// `WindowGroup(for: PageVersionCompareContext.self)` dedups by pageID +
    /// wikiID, so re-opening focuses the existing window.
    private func openVersionsWindow() {
        guard let pageID = currentPageID else { return }
        let title = store.summaries.first { $0.id == pageID }?.title ?? ""
        openWindow(value: PageVersionCompareContext(
            pageID: pageID,
            title: title,
            wikiID: store.eventBus?.wikiID ?? ""))
    }

    // MARK: - Subviews

    @ViewBuilder private var saveWarningBanner: some View {
        let hasFrontmatter = store.draftBody.hasPrefix("---")
        if store.mermaidSaveWarning != nil || store.markdownSaveWarning != nil || hasFrontmatter {
            VStack(alignment: .leading, spacing: 6) {
                if hasFrontmatter {
                    Text("Frontmatter (---) is generated automatically and will be stripped from this field on next load. Set the title using the field above.")
                        .foregroundStyle(.orange)
                }
                if let mermaid = store.mermaidSaveWarning {
                    Text(mermaid)
                        .foregroundStyle(.orange)
                }
                if let md = store.markdownSaveWarning {
                    markdownSection(md)
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, PageEditorMetrics.contentInset)
            .padding(.top, 8)
        }
    }

    @ViewBuilder private func markdownSection(_ md: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("Markdown formatting (informational — page saved as-is):\n\(md)")
                .foregroundStyle(.orange.opacity(0.8))
            Spacer(minLength: 4)
            // The button only appears when markdownSaveWarning is non-nil, which
            // only happens when the linter IS loaded — so fixMarkdownInDraft()
            // will always have a linter to call. No separate nil guard needed.
            Button("Fix", systemImage: "wand.and.stars") {
                store.fixMarkdownInDraft()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Auto-fix cosmetic markdown issues (trailing whitespace, blank-line spacing, etc.)")
        }
    }

    // MARK: - Actions

    private func commitEdit() {
        store.flushPendingSave()
        isEditing = false
    }

    private func cancelEdit() {
        if let id = store.activeTabID {
            store.discardPendingDraft(tabID: id)
        }
        isEditing = false
    }

    /// Rename the currently-selected page. `store.rename` flushes pending edits
    /// first, then updates the title (and the slug, open tabs, and `draftTitle`).
    private func renameCurrentPage(to newTitle: String) {
        guard case .page(let id)? = store.selection else { return }
        store.rename(id, to: newTitle)
    }

}
struct HeadingItem: Identifiable, Hashable {
    let id: String // The anchor slug
    let text: String
    let level: Int
    /// NSString (UTF-16) character offset of this heading's line start within
    /// the source markdown. Used by the editor to scroll to this heading
    /// (issue #268) and by the outline to determine which heading the caret
    /// is currently inside.
    let charOffset: Int
}

struct PageOutlineView: View {
    let markdown: String
    /// The caret's character index within the source text, or `nil` when not
    /// editing. When non-nil, the heading containing the caret is highlighted
    /// and the outline scrolls to keep it visible (issue #268).
    var caretCharIndex: Int? = nil
    let onSelect: (HeadingItem) -> Void
    
    @State private var headings: [HeadingItem] = []
    /// Tracks which heading the outline last scrolled itself to, so we only
    /// auto-scroll when the active heading actually changes (not on every
    /// keystroke that stays within the same heading).
    @State private var scrolledToHeadingID: String? = nil
    
    /// The id of the heading whose `charOffset` is closest to (but not after)
    /// the caret, or `nil` if there is no caret or no preceding heading.
    private var activeHeadingID: String? {
        guard let caret = caretCharIndex, !headings.isEmpty else { return nil }
        var active: HeadingItem?
        for heading in headings {
            if heading.charOffset <= caret {
                active = heading
            } else {
                break
            }
        }
        return active?.id
    }
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(headings) { heading in
                        let isActive = heading.id == activeHeadingID
                        Button(action: {
                            onSelect(heading)
                        }) {
                            Text(heading.text)
                                .font(.system(size: 13))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .padding(.leading, CGFloat((heading.level - 1) * 12))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(isActive ? .primary : .secondary)
                        .background(
                            isActive
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                        .id(heading.id)
                        .onHover { isHovering in
                            if isHovering {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                    }
                }
                .padding()
            }
            .onChange(of: caretCharIndex) { _, _ in
                let target = activeHeadingID
                guard target != scrolledToHeadingID else { return }
                scrolledToHeadingID = target
                if let target {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
        }
        .onAppear {
            parseHeadings()
        }
        .onChange(of: markdown) { _, _ in
            parseHeadings()
        }
    }
    
    private func parseHeadings() {
        var items: [HeadingItem] = []
        var slugCounts: [String: Int] = [:]
        var inFence = false
        
        // charOffset tracks the NSString (UTF-16) character offset of each
        // line's start — the same coordinate space NSTextView uses for ranges.
        var charOffset = 0
        
        for line in markdown.components(separatedBy: .newlines) {
            let lineUTF16Length = (line as NSString).length
            defer { charOffset += lineUTF16Length + 1 } // +1 for the \n
            
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            guard !inFence else { continue }
            
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                guard level > 0 && level <= 6 else { continue }
                
                let afterPounds = trimmed.dropFirst(level)
                guard afterPounds.first?.isWhitespace == true else { continue }
                
                let rawText = afterPounds.trimmingCharacters(in: .whitespaces)
                guard !rawText.isEmpty else { continue }

                // Strip inline markdown (links, code spans, emphasis) so the
                // outline shows plain text — matching the HTML renderer's
                // heading anchor IDs (which use Swift-Markdown's plainText).
                let text = Self.stripInlineMarkup(rawText)
                guard !text.isEmpty else { continue }

                let slug = AnchorBlock.makeSlug(text, counts: &slugCounts)
                items.append(HeadingItem(id: slug, text: text, level: level,
                                         charOffset: charOffset))
            }
        }
        
        headings = items
    }

    // MARK: - Inline markup stripping

    /// Strip inline markdown so heading text reads as plain text in the
    /// outline. Handles the cases most likely in headings: links
    /// (`[text](url)` → `text`), code spans (`` `text` `` → `text`), and
    /// emphasis (`**bold**`, `*italic*`, `__bold__`, `_italic_` → `text`).
    /// This mirrors what Swift-Markdown's `plainText` does in the HTML
    /// renderer, keeping the outline's display + slug in sync with the
    /// rendered anchor IDs.
    private static let linkAndCodeRegexes: [NSRegularExpression] = {
        [
            try? NSRegularExpression(pattern: #"\[([^\]]*)\]\([^)]*\)"#),  // links
            try? NSRegularExpression(pattern: #"`([^`]*)`"#),              // code spans
        ].compactMap { $0 }
    }()

    static func stripInlineMarkup(_ text: String) -> String {
        var result = text
        for regex in linkAndCodeRegexes {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1")
        }
        // Emphasis markers — strip ** before *, __ before _ to avoid
        // mismatched pairs. Use simple replacement (safe in headings where
        // these are virtually always emphasis, not literal characters).
        result = result.replacingOccurrences(of: "**", with: "")
        result = result.replacingOccurrences(of: "__", with: "")
        return result
    }
}

