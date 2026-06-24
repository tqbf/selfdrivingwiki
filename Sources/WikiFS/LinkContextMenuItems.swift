import AppKit
import SwiftUI
import Textual
import WikiFSCore

/// Builds the concrete ``LinkMenuItem``s for a right-clicked link by wiring the
/// pure ``WikiLinkMenuBuilder`` actions to real closures (navigation, semantic
/// search, pasteboard, the system browser).
///
/// Runs on the main actor (AppKit's context-menu path). `store` is captured by
/// the item actions; because the actions are `@MainActor`-isolated and `store`
/// is `@MainActor`, no isolation boundary is crossed.
@MainActor
enum WikiLinkContextMenu {

    static func items(
        for url: URL,
        store: WikiStoreModel,
        fileProvider: FileProviderSpike?,
        addURL: ((String) -> Void)? = nil
    ) -> [LinkMenuItem] {
        var items: [LinkMenuItem] = []
        for action in WikiLinkMenuBuilder.actions(for: url) {
            switch action {
            case .addAsSource:
                // Opens the "Add from URL" sheet pre-filled with the URL, the same
                // path the toolbar button takes. Omitted when no handler is wired
                // (e.g. SwiftUI previews), mirroring how `.copyFilePath` omits
                // itself without a File Provider spike.
                guard let addURL else { continue }
                items.append(.item("Add as Source") {
                    addURL(url.absoluteString)
                })
            case .suggest:
                items.append(
                    similarPagesMenu(
                        title: "Suggest…",
                        query: WikiLinkMarkdown.target(from: url) ?? "",
                        store: store))
            case .findSimilar:
                items.append(
                    similarPagesMenu(
                        title: "Find Similar…",
                        query: WikiLinkMarkdown.target(from: url) ?? "",
                        store: store))
            case .copyWikiLink:
                guard let link = WikiLinkMenuBuilder.wikiLinkString(for: url) else { continue }
                items.append(.item("Copy as Wiki Link") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(link, forType: .string)
                })
            case .copyFilePath:
                // Copies the linked target's File Provider mount path
                // (`<root>/pages/by-title/…` or `<root>/sources/by-id/…`). Needs
                // the spike; the mount root may be unresolved, so the action
                // resolves it async (if needed) then copies. Omitted when no
                // spike is wired into the preview (changelog / system-prompt).
                guard let fileProvider else { continue }
                let kind = WikiLinkMarkdown.resolvedKind(from: url)
                let target = WikiLinkMarkdown.target(from: url) ?? ""
                items.append(.item("Copy File Path") {
                    Task { @MainActor in
                        if fileProvider.path == nil { await fileProvider.resolvePath() }
                        guard let root = fileProvider.path,
                              let leaf = Self.pathLeaf(kind: kind, target: target, store: store)
                        else { return }
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString("\(root)/\(leaf)", forType: .string)
                    }
                })
            case .openInBrowser:
                items.append(.item("Open in Browser") {
                    NSWorkspace.shared.open(url)
                })
            case .copyLink:
                items.append(.item("Copy Link") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(url.absoluteString, forType: .string)
                })
            }
        }
        return items
    }

    /// The mount subpath (`pages/by-title/…` / `sources/by-id/…`) for a resolved
    /// wiki link's target, or `nil` if it can't be resolved. Uses the page's
    /// canonical title (looked up by id, not the link text) so the filename
    /// casing matches the File Provider projection exactly.
    private static func pathLeaf(
        kind: WikiLinkParser.ParsedLink.LinkType?,
        target: String,
        store: WikiStoreModel
    ) -> String? {
        switch kind {
        case .page:
            guard let id = store.pageID(forTitle: target),
                  let canonicalTitle = store.summaries.first(where: { $0.id == id })?.title
            else { return nil }
            return "pages/by-title/\(FilenameEscaping.byTitleFilename(title: canonicalTitle, pageID: id.rawValue))"
        case .source:
            guard let id = store.sourceID(forDisplayName: target),
                  let ext = store.sources.first(where: { $0.id == id })?.ext
            else { return nil }
            return "sources/by-id/\(FilenameEscaping.byIDSourceFilename(sourceID: id.rawValue, ext: ext))"
        case nil:
            return nil
        }
    }

    /// A submenu listing the closest pages to `query`; choosing one navigates to
    /// it. Shows a disabled "No similar pages" item when the search is empty so
    /// the submenu is never mysteriously blank.
    private static func similarPagesMenu(
        title: String, query: String, store: WikiStoreModel
    ) -> LinkMenuItem {
        let matches = query.isEmpty
            ? []
            : store.searchSimilar(query: query, limit: 8)

        let submenu: [LinkMenuItem] = matches.isEmpty
            ? [.item("No similar pages", isEnabled: false, action: {})]
            : matches.map { page in
                .item(page.title) { store.selectPage(byTitle: page.title) }
            }

        return .item(title, submenu: submenu)
    }
}

extension EnvironmentValues {
    /// Opens the "Add from URL" sheet, pre-filling the field with the given URL
    /// string (empty for the toolbar / empty-state buttons; the absolute URL for
    /// the right-click "Add as Source" item).
    ///
    /// Set once by `ContentView` and read deep in the tree (the reader views'
    /// link context menu, via `WikiLinkContextMenu`, plus the empty-state
    /// buttons) so external links can be ingested from any reader without
    /// threading a closure through every detail view. Mirrors how
    /// `MarkdownPreview` already injects behavior via `\.openURL`.
    @Entry var addURLHandler: ((String) -> Void)? = nil
}
