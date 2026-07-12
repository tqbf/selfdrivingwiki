import SwiftUI
import WikiFSCore

/// Unified page surface. The header (title, date, action buttons) stays fixed
/// regardless of mode. The content area below the divider swaps between rendered
/// markdown and the monospaced source editor. Save/Cancel appear inline in the
/// header — same position as the Edit / Copy Path buttons they replace.
struct PageDetailView: View {
    @Bindable var store: WikiStoreModel
    @Bindable var launcher: AgentLauncher
    @Bindable var manager: WikiManager
    let fileProvider: FileProviderSpike
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

    // Find bar state. The model is shared (hoisted to `ContentView` and injected
    // via environment) so the address bar's "Find on Page…" menu item can drive
    // the same find bar that Cmd+F toggles here (issue #157).
    @Environment(FindModel.self) private var findModel
    @State private var findVersion = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — always visible, same layout in both modes.
            VStack(alignment: .leading, spacing: PageEditorMetrics.sectionSpacing) {
                Label {
                    EditableTitle(
                        title: store.draftTitle,
                        placeholder: "Untitled",
                        isDisabled: false,
                        onCommit: renameCurrentPage
                    )
                } icon: {
                    Image(systemName: ResourceKind.page.systemImageName)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    if let date = pageUpdatedAt {
                        Text(date, style: .date)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    if isEditing {
                        Button("Save Changes", systemImage: "checkmark.circle") {
                            commitEdit()
                        }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(store.draftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("Cancel", systemImage: "xmark.circle") {
                            cancelEdit()
                        }
                        .keyboardShortcut(.escape, modifiers: [])

                        Button {
                            isOutlineExpanded.toggle()
                        } label: {
                            Image(systemName: "sidebar.right")
                        }
                        .help("Toggle Outline")
                    } else {
                        Button("Edit",
                               systemImage: "pencil") { isEditing = true }
                            .help("Edit this page manually")
                        if case .page(let id) = store.selection {
                            let pageTitle = store.summaries.first(where: { $0.id == id })?.title ?? ""
                            Button("Lint", systemImage: "checkmark.seal") {
                                Task {
                                    await AgentOperationRunner.runLintPages(
                                        pages: [(id: id, title: pageTitle)],
                                        launcher: launcher, store: store,
                                        manager: manager, fileProvider: fileProvider)
                                }
                            }
                            .help("Fix [[wiki-link]] syntax and run LLM lint on this page")
                        }
                        if case .page(let pageID) = store.selection {
                            Button("Show in List", systemImage: "sidebar.left") {
                                store.requestSidebarReveal(.page(pageID))
                            }
                            .help("Reveal this page in the sidebar")
                        }
                        if fileProvider.path != nil, case .page(let pageID) = store.selection {
                            Button("Share", systemImage: "square.and.arrow.up") {
                                Task {
                                    guard let url = await fileProvider.resolvePageByTitleURL(id: pageID) else { return }
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
                                Task { await fileProvider.revealPageInFinder(id: pageID) }
                            }
                            .help("Reveal this page file in Finder")
                        }
                        Button {
                            isOutlineExpanded.toggle()
                        } label: {
                            Image(systemName: "sidebar.right")
                        }
                        .help("Toggle Outline")
                    }
                }
            }
            .frame(maxWidth: PageEditorMetrics.readableContentWidth, alignment: .leading)
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
        .onAppear { lastKnownActiveTabID = store.activeTabID }
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

    private var editorContent: some View {
        ScrollableTextEditor(
            text: $store.draftBody,
            font: NSFont.monospacedSystemFont(
                ofSize: CGFloat(13 * editorZoom), weight: .regular),
            scrollRequest: editorScrollRequest,
            onCaretChange: { caretCharIndex = $0 }
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
    @AppStorage("outlineWidth") private var outlineWidth: Double = 75.0
    @State private var dragStartWidth: Double? = nil
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
        HStack(spacing: 0) {
            // Draggable divider on the outline's leading edge. A 1pt separator
            // line with a wider invisible hit area so it's easy to grab.
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                .frame(maxHeight: .infinity)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            .onHover { isHovering in
                if isHovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if dragStartWidth == nil {
                            dragStartWidth = outlineWidth
                        }
                        if let start = dragStartWidth {
                            let newWidth = start - Double(value.translation.width)
                            outlineWidth = max(60, min(600, newWidth))
                        }
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                    }
            )
            .zIndex(1)
            
            VStack(alignment: .leading, spacing: 0) {
                Text("Outline")
                    .font(.headline)
                    .padding()
                    
                Divider()
                
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
            }
            .frame(width: outlineWidth)
            .background(Color(nsColor: .windowBackgroundColor))
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

