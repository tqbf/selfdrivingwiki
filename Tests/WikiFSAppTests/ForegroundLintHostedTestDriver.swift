#if os(macOS)
import AppKit
import SwiftUI
import Testing
import WikiFSCore
import WikiFSTypes
@testable import WikiFS

/// AC.8 — the lint-specific hosted driver: hosts the REAL
/// `ForegroundLintSheet` content in a retained NSWindow and drives its
/// actual controls through the accessibility API. Direct session calls may
/// seed dependencies and select findings; they can NOT substitute for the
/// repair-choice, preview, Discard, or Apply interactions — those go through
/// real button presses located by stable accessibility identifiers.
///
/// Discipline:
/// - The driver RETAINS its window and closes it on every path
///   (`close()` is idempotent); a deinit closes defensively.
/// - Every wait is bounded (`Task.sleep` polling, never a bare
///   continuation), control lookup is bounded, and a missing control fails
///   with a diagnostic that lists the identifiers actually found.
/// - Presses route through `accessibilityPerformPress()` — the real AppKit
///   accessibility action SwiftUI buttons expose.
/// - Exactly-once completion: `close()` flips a flag so a `.timeLimit`
///   cancellation cannot double-close.
@MainActor
final class ForegroundLintHostedTestDriver {

    enum DriverError: Error, Equatable {
        /// The bounded wait expired. Carries a diagnostic.
        case timeout(String)
        /// The control was found but refused the press.
        case pressFailed(String)
    }

    let session: ForegroundLintSession
    let window: NSWindow
    private var isClosed = false

    /// Build the driver around the REAL sheet with a seeded session, then
    /// start the run exactly as `ForegroundLintWindow.openOnce` does (the
    /// sheet itself never starts the run; the window does).
    init(
        session: ForegroundLintSession,
        pageID: PageID,
        pageTitle: String,
        onApply: ((LintRepairProposal, String) async -> LintApplyOutcome)? = nil
    ) throws {
        self.session = session
        let applyRecorder = ApplyRecorder()
        self.applyRecorder = applyRecorder
        let recordedApply: (LintRepairProposal, String) async -> LintApplyOutcome = {
            proposal, candidate in
            applyRecorder.calls.append((proposal.findingID, proposal.optionID))
            applyRecorder.candidates.append(candidate)
            if let onApply {
                return await onApply(proposal, candidate)
            }
            return .committed(PageVersionID(rawValue: "hosted-applied"))
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        // The sheet's Close button closes the hosting window directly (the
        // driver's own close() is idempotent over an already-closed window).
        let content = NSHostingView(
            rootView: ForegroundLintSheet(
                session: session,
                pageTitle: pageTitle,
                onApply: recordedApply,
                onClose: { window.performClose(nil); window.close() }))
        window.contentView = content
        // AppKit publishes a window's accessibility tree only for active
        // apps; the test runner starts with a non-regular policy.
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        content.layoutSubtreeIfNeeded()
        self.window = window
        session.start(pageID: pageID, strategyRevision: nil, strategyContext: "")
    }

    /// The recorded Apply seam (identity, option, and exact candidates).
    private let applyRecorder: ApplyRecorder

    @MainActor
    private final class ApplyRecorder {
        var calls: [(finding: LintFindingID, option: LintOptionID)] = []
        var candidates: [String] = []
    }

    // No deinit: it can run on any thread, and AppKit window teardown is
    // main-thread only. Every test closes the driver in `defer { close() }`,
    // which is idempotent.

    // MARK: - Bounded waits

    /// Poll `condition` until it holds or the timeout expires. Bounded by
    /// construction — never a bare continuation, never `Thread.sleep`.
    func waitFor(
        _ condition: @MainActor () -> Bool,
        timeout: Duration = .seconds(6),
        diagnostic: @autoclosure @MainActor () -> String = "condition never held"
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while condition() == false {
            guard ContinuousClock.now < deadline else {
                throw DriverError.timeout(diagnostic())
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    /// Wait for the session to reach a phase (or anything but `isBusy`).
    func waitForPhaseReviewing(timeout: Duration = .seconds(6)) async throws {
        try await waitFor(
            { !session.isBusy },
            timeout: timeout,
            diagnostic: "the lint run never left the busy phases")
    }

    // MARK: - Accessibility-driven controls (tiered queries)

    /// One accessibility element, from either query channel: a real
    /// assistive-client `AXUIElement` or the informal in-process selector
    /// tree (some runners refuse self-examination at the app level).
    enum A11yElement {
        case ax(AXUIElement)
        case object(AnyObject)

        func identifier() -> String? {
            switch self {
            case .ax(let element):
                var value: CFTypeRef?
                let result = AXUIElementCopyAttributeValue(
                    element, "AXIdentifier" as CFString, &value)
                guard result == .success, let text = value as? String, !text.isEmpty else {
                    return nil
                }
                return text
            case .object(let element):
                let selector = NSSelectorFromString("accessibilityIdentifier")
                guard element.responds(to: selector),
                      let text = element.perform(selector)?
                          .takeUnretainedValue() as? String,
                      !text.isEmpty else {
                    return nil
                }
                return text
            }
        }

        func string(_ axAttribute: String, selectorName: String) -> String? {
            switch self {
            case .ax(let element):
                var value: CFTypeRef?
                let result = AXUIElementCopyAttributeValue(
                    element, axAttribute as CFString, &value)
                guard result == .success, let text = value as? String, !text.isEmpty else {
                    return nil
                }
                return text
            case .object(let element):
                let selector = NSSelectorFromString(selectorName)
                guard element.responds(to: selector),
                      let text = element.perform(selector)?
                          .takeUnretainedValue() as? String,
                      !text.isEmpty else {
                    return nil
                }
                return text
            }
        }

        /// The real press action for this element.
        func press() -> Bool {
            switch self {
            case .ax(let element):
                return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
            case .object(let element):
                let selector = NSSelectorFromString("accessibilityPerformPress")
                guard element.responds(to: selector),
                      let pressed = element.perform(selector)?
                          .takeUnretainedValue() as? Bool else {
                    return false
                }
                return pressed
            }
        }

        /// Human-readable shape for failure diagnostics.
        func shape() -> String {
            let identifier = identifier() ?? ""
            let title = string(kAXTitleAttribute, selectorName: "accessibilityLabel")
                ?? string(kAXDescriptionAttribute, selectorName: "accessibilityDescription")
                ?? ""
            let role = string(kAXRoleAttribute, selectorName: "accessibilityRole") ?? "?"
            return role + (title.isEmpty ? "" : "('\(title)')")
                + (identifier.isEmpty ? "" : "[\(identifier)]")
        }
    }

    /// The AX element for this test process (real assistive-client queries).
    /// `AXManualAccessibility` is enabled so SwiftUI's tree materializes
    /// without a real assistive client attached.
    private var appElement: AXUIElement {
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        // Both switches force AppKit/SwiftUI to materialize the a11y tree
        // without a real assistive client attached (the documented Electron/
        // Chromium approach for self-testing).
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        return element
    }

    /// Every accessibility element under the hosted window. Both channels
    /// are queried; whichever one exposes identifiers wins (the AXUIElement
    /// channel first, the informal in-process selector tree second).
    private func allAccessibilityElements() -> [A11yElement] {
        let app = appElement
        var axCollected: [A11yElement] = []
        var windows: CFTypeRef?
        let windowsResult = AXUIElementCopyAttributeValue(
            app, kAXWindowsAttribute as CFString, &windows)
        if windowsResult == .success, let list = windows as? [AXUIElement] {
            axCollected = list.flatMap { walkAX($0, depth: 0) }
        }
        if axCollected.isEmpty {
            var focusedValue: CFTypeRef?
            let focusedResult = AXUIElementCopyAttributeValue(
                app, kAXFocusedWindowAttribute as CFString, &focusedValue)
            if focusedResult == .success, let focused = focusedValue,
               let element = unsafeDowncast(focused, to: AXUIElement.self) as AXUIElement? {
                axCollected = walkAX(element, depth: 0)
            }
        }

        let childrenSelector = NSSelectorFromString("accessibilityChildren")
        var informal: [A11yElement] = []
        func walkObject(_ element: AnyObject, depth: Int) {
            guard depth < 32 else { return }
            informal.append(.object(element))
            guard element.responds(to: childrenSelector),
                  let children = element.perform(childrenSelector)?
                      .takeUnretainedValue() as? [AnyObject] else {
                return
            }
            for child in children { walkObject(child, depth: depth + 1) }
        }
        if let contentView = window.contentView {
            walkObject(contentView, depth: 0)
        }

        // Prefer the channel that actually exposes identifiers.
        if informal.contains(where: { $0.identifier() != nil }) {
            return informal
        }
        if axCollected.contains(where: { $0.identifier() != nil }) {
            return axCollected
        }
        return axCollected + informal
    }

    private func walkAX(_ element: AXUIElement, depth: Int) -> [A11yElement] {
        guard depth < 24 else { return [] }
        var collected: [A11yElement] = [.ax(element)]
        var children: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &children)
        if result == .success, let children,
           let list = unsafeDowncast(children, to: NSArray.self) as? [AXUIElement] {
            for child in list {
                collected += walkAX(child, depth: depth + 1)
            }
        }
        return collected
    }

    /// The first element whose accessibility identifier matches. The lookup
    /// is bounded by the caller's wait; the FAILURE diagnostic lists every
    /// identifier actually present so a missing control is diagnosable.
    private func element(withIdentifier identifier: String) -> A11yElement? {
        allAccessibilityElements().first { $0.identifier() == identifier }
    }

    /// Diagnostic listing every identifier present (for gating tests).
    func foundIdentifiers() -> String {
        let elements = allAccessibilityElements()
        let identifiers = elements.compactMap { $0.identifier() }
        if !identifiers.isEmpty {
            return identifiers.joined(separator: ", ")
        }
        return "no identifiers; \(elements.count) elements: "
            + elements.prefix(24).map { $0.shape() }.joined(separator: " ")
    }

    /// Public capability check for gating tests: whether ANY element in the
    /// hosted tree exposes an accessibility identifier.
    func hasAnyIdentifier() -> Bool {
        allAccessibilityElements().contains { $0.identifier() != nil }
    }

    /// Press the button identified by `identifier` through the REAL
    /// accessibility press action.
    func press(accessibilityIdentifier identifier: String) async throws {
        try await waitFor(
            { self.element(withIdentifier: identifier) != nil },
            timeout: .seconds(4),
            diagnostic: "button '\(identifier)' never appeared; found: \(self.foundIdentifiers())")
        guard let element = element(withIdentifier: identifier) else {
            throw DriverError.pressFailed("'\(identifier)' vanished before the press")
        }
        guard element.press() else {
            throw DriverError.pressFailed(
                "'\(identifier)' refused the press action; found: \(foundIdentifiers())")
        }
    }

    /// The status badge's text.
    func statusText() -> String {
        guard let badge = element(withIdentifier: "lint-status") else { return "" }
        return badge.string(kAXValueAttribute, selectorName: "accessibilityValue")
            ?? badge.string(kAXTitleAttribute, selectorName: "accessibilityLabel")
            ?? badge.string(kAXDescriptionAttribute, selectorName: "accessibilityDescription")
            ?? ""
    }

    /// All notice texts currently on screen.
    func noticeTexts() -> [String] {
        var texts: [String] = []
        for index in 0..<16 {
            guard let notice = element(withIdentifier: "lint-notice-\(index)") else { break }
            let text = notice.string(kAXValueAttribute, selectorName: "accessibilityValue")
                ?? notice.string(kAXTitleAttribute, selectorName: "accessibilityTitle")
                ?? notice.string(kAXDescriptionAttribute, selectorName: "accessibilityDescription")
                ?? ""
            if !text.isEmpty { texts.append(text) }
        }
        return texts
    }

    /// Whether a control with the identifier is currently present.
    func hasControl(_ identifier: String) -> Bool {
        element(withIdentifier: identifier) != nil
    }

    // MARK: - Lifecycle

    /// Close the window through AppKit's real close path. Idempotent and
    /// exactly-once — a second call is a no-op, so a `.timeLimit`
    /// cancellation cannot double-close. A short bounded run-loop drain
    /// after close lets the document WebView's teardown complete before the
    /// test process can exit mid-teardown (a known exit-segfault source).
    func close() {
        guard !isClosed else { return }
        isClosed = true
        window.performClose(nil)
        if window.isVisible { window.close() }
        // Drop the hosting view (and the document WKWebView inside it)
        // synchronously, then drain the main loop so WebKit's teardown
        // completes HERE rather than racing process exit — the latter
        // segfaults swiftpm-testing-helper at exit.
        window.contentView = NSView()
        RunLoop.main.run(mode: RunLoop.Mode.default, before: Date().addingTimeInterval(1.0))
    }

    // MARK: - Recorded Apply calls

    var applyCallCount: Int { applyRecorder.calls.count }
    var appliedCandidates: [String] { applyRecorder.candidates }
}
#endif
