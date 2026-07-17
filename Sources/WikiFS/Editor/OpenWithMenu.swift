import AppKit
import UniformTypeIdentifiers
import WikiFSCore

/// Builds Finder-style "Open With" submenus: the registered editors for a
/// content type (default marked), then "Other…" for manual selection.
///
/// App discovery is **content-type based**, not URL based: we already know the
/// source's MIME type / filename (and pages are always Markdown), so the submenu
/// builds synchronously with no File Provider URL resolution. The mount URL is
/// only resolved at click time, then handed to `NSWorkspace.open` with the
/// chosen app — see `FileProviderFacade.openSource(id:with:)` / `openPage(id:with:)`.
enum OpenWithMenu {
    /// Build the submenu for `contentType`. Each app item's `representedObject`
    /// is `payload(appURL)`; the trailing "Other…" item is `payload(nil)`.
    /// `action` is sent to `target` on selection (the same selector for apps and
    /// "Other…"; the handler treats a `nil` appURL as "present an app picker").
    static func build(
        contentType: UTType,
        target: AnyObject,
        action: Selector,
        payload: (URL?) -> Any
    ) -> NSMenu {
        let menu = NSMenu()
        // The parent owns enablement; don't let NSMenu auto-disable our items.
        menu.autoenablesItems = false

        let apps = NSWorkspace.shared.urlsForApplications(toOpen: contentType)
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: contentType)

        var seen = Set<String>()
        var insertedDefaultSeparator = false
        for app in apps {
            let key = app.standardized.path
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            let isDefault = (app.standardized.path == defaultApp?.standardized.path)
            let baseName = app.deletingPathExtension().lastPathComponent
            let title = (isDefault && apps.count > 1) ? "\(baseName) (Default)" : baseName

            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = payload(app)
            if let icon = NSWorkspace.shared.icon(forFile: app.path).copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            menu.addItem(item)

            // Separator after the default (matches Finder: default on its own,
            // then the rest). Only when there are more apps below.
            if isDefault, !insertedDefaultSeparator, apps.count > 1 {
                menu.addItem(.separator())
                insertedDefaultSeparator = true
            }
        }

        menu.addItem(.separator())
        let other = NSMenuItem(title: "Other…", action: action, keyEquivalent: "")
        other.target = target
        other.representedObject = payload(nil)
        menu.addItem(other)

        return menu
    }

    /// Derive the content type for a source from its filename extension
    /// (LaunchServices keys off extensions first) falling back to MIME type,
    /// then to `UTType.data`.
    static func contentType(mimeType: String?, filename: String?) -> UTType {
        let ext = (filename as NSString?)?.pathExtension ?? ""
        if !ext.isEmpty, let t = UTType(filenameExtension: ext) { return t }
        if let mime = mimeType, !mime.isEmpty,
           let t = UTType(tag: mime, tagClass: .mimeType, conformingTo: nil) {
            return t
        }
        return .data
    }

    /// Content type for wiki pages — always Markdown (projected as `.md`).
    static let pageContentType: UTType = UTType(filenameExtension: "md") ?? .plainText
}

/// Presents a system "choose an application" panel (scoped to /Applications by
/// default). Returns the chosen app URL, or `nil` if the user cancelled.
enum AppPicker {
    @MainActor
    static func pick() async -> URL? {
        await withCheckedContinuation { continuation in
            let panel = NSOpenPanel()
            panel.title = "Choose an Application"
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }
}

/// Payload for "Open With" app items in the sources/pages lists. Carries the
/// chosen app URL (or `nil` for "Other…") and the effective IDs to open.
/// A class so it round-trips through `NSMenuItem.representedObject` (Any?).
final class OpenWithIDsRef {
    let appURL: URL?
    let ids: [PageID]
    init(appURL: URL?, ids: [PageID]) {
        self.appURL = appURL
        self.ids = ids
    }
}
