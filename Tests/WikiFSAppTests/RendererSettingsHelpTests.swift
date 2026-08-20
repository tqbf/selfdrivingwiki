#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import WikiFS

@Suite("Renderer settings help content", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct RendererSettingsHelpContentTests {
    @Test("help content explains the package v1 import contract")
    func helpContentExplainsV1ImportContract() throws {
        let source = try sourceText()

        #expect(source.contains("A renderer package is one local folder."))
        #expect(source.contains("manifest.json"))
        #expect(source.contains("HTML, JavaScript, CSS, image, or font files"))
        #expect(source.contains("validates the selected folder and copies it"))
        #expect(source.contains("does not use the selected source folder after import"))
        #expect(source.contains("available to every wiki on this Mac"))
        #expect(source.contains("ZIP files, other archives, remote catalogs, and network installation are not supported"))
        #expect(source.contains("Source and native renderer fallback stay available"))
    }

    @Test("help surface uses stable accessible copy and system text styles")
    func helpSurfaceHasAccessibleLabelsAndSystemTextStyles() throws {
        let source = try sourceText()

        #expect(source.contains("static let triggerTitle = \"What is a renderer package?\""))
        #expect(source.contains("static let tooltip = \"Learn about local renderer packages\""))
        #expect(source.contains(".accessibilityIdentifier(\"renderer-package-help-button\")"))
        #expect(source.contains(".accessibilityLabel(RendererPackageHelpCopy.triggerTitle)"))
        #expect(source.contains(".help(RendererPackageHelpCopy.tooltip)"))
        #expect(source.contains(".font(.headline)"))
        #expect(source.contains(".font(.body)"))
        #expect(source.contains(".font(.system(.body, design: .monospaced))"))
        #expect(!source.contains(".font(.system(size:"))
    }

    @Test("hostable help content renders in a macOS window")
    func hostableHelpContentRendersInWindow() {
        let host = NSHostingController(rootView: RendererPackageHelpContent())
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 460, height: 540))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        host.view.layoutSubtreeIfNeeded()

        #expect(window.contentViewController === host)
        #expect(host.view.fittingSize.width > 0)
        #expect(host.view.fittingSize.height > 0)
    }

    private func sourceText() throws -> String {
        try String(
            contentsOf: repositoryRoot().appending(path: "Sources/WikiFS/Settings/RendererPackageHelp.swift"),
            encoding: .utf8)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

@MainActor
private final class HelpPresentationState {
    var isPresented = false
}

@Suite("Renderer settings help presentation", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct RendererSettingsHelpHostedTests {
    @Test("hosted help trigger presents and dismisses through its binding")
    func helpTriggerPresentsAndDismissesRendererPackageHelp() async throws {
        let presentation = HelpPresentationState()
        let binding = Binding(
            get: { presentation.isPresented },
            set: { presentation.isPresented = $0 })
        let control = RendererPackageHelpControl(isPresented: binding)
        let host = NSHostingController(rootView: control)
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 360, height: 100))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        host.view.layoutSubtreeIfNeeded()

        control.presentHelp()
        await Task.yield()
        #expect(presentation.isPresented)

        presentation.isPresented = false
        await Task.yield()
        #expect(!presentation.isPresented)

        let settingsSource = try String(
            contentsOf: repositoryRoot().appending(path: "Sources/WikiFS/Settings/RendererSettingsView.swift"),
            encoding: .utf8)
        #expect(settingsSource.contains("RendererPackageHelpControl(isPresented: $showingPackageHelp)"))
        #expect(settingsSource.contains("Advanced Local Renderer Package Import"))
        #expect(settingsSource.contains("Refresh Registry"))
        #expect(settingsSource.contains("Reset Safe Mode"))
        #expect(settingsSource.contains("Remove"))
        #expect(settingsSource.contains("Source Renderer Preferences"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
#endif
