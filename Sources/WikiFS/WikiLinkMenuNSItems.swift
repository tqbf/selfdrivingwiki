import AppKit
import SwiftUI
import WikiFSCore

/// Builds the concrete `NSMenuItem`s for a right-clicked link by wiring the
/// pure ``WikiLinkMenuBuilder`` actions to real closures (navigation, semantic
/// search, pasteboard, the system browser, the File Provider mount).
///
/// This is the WKWebView (AppKit) counterpart to the retired
/// `WikiLinkContextMenu` (which returned Textual `LinkMenuItem`s). It is
/// Textual-free and runs on the main actor (AppKit's context-menu path). The
/// menu items' closures capture `store` / `fileProvider`; because both are
/// `@MainActor`-isolated and the actions fire on the main thread, no isolation
/// boundary is crossed.
@MainActor
enum WikiLinkMenuNSItems {

    static func items(
        for url: URL,
        store: WikiStoreModel,
        fileProvider: FileProviderSpike?,
        addURL: ((String) -> Void)? = nil
    ) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for action in WikiLinkMenuBuilder.actions(for: url) {
            switch action {
            case .addAsSource:
                // Opens the "Add from URL" sheet pre-filled with the URL, the same
                // path the toolbar button takes. Omitted when no handler is wired
                // (e.g. SwiftUI previews), mirroring how `.copyFilePath` omits
                // itself without a File Provider spike.
                guard let addURL else { continue }
                items.append(.wikiItem("Add as Source") { addURL(url.absoluteString) })
            case .suggest:
                items.append(
                    similarPagesItem(
                        title: "Suggest…",
                        query: WikiLinkMarkdown.target(from: url) ?? "",
                        store: store))
            case .findSimilar:
                items.append(
                    similarPagesItem(
                        title: "Find Similar…",
                        query: WikiLinkMarkdown.target(from: url) ?? "",
                        store: store))
            case .copyWikiLink:
                guard let link = WikiLinkMenuBuilder.wikiLinkString(for: url) else { continue }
                items.append(.wikiItem("Copy as Wiki Link") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(link, forType: .string)
                })
            case .copyFilePath:
                // Copies the linked target's File Provider mount path
                // (`<root>/pages/by-title/…` or `<root>/sources/by-id/…`). Needs
                // the spike; the mount root may be unresolved, so the action
                // resolves it async (if needed) then copies. Omitted when no
                // spike is wired into the reader (changelog / system-prompt).
                guard let fileProvider else { continue }
                let kind = WikiLinkMarkdown.resolvedKind(from: url)
                let target = WikiLinkMarkdown.target(from: url) ?? ""
                items.append(.wikiItem("Copy File Path") {
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
                items.append(.wikiItem("Open in Browser") {
                    NSWorkspace.shared.open(url)
                })
            case .copyLink:
                items.append(.wikiItem("Copy Link") {
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
    private static func similarPagesItem(
        title: String, query: String, store: WikiStoreModel
    ) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let matches = query.isEmpty ? [] : store.searchSimilar(query: query, limit: 8)
        let menu = NSMenu()
        if matches.isEmpty {
            let none = NSMenuItem(title: "No similar pages", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for page in matches {
                menu.addItem(.wikiItem(page.title) { store.selectPage(byTitle: page.title) })
            }
        }
        parent.submenu = menu
        return parent
    }
}

// MARK: - NSMenuItem + closure bridge

extension NSMenuItem {
    /// Build an enabled menu item whose action invokes `action` when selected.
    ///
    /// `NSMenuItem.action` is a selector, so the closure is wrapped in an
    /// Objective-C target object. The item's `representedObject` retains the
    /// target for the lifetime of the menu (the menu owns its items), and the
    /// target is released when the menu is torn down — so no manual cleanup is
    /// needed and there's no lingering reference.
    @MainActor
    static func wikiItem(_ title: String, isEnabled: Bool = true, action: @escaping () -> Void) -> NSMenuItem {
        let target = ClosureMenuItemTarget(action)
        let item = NSMenuItem(title: title, action: #selector(ClosureMenuItemTarget.invoke), keyEquivalent: "")
        item.target = target
        item.isEnabled = isEnabled
        item.representedObject = target
        return item
    }
}

/// A retainable target that bridges a Swift closure to `NSMenuItem`'s
/// selector-based action. Retained via the menu item's `representedObject`.
@MainActor
private final class ClosureMenuItemTarget: NSObject {
    private let closure: () -> Void
    init(_ closure: @escaping () -> Void) { self.closure = closure }
    @objc func invoke() { closure() }
}

extension EnvironmentValues {
    /// Opens the "Add from URL" sheet, pre-filling the field with the given URL
    /// string (empty for the toolbar / empty-state buttons; the absolute URL for
    /// the right-click "Add as Source" item).
    ///
    /// Set once by `ContentView` and read deep in the tree (the reader views'
    /// link context menu, via `WikiLinkMenuNSItems`, plus the empty-state
    /// buttons) so external links can be ingested from any reader without
    /// threading a closure through every detail view. Mirrors how the reader
    /// already injects behavior via `\.openURL`.
    @Entry var addURLHandler: ((String) -> Void)? = nil
}
