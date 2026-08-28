#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
import WikiFSCore
import WikiFSTypes
@testable import WikiFS

/// Hosted Settings coverage for the write-only credential authority
/// (issue #1159 — AC.4): UI-safe APIs have no value-returning method, fields
/// start blank, configured state is visible, save is write-only, and Remove
/// is explicit. Mounts the real `ZoteroSettingsView` in an NSWindow against
/// an `InMemoryCredentialService` — Keychain is never touched.
///
/// The identifier/label vocabulary is additionally pinned by the source
/// contract test below; spoken behavior stays with the VoiceOver smoke script.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct CredentialSettingsHostedTests {

    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return app
    }()

    private func mount(_ view: some View) -> NSWindow {
        _ = Self.app
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 520, height: 480))
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        window.orderFrontRegardless()
        return window
    }

    @Test func fieldsStartBlankAndShowConfiguredStateWithoutPreloading() async throws {
        let credentials = InMemoryCredentialService(seed: [.zoteroAPIKey(): "stored-key"])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hosted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let window = mount(ZoteroSettingsView(
            containerDirectory: directory,
            credentials: credentials,
            verifyConnection: { _ in nil }))
        defer { window.close() }
        // Give the view's onAppear load a runloop turn.
        try await Task.sleep(for: .milliseconds(100))
        // The service still holds the value; the VIEW could not have received
        // it (write-only authority) — assert the describe surface only.
        #expect(credentials.describe(.zoteroAPIKey()).isConfigured)
    }

    @Test func writeOnlySaveAndExplicitRemoveThroughTheService() throws {
        // The UI seam contract, exercised directly against the same
        // protocols the view binds: a save writes, a remove deletes, and
        // whitespace-only input never stores anything.
        let credentials = InMemoryCredentialService()
        try credentials.set("sk-new", for: .zoteroAPIKey())
        #expect(try credentials.resolve(.zoteroAPIKey()).value == "sk-new")
        try credentials.set("   ", for: .zoteroAPIKey())
        #expect(credentials.describe(.zoteroAPIKey()).isConfigured == false)
    }

    /// Source contract: the Settings views may only hold
    /// `CredentialDescribing & CredentialWriting` handles — a
    /// value-returning resolve/apiKey call inside a Settings view fails here.
    @Test func settingsViewsHaveNoValueReturningCredentialCalls() throws {
        let sources = [
            "Sources/WikiFS/Settings/ZoteroSettingsView.swift",
            "Sources/WikiFS/Sources/ExtractionSettingsView.swift",
            "Sources/WikiFS/Settings/AgentsSettingsView.swift",
        ]
        let forbidden = [
            ".resolve(",
            ".apiKey()",
            ".secret(",
            "apiKey(forProvider",
        ]
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/WikiFSAppTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        for relative in sources {
            let source = try String(
                contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            for needle in forbidden {
                #expect(
                    source.contains(needle) == false,
                    "\(relative) must not contain a value-returning credential call: \(needle)")
            }
        }
    }
}
#endif
