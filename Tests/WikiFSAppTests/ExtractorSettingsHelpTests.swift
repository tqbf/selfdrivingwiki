#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WikiFS

/// Mirrors `RendererSettingsHelpContentTests` for the extractor pane: the help
/// popover explains the local-folder import contract and the one thing that
/// separates an extractor package from a renderer package — it runs code.
@Suite("Extractor settings help content", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct ExtractorSettingsHelpContentTests {
    @Test("help content explains the package import contract and how a package runs")
    func helpContentExplainsImportContract() throws {
        let source = try sourceText()

        #expect(source.contains("An extractor package turns one file into Markdown."))
        #expect(source.contains("manifest.json"))
        #expect(source.contains("validates the selected folder and copies it into the extractor store"))
        #expect(source.contains("does not use the selected source folder after import"))
        #expect(source.contains("ZIP files, other archives, remote catalogs, and network installation are not supported"))
        // Protocol facts a package author and a cautious user both rely on.
        #expect(source.contains("one-shot process"))
        #expect(source.contains("JSON Lines"))
        #expect(source.contains("lowercase SHA-256 digests"))
        #expect(source.contains("stays blocked until you choose another extractor"))
    }

    @Test("the help states the executable-code risk with the pane's own warning")
    func helpCarriesTheTrustWarning() throws {
        let source = try sourceText()

        // One definition of the warning: the popover reuses the string the
        // import footer shows, so the two can never drift apart.
        #expect(source.contains("ExtractionSettingsView.trustWarningMessage"))
        #expect(source.contains("Executable code warning."))
        #expect(source.contains("Declared capabilities are a declaration, not a security sandbox."))
        #expect(ExtractionSettingsView.trustWarningMessage.contains("executable code"))
    }

    @Test("help surface uses stable accessible copy and system text styles")
    func helpSurfaceHasAccessibleLabelsAndSystemTextStyles() throws {
        let source = try sourceText()

        #expect(source.contains("static let triggerTitle = \"What is an extractor package?\""))
        #expect(source.contains("static let tooltip = \"Learn about local extractor packages\""))
        #expect(source.contains(".accessibilityIdentifier(\"extractor-package-help-button\")"))
        #expect(source.contains(".accessibilityLabel(ExtractorPackageHelpCopy.triggerTitle)"))
        #expect(source.contains(".help(ExtractorPackageHelpCopy.tooltip)"))
        #expect(source.contains(".font(.headline)"))
        #expect(source.contains(".font(.body)"))
        #expect(source.contains(".font(.system(.body, design: .monospaced))"))
        #expect(!source.contains(".font(.system(size:"))
    }

    @Test("hostable help content renders in a macOS window")
    func hostableHelpContentRendersInWindow() {
        let host = NSHostingController(rootView: ExtractorPackageHelpContent())
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 460, height: 540))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        host.view.layoutSubtreeIfNeeded()

        #expect(window.contentViewController === host)
        #expect(host.view.fittingSize.width > 0)
        #expect(host.view.fittingSize.height > 0)
    }

    @Test("hosted help trigger presents and dismisses through its binding")
    func hostedHelpTriggerTogglesItsBinding() {
        var isPresented = false
        let binding = Binding(get: { isPresented }, set: { isPresented = $0 })
        let control = ExtractorPackageHelpControl(isPresented: binding)

        control.presentHelp()
        #expect(isPresented)

        binding.wrappedValue = false
        #expect(!isPresented)
    }

    @Test("the packages pane hosts the help control in its section header")
    func packagesPaneExposesTheHelpControl() throws {
        let settingsSource = try String(
            contentsOf: repositoryRoot().appending(path: "Sources/WikiFS/Sources/ExtractionSettingsView.swift"),
            encoding: .utf8)

        #expect(settingsSource.contains("ExtractorPackageHelpControl(isPresented: $showingPackageHelp)"))
        // An icon in the header, like the renderer pane's, not a row that
        // competes with the package table.
        #expect(settingsSource.contains(".labelStyle(.iconOnly)"))
        #expect(settingsSource.contains("Installed Extractor Packages"))
    }

    private func sourceText() throws -> String {
        try String(
            contentsOf: repositoryRoot().appending(path: "Sources/WikiFS/Settings/ExtractorPackageHelp.swift"),
            encoding: .utf8)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
#endif
