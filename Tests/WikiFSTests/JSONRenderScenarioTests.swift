import AppKit
import SwiftUI
import Testing
import WebKit
@testable import WikiFS
@testable import WikiFSCore

/// AC.2 + AC.3 — Integration tests that host `JSONRenderView` in an `NSWindow`
/// and verify the live WKWebView DOM renders the form + the action round-trips
/// to Swift.
///
/// Reuses the exact harness pattern from `QuoteHighlightWebViewTests` /
/// `YouTubeEmbedWebViewTests`: `NSApplication.shared` accessory activation,
/// `NSHostingController`, `findWebView`/`waitForWebView` helpers, `evaluateJavaScript`
/// polling with a bounded timeout.
@Suite(.tags(.integration))
@MainActor
struct JSONRenderScenarioTests {

    /// A WKWebView in `swift test` has no host app, so JS evaluation never
    /// fires. Creating `NSApplication.shared` gives WebKit the run loop / app
    /// context it needs. Done once.
    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return app
    }()

    // MARK: - Helpers (mirrors QuoteHighlightWebViewTests / YouTubeEmbedWebViewTests)

    private func findWebView(_ view: NSView) -> WKWebView? {
        if let w = view as? WKWebView { return w }
        for sub in view.subviews { if let f = findWebView(sub) { return f } }
        return nil
    }

    private func waitForWebView(in window: NSWindow, timeout: TimeInterval = 5) async throws -> WKWebView {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let cv = window.contentView, let w = findWebView(cv) { return w }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(domain: "JSONRenderScenarioTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "no WKWebView found in hosted window"])
    }

    @MainActor
    private func evalString(_ webView: WKWebView, _ js: String) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            webView.evaluateJavaScript(js) { result, _ in
                cont.resume(returning: result as? String)
            }
        }
    }

    @MainActor
    private func run(_ webView: WKWebView, _ js: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            webView.evaluateJavaScript(js) { _, _ in cont.resume() }
        }
    }

    /// Poll the DOM until the form renderer has painted, returning the text
    /// content of the field label for the given data-wiki-render-id. "" if not
    /// found within the timeout.
    @MainActor
    private func waitForFieldLabel(in webView: WKWebView, elementId: String, tries: Int = 40) async -> String {
        for _ in 0..<tries {
            let label = await evalString(webView, """
            (function(){ var el = document.querySelector('[data-wiki-render-id="\(elementId)"] label'); return el ? el.textContent : ""; })()
            """) ?? ""
            if !label.isEmpty { return label }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return ""
    }

    /// Poll the DOM until the button exists.
    @MainActor
    private func waitForButton(in webView: WKWebView, elementId: String, tries: Int = 40) async -> Bool {
        for _ in 0..<tries {
            // JS boolean → NSNumber; wrap in String() so evalString can coerce it.
            let exists = await evalString(webView, """
            (function(){ return String(!!document.querySelector('[data-wiki-render-id="\(elementId)"]')); })()
            """)
            if exists == "true" { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    // MARK: - Test spec (the dev proof form: TextField + PasswordField + NumberField + SelectField + Add Button)

    /// Build the dev-proof form spec (§1.3): TextField + PasswordField +
    /// NumberField + SelectField + an "Add" Button whose `addSource` action
    /// carries form values via `$state` expressions.
    private func devProofSpecBase64() throws -> String {
        let spec: [String: Any] = [
            "root": "form",
            "elements": [
                "form": [
                    "type": "Stack",
                    "children": ["name-field", "pass-field", "num-field", "sel-field", "add-btn"]
                ],
                "name-field": [
                    "type": "TextField",
                    "props": ["label": "Name", "value": ["$bindState": "/form/name"]]
                ],
                "pass-field": [
                    "type": "PasswordField",
                    "props": ["label": "API Key", "value": ["$bindState": "/form/apiKey"]]
                ],
                "num-field": [
                    "type": "NumberField",
                    "props": ["label": "Limit", "value": ["$bindState": "/form/limit"]]
                ],
                "sel-field": [
                    "type": "SelectField",
                    "props": [
                        "label": "Format",
                        "value": ["$bindState": "/form/format"],
                        "options": [
                            ["label": "Markdown", "value": "md"],
                            ["label": "PDF", "value": "pdf"]
                        ]
                    ]
                ],
                "add-btn": [
                    "type": "Button",
                    "props": ["label": "Add"],
                    "on": [
                        "press": [
                            "action": "addSource",
                            "params": [
                                "name": ["$state": "/form/name"],
                                "apiKey": ["$state": "/form/apiKey"],
                                "limit": ["$state": "/form/limit"],
                                "format": ["$state": "/form/format"]
                            ]
                        ]
                    ]
                ]
            ],
            "state": [:]
        ]
        return try JSONRenderPayloadEncoder.encode(spec: spec)
    }

    // MARK: - AC.2: Renders form spec

    @Test func test_renders_form_spec() async throws {
        _ = Self.app

        let b64 = try devProofSpecBase64()
        let view = JSONRenderView(specBase64: b64)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        let webView = try await waitForWebView(in: window)

        // AC.2: the DOM gains a rendered form with the expected field labels.
        let nameLabel = await waitForFieldLabel(in: webView, elementId: "name-field")
        #expect(nameLabel == "Name", "TextField label not rendered; got \"\(nameLabel)\"")

        let passLabel = await waitForFieldLabel(in: webView, elementId: "pass-field")
        #expect(passLabel == "API Key", "PasswordField label not rendered; got \"\(passLabel)\"")

        let numLabel = await waitForFieldLabel(in: webView, elementId: "num-field")
        #expect(numLabel == "Limit", "NumberField label not rendered; got \"\(numLabel)\"")

        let selLabel = await waitForFieldLabel(in: webView, elementId: "sel-field")
        #expect(selLabel == "Format", "SelectField label not rendered; got \"\(selLabel)\"")

        // The Add button exists.
        let hasButton = await waitForButton(in: webView, elementId: "add-btn")
        #expect(hasButton, "Add button not rendered")
    }

    // MARK: - AC.3: addSource action round-trips

    @Test func test_addSource_action_round_trips() async throws {
        _ = Self.app

        let b64 = try devProofSpecBase64()

        // Capture the action emitted from the webview.
        let capture = ActionCaptureBox()
        let view = JSONRenderView(specBase64: b64) { action, params in
            capture.action = action
            capture.params = params
            capture.received = true
        }

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        let webView = try await waitForWebView(in: window)

        // Wait for the form to render (the Add button must exist before clicking).
        _ = await waitForButton(in: webView, elementId: "add-btn")

        // Fill in form values via evaluateJavaScript, dispatching input/change
        // events so the $bindState bindings update the state model.
        await run(webView, """
        (function(){
          var n = document.getElementById('wr-name-field');
          if (n) { n.value = 'Test Source'; n.dispatchEvent(new Event('input')); }
          var p = document.getElementById('wr-pass-field');
          if (p) { p.value = 'secret123'; p.dispatchEvent(new Event('input')); }
          var num = document.getElementById('wr-num-field');
          if (num) { num.value = '42'; num.dispatchEvent(new Event('input')); }
          var sel = document.getElementById('wr-sel-field');
          if (sel) { sel.value = 'pdf'; sel.dispatchEvent(new Event('change')); }
        })();
        """)

        // Click the Add button — triggers emitAction → addAction.postMessage.
        await run(webView, """
        (function(){
          var btn = document.querySelector('[data-wiki-render-id="add-btn"]');
          if (btn) btn.click();
        })();
        """)

        // Poll for the action callback (the message handler fires asynchronously).
        var received = false
        for _ in 0..<40 {
            if capture.received { received = true; break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(received, "addAction message handler did not receive the payload")

        // AC.3: the payload carries the form values.
        #expect(capture.action == "addSource", "action name mismatch: \(capture.action ?? "nil")")
        let params = capture.params ?? [:]
        #expect(params["name"] as? String == "Test Source", "name param mismatch")
        #expect(params["apiKey"] as? String == "secret123", "apiKey param mismatch")
        #expect(params["format"] as? String == "pdf", "format param mismatch")

        // limit is a number (NumberField → Number(e.target.value) → JS number → NSNumber).
        let limit = params["limit"]
        #expect(limit != nil, "limit param missing")
        #expect(String(describing: limit ?? "") == "42", "limit param mismatch: \(String(describing: limit))")
    }
}

/// Holds the captured action for AC.3 (main-actor-isolated).
@MainActor
final class ActionCaptureBox {
    var received = false
    var action: String?
    var params: [String: Any]?
}
