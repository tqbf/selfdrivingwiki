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
                EditableTitle(
                    title: store.draftTitle,
                    placeholder: "Untitled",
                    isDisabled: store.isAgentRunning,
                    onCommit: renameCurrentPage
                )

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
                        .disabled(store.isAgentRunning
                                  || store.draftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

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
                        Button(store.isAgentRunning ? "Agent updating wiki…" : "Edit",
                               systemImage: "pencil") { isEditing = true }
                            .disabled(store.isAgentRunning)
                            .help(store.isAgentRunning
                                  ? "Editing is paused while the agent is updating the wiki"
                                  : "Edit this page manually")
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
                            .disabled(store.isAgentRunning)
                            .help("Fix [[wiki-link]] syntax and run LLM lint on this page")
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

            HStack(spacing: 0) {
                Group {
                    // Content — swaps between reader and editor, header stays put.
                    if isEditing {
                        TextEditor(text: $store.draftBody)
                            .font(.system(size: 13 * editorZoom, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(.horizontal, PageEditorMetrics.contentInset)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .frame(minHeight: PageEditorMetrics.editorMinHeight)
                            .onChange(of: store.draftBody) { store.bodyChanged() }
                            .zoomShortcuts($editorZoom)
                            .zoomScroll($editorZoom)
                    } else {
                        WikiReaderView(markdown: store.draftBody,
                                        currentSelection: store.selection,
                                        store: store,
                                        fileProvider: fileProvider,
                                        findText: findText, findVersion: findVersion, findOccurrence: findOccurrence)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: PageEditorMetrics.previewMinHeight)
                            .zoomShortcuts($readerZoom)
                            .zoomScroll($readerZoom)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                
                if isOutlineExpanded {
                    PageOutlineView(markdown: store.draftBody) { slug in
                        store.jumpToAnchorInCurrentSelection(slug)
                    }
                }
            }
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
        }
        .onChange(of: store.isAgentRunning) { _, isRunning in
            if isRunning { isEditing = false }
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
}

struct PageOutlineView: View {
    let markdown: String
    let onSelect: (String) -> Void
    
    @State private var headings: [HeadingItem] = []
    @AppStorage("outlineWidth") private var outlineWidth: Double = 75.0
    @State private var dragStartWidth: Double? = nil
    
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
                
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(headings) { heading in
                            Button(action: {
                                onSelect(heading.id)
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
                            .foregroundStyle(.secondary)
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
        
        let lines = markdown.components(separatedBy: .newlines)
        var inFence = false
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                guard level > 0 && level <= 6 else { continue }
                
                let afterPounds = trimmed.dropFirst(level)
                guard afterPounds.first?.isWhitespace == true else { continue }
                
                let text = afterPounds.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                
                let slug = AnchorBlock.makeSlug(text, counts: &slugCounts)
                items.append(HeadingItem(id: slug, text: text, level: level))
            }
        }
        
        headings = items
    }
}

