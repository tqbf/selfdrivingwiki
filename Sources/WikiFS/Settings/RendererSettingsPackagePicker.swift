import AppKit
import Foundation
import WikiFSCore

/// The local-only package-directory contract used by Renderer settings.
///
/// AppKit's panel configuration is only the first safeguard. Every accepted
/// selection is revalidated at this boundary so files, archives, and multiple
/// URLs cannot enter the package-install workflow through another call path.
@MainActor
enum RendererSettingsPackagePicker {
    static let importButtonTitle = "Import Renderer Package…"
    static let localImportSourceMessage = "Select one local renderer package folder as an import source."
    static let localImportStorageMessage = "Self Driving Wiki validates and copies it for use on this Mac."
    static let localImportAfterMessage = "The selected source folder is not used after import."
    static let v1FormatMessage = "Select one local renderer package folder as an import source. Self Driving Wiki validates and copies it. The selected source folder is not used after import. Files and archives are not supported."

    enum SelectionError: Error, Equatable {
        case expectedOneDirectory
        case fileOrArchiveNotSupported
    }

    static func makePanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        configure(panel)
        return panel
    }

    static func configure(_ panel: NSOpenPanel) {
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.prompt = importButtonTitle
        panel.title = importButtonTitle
        panel.message = v1FormatMessage
    }

    static func validatedDirectory(from selection: [URL]) throws -> URL {
        guard selection.count == 1, let url = selection.first else {
            throw SelectionError.expectedOneDirectory
        }

        guard !isArchive(url), isDirectory(url) else {
            throw SelectionError.fileOrArchiveNotSupported
        }
        return url
    }

    static func selectedDirectory(from panel: NSOpenPanel) throws -> URL {
        try validatedDirectory(from: panel.urls)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        do {
            return try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        } catch {
            DebugLog.store("Renderer package picker could not inspect the selected URL.")
            return false
        }
    }

    private static func isArchive(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar":
            true
        default:
            false
        }
    }
}
