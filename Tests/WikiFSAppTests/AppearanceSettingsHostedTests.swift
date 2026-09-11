#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WikiFS

/// Hosts the real Settings → Appearance view against an isolated defaults
/// suite, drives the real radio controls through accessibility presses, then
/// remounts the view to prove the selection persists.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct AppearanceSettingsHostedTests {
    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return app
    }()

    private func isolatedDefaults() -> UserDefaults {
        let name = "AppearanceSettingsHostedTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            fatalError("unable to create test defaults suite \(name)")
        }
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// Mounts the view in a window and returns the hosting view.
    private func host(_ view: some View, in window: NSWindow) -> NSHostingView<some View> {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 480, height: 600)
        window.contentView = hosting
        window.orderFront(nil)
        return hosting
    }

    /// Every subview of `root`, depth-first, including `root`.
    private func allSubviews(of root: NSView) -> [NSView] {
        var out = [root]
        for child in root.subviews {
            out.append(contentsOf: allSubviews(of: child))
        }
        return out
    }

    /// The grouped Form bridges its radio pickers to real `FocusRingNSButton`
    /// controls (labels are drawn by SwiftUI, so the buttons carry no
    /// titles). Mount is asynchronous, hence the bounded wait. Within this
    /// view the six radios are authored in a fixed order: Appearance
    /// (Light/Dark/System) then Chat (Summary/Detailed/Hidden).
    private func waitForRadioButtons(in root: NSView) async -> [NSButton] {
        for _ in 0..<30 {
            let buttons = allSubviews(of: root).compactMap { $0 as? NSButton }
            if buttons.count >= 6 {
                return buttons
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return []
    }

    @Test func exposesAndPersistsAllToolCallDisplayModes() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        _ = Self.app
        let defaults = isolatedDefaults()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        defer { window.orderOut(nil) }

        // Fresh install: the new key is unset, and the real radio controls
        // exist. Chat radios are the trailing three of six.
        let first = host(AppearanceSettingsView(store: defaults), in: window)
        #expect(defaults.string(forKey: ChatToolCallDisplayPreference.storageKey) == nil)
        let radios = await waitForRadioButtons(in: first)
        let chatRadios = Array(radios.suffix(3))
        #expect(chatRadios.count == 3)

        // Warm-up: click Detailed first. Summary starts selected, and a
        // click on an already-selected radio may not re-fire; the warm-up
        // also proves the click path writes the binding at all.
        do {
            let button = chatRadios[1]
            let bounds = button.convert(button.bounds, to: nil)
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let uptime = ProcessInfo.processInfo.systemUptime
            let down = NSEvent.mouseEvent(
                with: .leftMouseDown, location: center, modifierFlags: [],
                timestamp: uptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 99, clickCount: 1, pressure: 1)
            let up = NSEvent.mouseEvent(
                with: .leftMouseUp, location: center, modifierFlags: [],
                timestamp: uptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 100, clickCount: 1, pressure: 0)
            window.sendEvent(try #require(down))
            window.sendEvent(try #require(up))
            try await Task.sleep(for: .milliseconds(150))
            #expect(defaults.string(forKey: ChatToolCallDisplayPreference.storageKey) == "detailed")
        }

        // Select each mode through the real control: a synthesized mouse
        // click at the radio's center — the real event path
        // (`performClick` is ignored by SwiftUI's hosted radio bridge).
        for (offset, mode) in ChatToolCallDisplayMode.allCases.enumerated() {
            let button = chatRadios[offset]
            let bounds = button.convert(button.bounds, to: nil)
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let uptime = ProcessInfo.processInfo.systemUptime
            let down = NSEvent.mouseEvent(
                with: .leftMouseDown, location: center, modifierFlags: [],
                timestamp: uptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: offset + 1, clickCount: 1, pressure: 1)
            let up = NSEvent.mouseEvent(
                with: .leftMouseUp, location: center, modifierFlags: [],
                timestamp: uptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: offset + 2, clickCount: 1, pressure: 0)
            #expect(down != nil && up != nil, "unable to synthesize click for radio \(offset)")
            guard let down, let up else { continue }
            window.sendEvent(down)
            window.sendEvent(up)
            // SwiftUI processes the click on the following runloop pass.
            try await Task.sleep(for: .milliseconds(150))
            #expect(
                defaults.string(forKey: ChatToolCallDisplayPreference.storageKey) == mode.rawValue,
                "clicking radio \(offset) must persist \(mode.rawValue)"
            )
        }

        // Destroy and remount the view against the same suite: the last
        // selection (hidden) is what the fresh view shows.
        window.contentView = nil
        let second = host(AppearanceSettingsView(store: defaults), in: window)
        let remounted = await waitForRadioButtons(in: second)
        #expect(remounted.count >= 6)
        #expect(remounted[5].state == .on, "Hidden must be the selected radio after remount")
    }
}
#endif
