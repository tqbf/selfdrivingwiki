import AppKit
import UniformTypeIdentifiers

/// Native macOS file panels for wiki backup/restore. Kept out of the switcher
/// view so the menu stays declarative and testable manager logic stays in core.
@MainActor
enum WikiFilePanels {
    private static var sqliteType: UTType {
        UTType(filenameExtension: "sqlite") ?? .data
    }

    static func exportURL(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [sqliteType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(defaultName).sqlite"
        panel.prompt = "Export"
        panel.title = "Export Wiki Backup"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func importURL() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [sqliteType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Import"
        panel.title = "Import Wiki Backup"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
