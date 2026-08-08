import AppKit
import Foundation
import Testing
@testable import WikiFS

@Suite(.serialized)
@MainActor
struct RendererSettingsPackagePickerTests {
    @Test func testV1PickerAcceptsOneDirectoryAndRejectsFilesAndArchives() throws {
        let panel = NSOpenPanel()
        RendererSettingsPackagePicker.configure(panel)

        #expect(panel.canChooseDirectories)
        #expect(!panel.canChooseFiles)
        #expect(!panel.allowsMultipleSelection)
        #expect(RendererSettingsPackagePicker.importButtonTitle == "Import Renderer Package…")
        #expect(RendererSettingsPackagePicker.localImportSourceMessage == "Select one local renderer package folder as an import source.")
        #expect(RendererSettingsPackagePicker.localImportStorageMessage == "Self Driving Wiki validates and copies it for use on this Mac.")
        #expect(RendererSettingsPackagePicker.localImportAfterMessage == "The selected source folder is not used after import.")
        #expect(panel.prompt == "Import Renderer Package…")
        #expect(panel.message == "Package format v1 accepts one local directory. Files and archives are not supported.")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("renderer-picker-\(UUID().uuidString)", isDirectory: true)
        let packageDirectory = root.appendingPathComponent("example.renderer", isDirectory: true)
        let sourceFile = root.appendingPathComponent("renderer.js")
        let archive = root.appendingPathComponent("renderer.zip")
        defer {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                Issue.record("Temporary renderer picker fixture cleanup failed.")
            }
        }

        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        try Data().write(to: sourceFile)
        try Data().write(to: archive)

        #expect(try RendererSettingsPackagePicker.validatedDirectory(from: [packageDirectory]) == packageDirectory)
        #expect(throws: RendererSettingsPackagePicker.SelectionError.fileOrArchiveNotSupported) {
            try RendererSettingsPackagePicker.validatedDirectory(from: [sourceFile])
        }
        #expect(throws: RendererSettingsPackagePicker.SelectionError.fileOrArchiveNotSupported) {
            try RendererSettingsPackagePicker.validatedDirectory(from: [archive])
        }
        #expect(throws: RendererSettingsPackagePicker.SelectionError.expectedOneDirectory) {
            try RendererSettingsPackagePicker.validatedDirectory(from: [packageDirectory, root])
        }
    }
}
