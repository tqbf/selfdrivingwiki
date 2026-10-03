#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WikiFS
@testable import WikiFSCore

/// Real hosted-`NSWindow` scenarios for the wiki Strategy editor (AC.4).
/// The real ``WikiStrategyEditorView`` and the real production confirmation
/// surfaces (``WikiStrategyInlineConfirmation``, the editor's pending-action
/// row, and ``WikiStrategySwitchConfirmBanner``, RootScene's window-level
/// wiki-switch guard) are mounted against the real ``WikiStoreModel`` over a
/// disposable GRDB database. Every workflow step is driven through REAL
/// controls and asserted at the model/store seam — an interaction that drives
/// nothing fails the scenario.
///
/// ## How controls are found and driven (rendered output, not view classes)
///
/// SwiftUI renders default-style `Button`s and menu-style `Picker`s itself:
/// under `NSHostingView` they never materialize as `NSButton`/`NSPopUpButton`
/// in the AppKit view tree (verified against this host — only the
/// `TextField`→`NSTextField` and `TextEditor`→`NSTextView` bridges exist).
/// The accessibility route is unavailable in this harness: the system AX
/// API vends nothing (`api-disabled` without an Accessibility TCC grant —
/// the same environment limitation `ActivityWindowWorkspaceHostedTests`
/// documents), and the in-process `NSAccessibility` walk returns exactly one
/// empty `AXGroup`. No production UI is changed to materialize AppKit
/// controls for tests.
///
/// Control GEOMETRY therefore comes from the real mounted view, measured at
/// runtime through two layers:
///
/// 1. **The real AppKit views SwiftUI mounts.** SwiftUI bridges focusable
///    controls to real AppKit proxy views (`_FocusRingView` and the
///    platform-view hosts — verified in this host: four rings for the
///    controls row's three buttons and the template picker). Their frames
///    ARE the controls' real on-screen frames (the same geometry-parity
///    seam `ActivityWindowWorkspaceHostedTests` presses its toolbar toggle
///    at), and each proxy is asked DIRECTLY for its accessibility role and
///    label — per-view queries, not the vend-nothing system AX tree.
/// 2. **Measured control-row structure.** When a proxy vends no label, the
///    controls row is identified structurally from MEASURED frames: the
///    row's focus-ring proxies share one baseline and sort left-to-right
///    into the authored control order (`controlsRow`: Save, Cancel, Reset
///    to Default, then the picker), so ring i ↔ authored control i. The
///    mapping is validated against the measured tree and refuses to guess
///    when the structure does not match.
/// 3. **Measured two-button surfaces.** The inline confirmations and the
///    conflict/switch banners each render two buttons on one baseline; the
///    rings group into measured rows, the confirmation is the LOWEST such
///    row (authored directly above the fields, below any banner), and each
///    row's rings map left-to-right onto that surface's authored button
///    order. The mounted row COUNT is the presence assertion.
///
/// Pixel-reading the window's composited output is not an option here: the
/// `CGWindowList…Image` family is obsoleted (ScreenCaptureKit requires a
/// screen-recording grant even for own windows, which a CLI test host
/// cannot obtain), and SwiftUI's Metal content never draws through the
/// `NSView` draw path. No screen capture and no screen-coordinate events
/// happen at all — no other app's window can ever be tested or clicked.
///
/// Interaction goes through REAL events at those real measured frames,
/// on two routes separated by a MEASURED button-role boundary:
///
/// - Synthesized `NSEvent` mouse down/up delivered through
///   `NSWindow.sendEvent` (the route `AppearanceSettingsHostedTests`
///   and `ActivityWindowWorkspaceHostedTests` use; `performClick` is
///   ignored). Measured boundary: this route drives PLAIN-role
///   SwiftUI buttons in this host and is INERT on `role: .destructive`
///   buttons — the event is delivered, the action never runs
///   (confirmed by the glm-ui-root-cause job). The three destructive
///   confirms (“Reset Strategy”, “Reload Draft”, “Discard Changes &
///   Switch”) therefore go through their REGISTERED default action:
///   one real Return keyDown/keyUp pair through `window.sendEvent`
///   after focus release
///   (``confirmDefaultAction(labeled:mountedSurfaces:in:)``).
/// - Text input goes through the REAL bridged `NSTextView`/
///   `NSTextField`: first responder plus `insertText` — the entry
///   point keyboard input uses.
///
/// The template picker's menu is an HONEST DECLARED GAP: opening the
/// real menu from posted events terminated the shared CLI test host
/// the one time it was attempted (documented at
/// ``chooseTemplate(_:in:)``), so that step fails fast with the
/// observation instead of risking every other suite in the target.
///
/// ## Fail fast, never cascade
///
/// Every lookup and interaction THROWS: one failed prerequisite stops the
/// scenario with a diagnostic (including the text lines the harness actually
/// saw rendered) instead of recording dozens of follow-on failures.
///
/// Not coverable in this harness, stated honestly:
/// - The tab-close confirmation is an ESTABLISHED system alert (ContentView,
///   pendingCloseTabID pattern) — replacing established UX just for tests is
///   out of scope, and system alert buttons are not clickable headless. Its
///   strategy-draft effects are asserted at the model seam, with the alert
///   wiring itself unchanged production code.
/// - Enabled-state evidence: accessibility `AXEnabled` is not vendable in
///   this harness, so the BEHAVIORAL probe is the assertion — a real press
///   on a disabled control must drive nothing (checked unconditionally).
@Suite(.serialized, .timeLimit(.minutes(3)))
@MainActor
struct WikiStrategyEditorScenarioTests {
    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return app
    }()

    /// The strings the template picker's menu button can render as its own
    /// label (`nil` selection keeps the prompt row selected, so the button
    /// shows the prompt). Independent of accessibility labels, which never
    /// render as text.
    private static let pickerButtonLabels = [
        "Choose a template…",
        "Choose a template...",
        "Start from a Template",
    ]

    /// Render/poll tuning (one owner, no magic numbers).
    private enum Discovery {
        /// Post-load waits for the editor form's controls to materialize.
        static let lookupAttempts = 40
        static let lookupGap: Duration = .milliseconds(50)
        /// Two frames whose centers are closer than this describe the same
        /// control found by both discovery layers (view proxies + row).
        static let frameMergeTolerance: CGFloat = 14
        /// Rings within this vertical distance of a shared midY form one
        /// control row (an HStack baseline).
        static let rowBaselineTolerance: CGFloat = 3
    }

    // MARK: - Fixtures

    private static let projectTmpRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("tmp", isDirectory: true)

    private func tempDatabaseURL() throws -> URL {
        let dir = Self.projectTmpRoot
            .appendingPathComponent("strategy-editor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    private func removeFixture(at directory: URL) {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Failed to remove strategy editor fixture: \(error)")
        }
    }

    private func makeModel(databaseURL: URL) throws -> WikiStoreModel {
        let store = try StoreBackend.current.makeStore(databaseURL: databaseURL)
        return WikiStoreModel(store: store)
    }

    /// The production composition RootScene hosts when a wiki switch is
    /// deferred: the switch banner above the session content. The editor is
    /// the session content here; the banner's actions are the production
    /// actions (model cancel / apply + swap recorded).
    private struct SwitchGuardHost: View {
        @Bindable var store: WikiStoreModel
        let wikiName: String
        let onPerformSwitch: (WikiID) -> Void

        var body: some View {
            VStack(spacing: 0) {
                if store.pendingStrategyWikiSwitch != nil {
                    WikiStrategySwitchConfirmBanner(
                        store: store,
                        targetDisplayName: "Other Wiki",
                        onPerformSwitch: {
                            if let target = store.applyPendingStrategyWikiSwitch() {
                                onPerformSwitch(target)
                            }
                        })
                }
                WikiStrategyEditorView(store: store, wikiDisplayName: wikiName)
            }
        }
    }

    /// Fail-fast error: one message, one failure, no cascade.
    private struct ScenarioFailure: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: - Hosting

    /// Mount a view in a window, load the strategy through the model seam,
    /// and wait for the editor form's REAL precondition: the strategy read
    /// completing and the form's Save label rendering in the view's actual
    /// draw output. The editor's own `.task` may never run in a headless
    /// host, so the harness drives the same load call itself.
    @discardableResult
    private func host<Content: View>(
        _ view: Content,
        model: WikiStoreModel,
        appearance: NSAppearance? = nil,
        size: NSSize = NSSize(width: 720, height: 900)
    ) async throws -> NSWindow {
        let controller = NSHostingController(rootView: view)
        let hosting = controller.view
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        if let appearance {
            window.appearance = appearance
            hosting.appearance = appearance
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        model.loadWikiStrategy()
        for _ in 0..<60 {
            if model.strategyDidLoad || model.strategyLoadFailed { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard model.strategyDidLoad else {
            throw ScenarioFailure(description: """
                strategy never loaded (loadFailed=\(model.strategyLoadFailed)) — \
                the editor form cannot materialize
                """)
        }
        for _ in 0..<Discovery.lookupAttempts {
            window.layoutIfNeeded()
            hosting.layoutSubtreeIfNeeded()
            if findButton(labeled: "Save", in: window) { return window }
            try await Task.sleep(for: Discovery.lookupGap)
        }
        throw ScenarioFailure(description: """
            the editor form's Save label never rendered — rendered text: \
            \(renderedTextSummary(in: window)); \
            AppKit subviews: \(allSubviews(of: hosting).map { String(describing: Swift.type(of: $0)) }.prefix(25))
            """)
    }

    private func settle(_ ms: Int = 150) async throws {
        try await Task.sleep(for: .milliseconds(ms))
    }

    // MARK: - Rendered-output control discovery

    /// Every subview of `root`, depth-first, including `root`.
    private func allSubviews(of root: NSView) -> [NSView] {
        var out = [root]
        for child in root.subviews {
            out.append(contentsOf: allSubviews(of: child))
        }
        return out
    }

    /// Frames of every occurrence of `label` on the mounted controls, in
    /// WINDOW coordinates, merged across the two discovery layers. Empty
    /// when no layer finds it — callers decide whether absence is expected.
    private func renderedLabelFrames(_ label: String, in window: NSWindow) -> [CGRect] {
        let viaViews = bridgedViewControls(in: window)
            .filter { $0.label.normalizedLabel == label.normalizedLabel }
            .map(\.frame)
        let viaRow = controlsRowFrame(labeled: label, in: window)
        return merged(viaViews + viaRow)
    }

    /// Collapses near-duplicate frames (the same control found by both
    /// layers); the bridged-view frame wins because it is the exact
    /// AppKit frame, and later duplicates are dropped.
    private func merged(_ frames: [CGRect]) -> [CGRect] {
        var out = [CGRect]()
        for frame in frames {
            guard !out.contains(where: { existing in
                hypot(existing.midX - frame.midX, existing.midY - frame.midY)
                    < Discovery.frameMergeTolerance
            }) else { continue }
            out.append(frame)
        }
        return out
    }

    /// Non-throwing presence probe (used where the scenario continues).
    private func findButton(labeled label: String, in window: NSWindow) -> Bool {
        !renderedLabelFrames(label, in: window).isEmpty
    }

    /// The label's unique rendered frame, or a fail-fast error carrying what
    /// the harness actually saw. Ambiguity is a defect in the surfaces' label
    /// set (they author distinct labels), so it fails just as loudly.
    private func requireLabelFrame(labeled label: String, in window: NSWindow) throws -> CGRect {
        let matches = renderedLabelFrames(label, in: window)
        switch matches.count {
        case 1:
            return matches[0]
        case 0:
            throw ScenarioFailure(description: """
                “\(label)” is not rendered in the mounted view — rendered text: \
                \(renderedTextSummary(in: window))
                """)
        default:
            throw ScenarioFailure(description: """
                “\(label)” rendered \(matches.count) times (frames: \(matches)) — \
                the view's label set has a defect
                """)
        }
    }

    /// A short, human-readable summary of what the harness can actually see,
    /// for failure diagnostics: labeled bridged controls plus every measured
    /// proxy frame, so a discovery regression is debuggable from the test
    /// log alone.
    private func renderedTextSummary(in window: NSWindow) -> String {
        guard window.contentView != nil else { return "no content view" }
        let describedControls = bridgedViewControls(in: window).prefix(20).map { control in
            "\(control.role) “\(control.label)” @\(Int(control.frame.minX)),\(Int(control.frame.minY)) \(Int(control.frame.width))×\(Int(control.frame.height))"
        }
        let describedProxies = proxyFrames(in: window).prefix(20).map { name, frame in
            "\(name) @\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height))"
        }
        return [
            describedControls.isEmpty ? "views[none]" : "views[\(describedControls.joined(separator: " | "))]",
            describedProxies.isEmpty ? "proxies[none]" : "proxies[\(describedProxies.joined(separator: " | "))]",
        ].joined(separator: "; ")
    }

    // MARK: Discovery layer A: the real AppKit views SwiftUI mounts

    /// One control discovered on a real bridged AppKit view.
    private struct BridgedControl {
        let label: String
        let role: String
        /// Window-space frame of the real mounted view.
        let frame: CGRect
    }

    /// Controls the real AppKit proxy views expose, asked DIRECTLY per view
    /// (role + label + frame). SwiftUI's own content never draws through the
    /// `NSView` draw path (verified: `dataWithPDF` renders only the bridged
    /// AppKit text), but the proxies it mounts for focusable controls carry
    /// the controls' real frames — the same geometry-parity seam
    /// `ActivityWindowWorkspaceHostedTests` presses.
    private func bridgedViewControls(in window: NSWindow) -> [BridgedControl] {
        guard let surface = window.contentView else { return [] }
        return allSubviews(of: surface).compactMap { view in
            guard let role = view.accessibilityRole(),
                  let label = view.accessibilityLabel(),
                  !label.isEmpty
            else { return nil }
            return BridgedControl(
                label: label,
                role: role.rawValue,
                frame: view.convert(view.bounds, to: nil))
        }
    }

    /// Class name + window-space frame of every focus-ring/platform proxy in
    /// the tree — the raw measured geometry, included in failure diagnostics
    /// so a discovery regression is debuggable from the test log alone.
    private func proxyFrames(in window: NSWindow) -> [(String, CGRect)] {
        guard let surface = window.contentView else { return [] }
        return allSubviews(of: surface).compactMap { view in
            let name = String(describing: Swift.type(of: view))
            guard name.contains("FocusRing") || name.contains("PlatformViewHost") else {
                return nil
            }
            return (name, view.convert(view.bounds, to: nil))
        }
    }

    // MARK: Discovery layer B: measured control-row structure

    /// The authored button order of the editor's controls row
    /// (`WikiStrategyEditorView.controlsRow`), left-to-right — the identity
    /// map for the row's measured focus-ring proxies when they vend no
    /// labels. The picker (trailing, after a Spacer) is handled separately.
    private static let controlsRowButtons = ["Save", "Cancel", "Reset to Default"]

    /// The frame for `label` identified from MEASURED focus-ring proxies,
    /// used when the per-view accessibility layer vends nothing. SwiftUI
    /// mounts one focus-ring proxy per focusable control; the controls row
    /// renders its authored controls left-to-right on one baseline, so the
    /// row's rings, sorted by x, map 1:1 to the authored order. Returns
    /// nothing when the measured tree does not match that structure — this
    /// layer never guesses.
    private func controlsRowFrame(labeled label: String, in window: NSWindow) -> [CGRect] {
        guard let row = controlsRowRings(in: window) else { return [] }
        if let index = Self.controlsRowButtons.firstIndex(where: {
            $0.normalizedLabel == label.normalizedLabel
        }) {
            guard index < row.count else { return [] }
            return [row[index]]
        }
        // The template picker: the one trailing ring beyond the authored
        // buttons (it follows the row's Spacer).
        guard row.count == Self.controlsRowButtons.count + 1,
              Self.pickerButtonLabels.contains(where: {
                  $0.normalizedLabel == label.normalizedLabel
              })
        else { return [] }
        return [row[Self.controlsRowButtons.count]]
    }

    /// The controls row's measured ring frames, sorted left-to-right, or nil
    /// when the tree does not hold exactly one plausible row (3 buttons, or
    /// 3 buttons + the picker, on a shared baseline).
    private func controlsRowRings(in window: NSWindow) -> [CGRect]? {
        let plausible = ringRows(in: window).filter {
            (Self.controlsRowButtons.count...Self.controlsRowButtons.count + 1)
                .contains($0.count)
        }
        guard plausible.count == 1 else { return nil }
        return plausible[0]
    }

    // MARK: Measured two-button surfaces (confirmations and banners)

    /// Ring rows currently mounted — each row is the rings sharing one
    /// baseline, sorted left-to-right. Absolute positions shift with the
    /// content above them; identity comes from measured structure (row
    /// count and vertical order) plus the authored button order, never
    /// from remembered coordinates.
    private func ringRows(in window: NSWindow) -> [[CGRect]] {
        let rings = proxyFrames(in: window)
            .filter { $0.0.contains("FocusRing") }
            .map(\.1)
        var rows = [[CGRect]]()
        for ring in rings {
            if let index = rows.firstIndex(where: { row in
                abs(row[0].midY - ring.midY) <= Discovery.rowBaselineTolerance
            }) {
                rows[index].append(ring)
            } else {
                rows.append([ring])
            }
        }
        return rows.map { $0.sorted { $0.minX < $1.minX } }
    }

    /// The mounted two-button rows (inline confirmations and banners),
    /// sorted top-to-bottom.
    private func twoButtonRowsTopToBottom(in window: NSWindow) -> [[CGRect]] {
        ringRows(in: window)
            .filter { $0.count == 2 }
            .sorted { $0[0].midY > $1[0].midY }
    }

    /// How many two-button surfaces are mounted (0, 1, or 2: the banners and
    /// the inline confirmation never stack beyond one of each).
    private func twoButtonRowCount(in window: NSWindow) -> Int {
        twoButtonRowsTopToBottom(in: window).count
    }

    /// Press `label` on the ONE two-button surface currently mounted,
    /// mapping the measured row's left-to-right rings onto `authoredOrder`.
    /// Fails fast unless exactly one such row exists — this never guesses
    /// between surfaces.
    @discardableResult
    private func pressUniqueTwoButton(
        labeled label: String,
        authoredOrder: [String],
        in window: NSWindow
    ) throws -> Bool {
        let rows = twoButtonRowsTopToBottom(in: window)
        guard rows.count == 1 else {
            throw ScenarioFailure(description: """
                expected exactly one two-button surface for “\(label)”, found \
                \(rows.count) — \(renderedTextSummary(in: window))
                """)
        }
        return try pressRowButton(labeled: label, authoredOrder: authoredOrder, row: rows[0], in: window)
    }

    /// Press `label` on the inline confirmation, identified by MEASURED
    /// vertical order: the confirmation is authored directly above the
    /// fields, so it is the LOWEST two-button row; banners render above it.
    /// The row's rings map left-to-right onto the authored
    /// confirm-then-cancel order (``WikiStrategyInlineConfirmation``).
    @discardableResult
    private func pressConfirmationButton(
        labeled label: String,
        confirmation: (confirm: String, cancel: String),
        in window: NSWindow
    ) throws -> Bool {
        let rows = twoButtonRowsTopToBottom(in: window)
        guard let lowest = rows.last else {
            throw ScenarioFailure(description: """
                no two-button surface mounted for the confirmation “\(label)” — \
                \(renderedTextSummary(in: window))
                """)
        }
        return try pressRowButton(
            labeled: label,
            authoredOrder: [confirmation.confirm, confirmation.cancel],
            row: lowest,
            in: window)
    }

    /// Shared row press: the measured row must match the authored button
    /// count, and the label must be one of the authored buttons.
    @discardableResult
    private func pressRowButton(
        labeled label: String,
        authoredOrder: [String],
        row: [CGRect],
        in window: NSWindow
    ) throws -> Bool {
        guard row.count == authoredOrder.count else {
            throw ScenarioFailure(description: """
                the two-button row has \(row.count) rings, the authored \
                surface has \(authoredOrder.count) buttons — \
                \(renderedTextSummary(in: window))
                """)
        }
        guard let index = authoredOrder.firstIndex(where: {
            $0.normalizedLabel == label.normalizedLabel
        }) else {
            throw ScenarioFailure(description: """
                “\(label)” is not one of the authored buttons \(authoredOrder)
                """)
        }
        return try press(frame: row[index], in: window)
    }

    // MARK: Real presses (synthesized mouse events at real rendered frames)

    /// Monotonic event numbers: every synthesized click gets fresh numbers
    /// so AppKit can never mistake a later click for a re-broadcast of an
    /// earlier one (the radio suite in `AppearanceSettingsHostedTests`
    /// uses unique numbers per click — that precedent is plain-role
    /// buttons only; see the role boundary documented at
    /// ``click(atWindowPoint:in:)``). Key events carry no event number,
    /// so the Return route mints none.
    private static var nextEventNumber = 101

    /// Click at a point given in WINDOW coordinates by delivering real
    /// `NSEvent` mouse moved/down/up through the window's event path — the
    /// same route `AppearanceSettingsHostedTests` and
    /// `ActivityWindowWorkspaceHostedTests` use for SwiftUI-rendered
    /// controls. Measured boundary: drives PLAIN-role buttons in this
    /// host; `role: .destructive` buttons are INERT to it (the event is
    /// delivered, the action never runs) — route those through
    /// ``confirmDefaultAction(labeled:mountedSurfaces:in:)`` instead. The
    /// moved event first puts the cursor inside the control, the way a
    /// real click arrives.
    @discardableResult
    private func click(atWindowPoint point: NSPoint, in window: NSWindow) -> Bool {
        let uptime = ProcessInfo.processInfo.systemUptime
        let number = Self.nextEventNumber
        Self.nextEventNumber += 10
        guard
            let moved = NSEvent.mouseEvent(
                with: .mouseMoved, location: point, modifierFlags: [],
                timestamp: uptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: number, clickCount: 0, pressure: 0),
            let down = NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: uptime + 0.01, windowNumber: window.windowNumber,
                context: nil, eventNumber: number + 1, clickCount: 1, pressure: 1),
            let up = NSEvent.mouseEvent(
                with: .leftMouseUp, location: point, modifierFlags: [],
                timestamp: uptime + 0.06, windowNumber: window.windowNumber,
                context: nil, eventNumber: number + 2, clickCount: 1, pressure: 0)
        else { return false }
        window.sendEvent(moved)
        window.sendEvent(down)
        window.sendEvent(up)
        return true
    }

    /// Press the control whose measured frame is `frame` (WINDOW
    /// coordinates — both discovery layers report window-space frames): the
    /// label/ring frame lives inside its control, so its center is inside
    /// the control's real hit area.
    @discardableResult
    private func press(frame: CGRect, in window: NSWindow) throws -> Bool {
        click(
            atWindowPoint: NSPoint(x: frame.midX, y: frame.midY),
            in: window)
    }

    /// Find and press in one step — the standard scenario action.
    @discardableResult
    private func press(labeled label: String, in window: NSWindow) throws -> Bool {
        let frame = try requireLabelFrame(labeled: label, in: window)
        guard try press(frame: frame, in: window) else {
            throw ScenarioFailure(description: """
                could not synthesize a mouse press for “\(label)” at its \
                rendered frame \(frame)
                """)
        }
        return true
    }

    // MARK: Real Return key (registered default-action confirms)

    /// Key-route tuning (one owner, no magic numbers).
    private enum KeyRoute {
        /// `kVK_Return` — the Return key's hardware scan code.
        static let returnKeyCode: UInt16 = 36
        /// The character Return carries in both `characters` fields.
        static let returnCharacter = "\r"
    }

    /// Confirm a mounted DESTRUCTIVE confirmation through its REGISTERED
    /// default action: release focus, then dispatch one REAL Return
    /// keyDown/keyUp pair through `NSWindow.sendEvent`.
    ///
    /// Why a key route (measured in this host, confirmed by the
    /// glm-ui-root-cause job): the synthesized mouse press that drives
    /// plain-role SwiftUI buttons here is INERT on `role: .destructive`
    /// buttons — the event is delivered, the action never runs — while
    /// those same surfaces' `.keyboardShortcut(.defaultAction)`
    /// registration DOES fire on a real Return pair once focus is
    /// released (a focused text editor consumes Return before the
    /// default-action route sees it). Exactly the three destructive
    /// confirms — “Reset Strategy”, “Reload Draft”, “Discard Changes &
    /// Switch” — use this route; every other control keeps the mouse.
    ///
    /// Bounded and structural BEFORE any key is dispatched:
    /// - `mountedSurfaces` is the FULL expected two-button composition,
    ///   top-to-bottom, each with its authored button order and whether
    ///   that surface registers its confirm as the window default action.
    ///   The MEASURED rows must match that composition exactly.
    /// - Exactly ONE default-action surface may be mounted, and `label`
    ///   must be one of ITS authored buttons — with two default-action
    ///   surfaces mounted, which one receives Return is an implementation
    ///   detail of shortcut resolution, not a scenario the harness may
    ///   assert.
    ///
    /// The dispatch is one key pair — no retries, no polling. The
    /// scenario's model-seam assertion immediately after is the evidence
    /// the key drove the confirm (an interaction that drives nothing
    /// fails the scenario, the suite's standing rule).
    private func confirmDefaultAction(
        labeled label: String,
        mountedSurfaces: [(authoredOrder: [String], registersDefaultAction: Bool)],
        in window: NSWindow
    ) throws {
        let rows = twoButtonRowsTopToBottom(in: window)
        guard rows.count == mountedSurfaces.count else {
            throw ScenarioFailure(description: """
                expected \(mountedSurfaces.count) two-button surface(s) mounted \
                for the default-action confirm “\(label)”, measured \(rows.count) — \
                \(renderedTextSummary(in: window))
                """)
        }
        for (row, surface) in zip(rows, mountedSurfaces)
        where row.count != surface.authoredOrder.count {
            throw ScenarioFailure(description: """
                a mounted row carries \(row.count) rings but its surface \
                “\(surface.authoredOrder)” authors \(surface.authoredOrder.count) \
                buttons — \(renderedTextSummary(in: window))
                """)
        }
        let defaultSurfaces = mountedSurfaces.filter { $0.registersDefaultAction }
        guard defaultSurfaces.count == 1,
              defaultSurfaces[0].authoredOrder.contains(where: {
                  $0.normalizedLabel == label.normalizedLabel
              })
        else {
            throw ScenarioFailure(description: """
                “\(label)” must be the only mounted default-action confirm — \
                expected exactly one default-action surface containing it, found \
                \(defaultSurfaces.count) — \(renderedTextSummary(in: window))
                """)
        }

        // Focus release: a focused text editor consumes Return before the
        // window's default-action route can see the key.
        window.makeFirstResponder(nil)

        // Key events carry no event number (unlike mouse events), so real
        // timestamps are the only ordering the pair needs.
        let uptime = ProcessInfo.processInfo.systemUptime
        guard
            let down = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: uptime, windowNumber: window.windowNumber,
                context: nil, characters: KeyRoute.returnCharacter,
                charactersIgnoringModifiers: KeyRoute.returnCharacter,
                isARepeat: false, keyCode: KeyRoute.returnKeyCode),
            let up = NSEvent.keyEvent(
                with: .keyUp, location: .zero, modifierFlags: [],
                timestamp: uptime + 0.02, windowNumber: window.windowNumber,
                context: nil, characters: KeyRoute.returnCharacter,
                charactersIgnoringModifiers: KeyRoute.returnCharacter,
                isARepeat: false, keyCode: KeyRoute.returnKeyCode)
        else {
            throw ScenarioFailure(description: """
                could not synthesize a Return key pair for “\(label)”
                """)
        }
        window.sendEvent(down)
        window.sendEvent(up)
    }

    // MARK: Real text input (bridged NSTextView / NSTextField)

    /// The strategy instructions editor: SwiftUI `TextEditor` bridges to a
    /// real `NSTextView` (verified in this host).
    private func instructionsTextView(in root: NSView) -> NSTextView? {
        allSubviews(of: root).compactMap { $0 as? NSTextView }.first
    }

    /// The display-name field: SwiftUI `TextField(.roundedBorder)` bridges to
    /// a real `NSTextField` (verified in this host).
    private func nameField(in root: NSView) -> NSTextField? {
        allSubviews(of: root).compactMap { $0 as? NSTextField }.first
    }

    /// Type `text` at the end of the hosted text view through the real
    /// input path: first responder, then `insertText` (the entry point
    /// keyboard input and input methods use), which posts the change
    /// notification SwiftUI's binding listens to.
    private func type(_ text: String, into textView: NSTextView, in window: NSWindow) throws {
        guard window.makeFirstResponder(textView) else {
            throw ScenarioFailure(description: "instructions editor refused first responder")
        }
        textView.insertText(
            text,
            replacementRange: NSRange(location: (textView.string as NSString).length, length: 0))
        guard textView.string.hasSuffix(text) else {
            throw ScenarioFailure(description: """
                insertText did not land in the instructions editor \
                (got \(String(describing: textView.string.suffix(40))))
                """)
        }
    }

    /// Set the display name through the field editor and commit the edit the
    /// way a real edit commits (ending the first-responder session), then
    /// VERIFY the model binding took the value — a silent non-commit fails
    /// here instead of cascading.
    private func setName(_ text: String, in window: NSWindow, store: WikiStoreModel) async throws {
        guard let content = window.contentView,
              let field = nameField(in: content) else {
            throw ScenarioFailure(description: "no bridged NSTextField for the display-name field")
        }
        guard window.makeFirstResponder(field),
              let editor = window.firstResponder as? NSText
        else {
            throw ScenarioFailure(description: "display-name field refused first responder")
        }
        editor.selectAll(nil)
        editor.insertText(text)
        window.makeFirstResponder(nil)
        try await settle(50)
        guard store.strategyDraftName == text else {
            throw ScenarioFailure(description: """
                name edit did not commit through the field editor — model has \
                “\(store.strategyDraftName)”
                """)
        }
    }

    // MARK: Real template-picker menu drive (posted events)

    /// Choose a template through the REAL menu-style picker the way a
    /// keyboard user does: a posted real click opens the real menu (posting
    /// asynchronously — a synchronous `sendEvent` mouse-down would enter
    /// menu tracking on the test's own stack and never return), then posted
    /// real Down-key events walk the menu's rows (row 0 is the
    /// "Choose a template…" prompt, rows 1… follow `WikiStrategyTemplates.all`
    /// order) and Return commits the row. The picker's `onChange` fires the
    /// same path a real selection does; callers verify the draft at the
    /// model seam.
    private func chooseTemplate(_ id: WikiStrategyTemplateID, in window: NSWindow) async throws {
        // One canonical label: the candidates are alternate spellings of
        // the SAME button, so the first candidate that resolves to exactly
        // one frame wins and later candidates are not consulted.
        var pickerFrame: CGRect?
        for candidate in Self.pickerButtonLabels where pickerFrame == nil {
            let matches = renderedLabelFrames(candidate, in: window)
            guard !matches.isEmpty else { continue }
            guard matches.count == 1 else {
                throw ScenarioFailure(description: """
                    the template picker's button label is ambiguous \
                    (candidate “\(candidate)”, \(matches.count) frames) — \
                    rendered text: \(renderedTextSummary(in: window))
                    """)
            }
            pickerFrame = matches[0]
        }
        guard let frame = pickerFrame else {
            throw ScenarioFailure(description: """
                the template picker's button never rendered — rendered text: \
                \(renderedTextSummary(in: window))
                """)
        }
        guard let templateIndex = WikiStrategyTemplates.all.firstIndex(where: { $0.id == id }) else {
            throw ScenarioFailure(description: "template \(id) is not in WikiStrategyTemplates.all")
        }

        // HONEST BLOCKER (observed in-run): driving the real menu through
        // posted window-routed events — click to open, Down × row, Return —
        // SILENTLY TERMINATED the test host process the first time it ran
        // (swift test exited 0 with the log truncated mid-suite; the three
        // tests after this point never executed). In-process menu tracking
        // is not survivable for the shared CLI test host, so this step
        // fails fast instead of risking every other suite in the target.
        // The picker's button still resolves above (its measured frame is
        // real); a supported menu-drive route — e.g. a dedicated executable
        // test host — is the remaining work.
        throw ScenarioFailure(description: """
            the template picker's real menu cannot be driven in this host — \
            posted menu events terminated the test process (observed once); \
            picker frame resolved at \(frame), template row \
            \(templateIndex + 1)
            """)
    }

    // MARK: - AC.4 saveCancelReset

    @Test func saveCancelReset() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        _ = Self.app
        let databaseURL = try tempDatabaseURL()
        defer { removeFixture(at: databaseURL.deletingLastPathComponent()) }
        let model = try makeModel(databaseURL: databaseURL)
        let window = try await host(
            WikiStrategyEditorView(store: model, wikiDisplayName: "Scenario Wiki"),
            model: model)
        defer { window.orderOut(nil) }
        let contentView = try #require(window.contentView)

        // Fresh wiki: Default strategy; Save/Cancel/Reset disabled (nothing
        // dirty). Enabled evidence is behavioral (AXEnabled is not vendable
        // here): a real press on a clean draft must save nothing.
        try #require(findButton(labeled: "Save", in: window), "Save must render on a clean draft")
        try #require(findButton(labeled: "Cancel", in: window), "Cancel must render on a clean draft")
        try #require(findButton(labeled: "Reset to Default", in: window), "Reset must render on a clean draft")
        try press(labeled: "Save", in: window)
        try await settle()
        #expect(try model.internalStore.getWikiStrategy() == nil,
                "pressing Save on a clean draft must not save")
        #expect(!model.isStrategyDraftDirty)

        // Type a name and instructions through the REAL text controls.
        try await setName("Story Notes", in: window, store: model)
        let instructions = try #require(instructionsTextView(in: contentView))
        try type("Track characters and themes.", into: instructions, in: window)
        try await settle()
        #expect(model.isStrategyDraftDirty, "typing through the real controls must mark the draft dirty")

        // SAVE through a real press.
        try press(labeled: "Save", in: window)
        try await settle()
        #expect(!model.isStrategyDraftDirty)
        let saved = try #require(try model.internalStore.getWikiStrategy())
        #expect(saved.name == "Story Notes")
        #expect(saved.instructions == "Track characters and themes.")
        #expect(saved.revision.rawValue == 1)

        // Edit again, then CANCEL through a real press: draft reverts.
        try type(" Extra.", into: try #require(instructionsTextView(in: contentView)), in: window)
        try await settle()
        #expect(model.isStrategyDraftDirty)
        try press(labeled: "Cancel", in: window)
        try await settle()
        #expect(!model.isStrategyDraftDirty)
        #expect(model.strategyDraftInstructions == "Track characters and themes.")

        // RESET through the real button + the real inline confirmation.
        try press(labeled: "Reset to Default", in: window)
        try await settle()
        #expect(twoButtonRowCount(in: window) == 1,
                "arming Reset must show the inline confirmation")
        // “Reset Strategy” is a destructive-role confirm: the real Return
        // key drives its registered default action (synthetic mouse is
        // inert on destructive-role buttons in this host).
        try confirmDefaultAction(
            labeled: "Reset Strategy",
            mountedSurfaces: [
                (authoredOrder: ["Reset Strategy", "Keep Current Draft"],
                 registersDefaultAction: true),
            ],
            in: window)
        try await settle()
        #expect(try model.internalStore.getWikiStrategy() == nil, "reset returns the wiki to Default")
        #expect(try #require(try model.internalStore.wikiStrategyRevision()).rawValue == 2,
                "reset keeps the revision monotonic via the tombstone")
        #expect(!model.isStrategyDraftDirty)
    }

    // MARK: - AC.4 switchProtectsDraft

    /// Three protections in one scenario: (1) the in-place wiki switch — ANY
    /// registry.select origin, guarded at RootScene's boundary — defers
    /// behind the REAL production banner whose REAL buttons are pressed
    /// here; (2) navigation away and back is non-destructive by construction
    /// (the draft lives on the model); (3) tab close reuses the established
    /// system alert, whose model-seam effects are asserted (the alert's own
    /// buttons are not clickable headless — declared gap). Production order
    /// throughout: the strategy tab exists BEFORE the user edits in it (the
    /// editor lives inside that tab).
    @Test func switchProtectsDraft() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        _ = Self.app
        let databaseURL = try tempDatabaseURL()
        defer { removeFixture(at: databaseURL.deletingLastPathComponent()) }
        let model = try makeModel(databaseURL: databaseURL)
        var performedSwitchTo: WikiID?
        let window = try await host(
            SwitchGuardHost(store: model, wikiName: "Protected Wiki") { performedSwitchTo = $0 },
            model: model)
        defer { window.orderOut(nil) }
        let contentView = try #require(window.contentView)

        // Production order: the strategy tab exists before editing in it.
        model.openTab(.strategy)
        try await settle()
        let tabID = try #require(model.activeTab?.id)

        // Dirty the draft through the real text controls. The mounted editor
        // marks the STRATEGY tab editing (the path the close guard uses).
        try await setName("Protected", in: window, store: model)
        try type("unsaved work", into: try #require(instructionsTextView(in: contentView)), in: window)
        try await settle()
        #expect(model.isStrategyDraftDirty)
        #expect(model.activeTab?.isEditing == true,
                "the mounted editor must sync the tab edit marker while dirty")

        // (1) Tab close protection (established system alert, asserted at the
        // seam — its buttons cannot be clicked headless; wiring unchanged).
        model.closeTab(id: tabID)
        #expect(model.pendingCloseTabID == tabID, "closing a dirty strategy tab must defer for confirmation")
        model.cancelCloseTab()
        #expect(model.tabs.contains { $0.id == tabID })

        // (2) Navigation away and back: the draft is stashed on the MODEL,
        // so returning loses nothing (the pendingChatDraft pattern).
        model.openTab(.changeLog)
        try await settle()
        model.selectTab(id: tabID)
        try await settle()
        #expect(model.strategyDraftName == "Protected")
        #expect(model.strategyDraftInstructions == "unsaved work")

        // (3) In-place wiki switch: RootScene's boundary guard defers (this
        // is the exact call the scene makes on any registry.select change).
        let otherWiki = WikiID(rawValue: "01TESTWIKISWITCHTARGET")
        #expect(model.deferInPlaceWikiSwitchIfNeeded(to: otherWiki) == true)
        try await settle()
        #expect(model.pendingStrategyWikiSwitch == otherWiki)

        // The REAL production banner's REAL "Keep Editing" button: stays,
        // draft intact, banner gone.
        let switchBannerButtons = ["Discard Changes & Switch", "Keep Editing"]
        #expect(twoButtonRowCount(in: window) == 1,
                "the deferred switch must present the real banner")
        try pressUniqueTwoButton(labeled: "Keep Editing", authoredOrder: switchBannerButtons, in: window)
        try await settle()
        #expect(model.pendingStrategyWikiSwitch == nil)
        #expect(model.isStrategyDraftDirty)
        #expect(twoButtonRowCount(in: window) == 0,
                "the switch banner must dismiss with no pending confirmation")

        // The REAL "Discard Changes & Switch" button: drops the draft and
        // performs the switch (the scene's onPerformSwitch runs the swap).
        #expect(model.deferInPlaceWikiSwitchIfNeeded(to: otherWiki))
        try await settle()
        // “Discard Changes & Switch” is a destructive-role confirm: the
        // real Return key drives its registered default action.
        try confirmDefaultAction(
            labeled: "Discard Changes & Switch",
            mountedSurfaces: [
                (authoredOrder: switchBannerButtons, registersDefaultAction: true),
            ],
            in: window)
        try await settle()
        #expect(performedSwitchTo == otherWiki, "confirming the banner must drive the session swap")
        #expect(!model.isStrategyDraftDirty && model.strategyDraftName.isEmpty)
        #expect(model.pendingStrategyWikiSwitch == nil)

        // Tab close after the draft is gone closes without the confirm.
        model.closeTab(id: tabID)
        #expect(model.pendingCloseTabID == nil)
    }

    // MARK: - AC.4 conflictPreservesDraft

    @Test func conflictPreservesDraft() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        _ = Self.app
        let databaseURL = try tempDatabaseURL()
        defer { removeFixture(at: databaseURL.deletingLastPathComponent()) }
        let model = try makeModel(databaseURL: databaseURL)
        let window = try await host(
            WikiStrategyEditorView(store: model, wikiDisplayName: "Conflict Wiki"),
            model: model)
        defer { window.orderOut(nil) }
        let contentView = try #require(window.contentView)

        // Save a first strategy through the real controls.
        try await setName("Mine", in: window, store: model)
        try type("my instructions", into: try #require(instructionsTextView(in: contentView)), in: window)
        try await settle()
        try press(labeled: "Save", in: window)
        try await settle()
        let revision1 = try #require(try model.internalStore.wikiStrategyRevision())

        // Another editor commits on a SECOND real connection to the same
        // WAL database (the AC.6 two-connection pattern).
        let otherEditor = try StoreBackend.current.makeStore(databaseURL: databaseURL)
        _ = try otherEditor.saveWikiStrategy(
            name: "Theirs", instructions: "their instructions",
            expectedRevision: revision1)

        // Keep editing and SAVE: the store must throw the conflict, the
        // editor must preserve the draft and show the banner with Reload.
        try type(" and more", into: try #require(instructionsTextView(in: contentView)), in: window)
        try await settle()
        try press(labeled: "Save", in: window)
        try await settle()
        #expect(model.strategyConflict != nil, "a stale-revision save must surface the conflict")
        #expect(model.strategyDraftInstructions == "my instructions and more",
                "the conflict must NOT overwrite the draft")
        #expect(model.isStrategyDraftDirty)
        let conflictBannerButtons = ["Reload From Wiki", "Keep Draft"]
        #expect(twoButtonRowCount(in: window) == 1,
                "the conflict banner must present its two real buttons")

        // KEEP DRAFT (real button): the banner dismisses, the conflict stays
        // UNRESOLVED (a re-mount must not re-read its way past it), the
        // draft survives, and the stale expectation is NOT refreshed —
        // saving again conflicts AGAIN rather than overwriting the winner.
        try pressUniqueTwoButton(labeled: "Keep Draft", authoredOrder: conflictBannerButtons, in: window)
        try await settle()
        #expect(model.isStrategyConflictDismissed, "Keep Draft dismisses the banner but keeps the conflict unresolved")
        #expect(model.strategyConflict != nil)
        #expect(model.strategyDraftInstructions == "my instructions and more")
        try press(labeled: "Save", in: window)
        try await settle()
        #expect(model.strategyConflict != nil && !model.isStrategyConflictDismissed,
                "keeping a draft must never authorize overwriting the winner")
        #expect(model.strategyDraftInstructions == "my instructions and more")

        // RELOAD (real banner button + real confirmation button): the draft
        // adopts the committed winner AND its revision.
        #expect(twoButtonRowCount(in: window) == 1,
                "the returned conflict banner must present its two real buttons")
        try pressUniqueTwoButton(labeled: "Reload From Wiki", authoredOrder: conflictBannerButtons, in: window)
        try await settle()
        #expect(twoButtonRowCount(in: window) == 2,
                "arming Reload must show the inline confirmation beside the banner")
        // “Reload Draft” is a destructive-role confirm: the real Return
        // key drives its registered default action. The conflict banner
        // above mounts plain buttons (no default action), so the
        // confirmation's confirm is the unique Return target.
        try confirmDefaultAction(
            labeled: "Reload Draft",
            mountedSurfaces: [
                (authoredOrder: conflictBannerButtons, registersDefaultAction: false),
                (authoredOrder: ["Reload Draft", "Keep Current Draft"],
                 registersDefaultAction: true),
            ],
            in: window)
        try await settle()
        #expect(model.strategyConflict == nil)
        #expect(!model.isStrategyDraftDirty)
        #expect(model.strategyDraftName == "Theirs")
        #expect(model.strategyDraftInstructions == "their instructions")

        // After adoption, the user is editing the content they see — a small
        // edit saves WITHOUT another conflict.
        try type("!", into: try #require(instructionsTextView(in: contentView)), in: window)
        try await settle()
        try press(labeled: "Save", in: window)
        try await settle()
        #expect(model.strategyConflict == nil, "adopting the winner re-authorizes saves")
        #expect(try #require(try model.internalStore.getWikiStrategy()).instructions == "their instructions!")
    }

    // MARK: - AC.4 templateCopiesWithoutLiveDependency

    @Test func templateCopiesWithoutLiveDependency() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        _ = Self.app
        let databaseURL = try tempDatabaseURL()
        defer { removeFixture(at: databaseURL.deletingLastPathComponent()) }
        let model = try makeModel(databaseURL: databaseURL)
        let window = try await host(
            WikiStrategyEditorView(store: model, wikiDisplayName: "Template Wiki"),
            model: model)
        defer { window.orderOut(nil) }

        // Blank draft: selecting a template copies immediately — no
        // confirmation, no save, no committed change.
        let revisionBefore = try model.internalStore.wikiStrategyRevision()
        try await chooseTemplate(.storyAnalysis, in: window)
        try await settle()
        let storyTemplate = WikiStrategyTemplates.template(for: .storyAnalysis)
        #expect(model.strategyDraftName == storyTemplate.name,
                "the real menu selection must copy the template name into the draft")
        #expect(model.strategyDraftInstructions == storyTemplate.markdown)
        #expect(model.isStrategyDraftDirty)
        #expect(try model.internalStore.getWikiStrategy() == nil, "template selection must not save")
        #expect(try model.internalStore.wikiStrategyRevision() == revisionBefore,
                "template selection must not advance the revision")

        // Nonblank draft: selecting another template asks for confirmation
        // with REAL buttons; Cancel keeps the draft, Replace performs it.
        try await chooseTemplate(.repositoryHistory, in: window)
        try await settle()
        #expect(twoButtonRowCount(in: window) == 1,
                "replacing a nonempty draft must show the confirmation row")
        try pressConfirmationButton(
            labeled: "Keep Current Draft",
            confirmation: ("Replace Draft", "Keep Current Draft"),
            in: window)
        try await settle()
        #expect(model.strategyDraftName == storyTemplate.name,
                "cancelling the replacement must keep the draft")
        try await chooseTemplate(.repositoryHistory, in: window)
        try await settle()
        #expect(twoButtonRowCount(in: window) == 1,
                "arming the replacement again must show the confirmation row")
        try pressConfirmationButton(
            labeled: "Replace Draft",
            confirmation: ("Replace Draft", "Keep Current Draft"),
            in: window)
        try await settle()
        let repoTemplate = WikiStrategyTemplates.template(for: .repositoryHistory)
        #expect(model.strategyDraftName == repoTemplate.name)
        #expect(model.strategyDraftInstructions == repoTemplate.markdown)

        // Not a live dependency: the draft holds a VALUE COPY. Saving pins
        // those bytes, and nothing re-reads the template constants.
        try await setName("Repo Notes", in: window, store: model)
        try await settle()
        try press(labeled: "Save", in: window)
        try await settle()
        let saved = try #require(try model.internalStore.getWikiStrategy())
        #expect(saved.instructions == repoTemplate.markdown)
        #expect(saved.name == "Repo Notes")
    }

    // MARK: - AC.4 saveDoesNotModifyPages

    @Test func saveDoesNotModifyPages() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        _ = Self.app
        let databaseURL = try tempDatabaseURL()
        defer { removeFixture(at: databaseURL.deletingLastPathComponent()) }
        let model = try makeModel(databaseURL: databaseURL)
        let window = try await host(
            WikiStrategyEditorView(store: model, wikiDisplayName: "Pages Wiki"),
            model: model)
        defer { window.orderOut(nil) }
        let contentView = try #require(window.contentView)

        // Seed one page, then save a strategy through the real controls.
        let page = try model.internalStore.createPage(title: "Stable Page")
        try await setName("Anything", in: window, store: model)
        try type("instructions", into: try #require(instructionsTextView(in: contentView)), in: window)
        try await settle()
        try press(labeled: "Save", in: window)
        try await settle()

        // The page, its body, and the activity log are unchanged; saving
        // enqueues nothing and rewrites nothing.
        let pages = try model.internalStore.listPages(sortBy: .lastUpdated)
        #expect(pages.count == 1)
        #expect(pages.first?.id == page.id)
        #expect(pages.first?.title == "Stable Page")
        let logEntries = try model.internalStore.recentLogEntries(limit: 100)
        #expect(logEntries.isEmpty, "a strategy save must not append activity-log entries")
    }

    // MARK: - Layout: the editor fills the window, the controls stay anchored

    /// Layout probe tuning (one owner, no magic numbers).
    private enum LayoutProbe {
        static let windowWidth: CGFloat = 720
        /// Near the boundary where the compact layout (scrolling headers)
        /// gives way to the roomy layout — either variant is legal here, so
        /// assertions at this height must hold under BOTH.
        static let compactHeight: CGFloat = 650
        /// Comfortably roomy (fixed headers + editor floor + footer fit with
        /// margin), so the growth check below compares two ROOMY layouts and
        /// is exact rather than spanning the variant switch.
        static let roomyHeight: CGFloat = 900
        static let tallHeight: CGFloat = 1050
        /// The controls row lives in a fixed-height footer: its bottom edge
        /// is never farther than this from the content view's bottom edge.
        static let footerBottomMaxDistance: CGFloat = 80
        /// The footer is fixed-height and outside the layout variants, so
        /// its bottom-edge distance must not shift across a window-height
        /// change (or a variant switch) beyond layout rounding.
        static let footerBottomStabilityTolerance: CGFloat = 4
        /// Between two roomy heights, headers and footer are fixed, so the
        /// editor box absorbs the window delta exactly up to rounding.
        static let growthTolerance: CGFloat = 12
    }

    /// One measurement of the mounted editor's real AppKit geometry, in
    /// window coordinates (origin at the content view's bottom-left corner).
    private struct EditorLayout {
        let contentHeight: CGFloat
        /// The height of the instructions editor's own scroll view — the
        /// box the user sees and scrolls inside.
        let editorHeight: CGFloat
        /// Bottom edge of that box (distance from the content bottom).
        let editorBottomDistance: CGFloat
        /// Top edge of the controls row, measured on the Save button.
        let controlsTopDistance: CGFloat
        /// Bottom edge of the controls row (distance from the content bottom).
        let controlsBottomDistance: CGFloat
    }

    /// Measured on the REAL mounted AppKit tree: the `NSScrollView` that
    /// hosts the instructions `NSTextView`, and the Save button's real
    /// rendered frame (either discovery layer, both report window space).
    private func measureEditorLayout(in window: NSWindow) throws -> EditorLayout {
        let content = try #require(window.contentView, "hosted content view")
        let textView = try #require(
            instructionsTextView(in: content),
            "the instructions NSTextView must be mounted")
        let editorBox = try #require(
            textView.enclosingScrollView,
            "the instructions editor must own its scroll view")
        let editorFrame = editorBox.convert(editorBox.bounds, to: nil)
        let saveFrame = try requireLabelFrame(labeled: "Save", in: window)
        return EditorLayout(
            contentHeight: content.bounds.height,
            editorHeight: editorFrame.height,
            editorBottomDistance: editorFrame.minY,
            controlsTopDistance: saveFrame.maxY,
            controlsBottomDistance: saveFrame.minY)
    }

    /// A real resize: `setContentSize`, then force AppKit layout and give
    /// SwiftUI's async update a moment to settle before measuring.
    private func resize(_ window: NSWindow, to size: NSSize) async throws {
        window.setContentSize(size)
        window.layoutIfNeeded()
        if let hosting = window.contentView {
            hosting.layoutSubtreeIfNeeded()
        }
        try await settle()
    }

    /// The layout contract the user asked for: the instructions textbox
    /// expands to fill the remaining window height (scrolling its own
    /// content), and the action buttons stay anchored at the bottom behind a
    /// divider. Asserted on the real mounted geometry at a compact height
    /// (650), after a real resize to a roomy height (900), and between two
    /// roomy heights (900 → 1050) where the editor must absorb the exact
    /// window delta.
    @Test func instructionsEditorFillsWindowAndControlsStayAnchored() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        _ = Self.app
        let databaseURL = try tempDatabaseURL()
        defer { removeFixture(at: databaseURL.deletingLastPathComponent()) }
        let model = try makeModel(databaseURL: databaseURL)
        let window = try await host(
            WikiStrategyEditorView(store: model, wikiDisplayName: "Layout Wiki"),
            model: model,
            size: NSSize(width: LayoutProbe.windowWidth, height: LayoutProbe.compactHeight))
        defer { window.orderOut(nil) }

        // Compact height: the editor keeps its minimum floor, and the
        // controls row sits in a bounded footer at the bottom of the window.
        let compact = try measureEditorLayout(in: window)
        #expect(compact.editorHeight >= WikiStrategyEditorMetrics.instructionsMinHeight,
                "the instructions editor must keep its minimum floor at a compact height (got \(compact.editorHeight))")
        #expect(compact.controlsBottomDistance <= LayoutProbe.footerBottomMaxDistance,
                "the controls row must stay anchored near the content bottom, not scroll away (got \(compact.controlsBottomDistance)pt above it)")
        #expect(compact.editorBottomDistance >= compact.controlsTopDistance,
                "the editor box must sit fully above the controls row")

        // A real resize to the roomy height: the footer stays anchored and
        // stable (it is outside the editor's layout, so a variant switch
        // between these heights must not move it).
        try await resize(
            window,
            to: NSSize(width: LayoutProbe.windowWidth, height: LayoutProbe.roomyHeight))
        let roomy = try measureEditorLayout(in: window)
        #expect(roomy.controlsBottomDistance <= LayoutProbe.footerBottomMaxDistance,
                "the controls row must stay anchored after growing the window (got \(roomy.controlsBottomDistance)pt above the content bottom)")
        #expect(abs(roomy.controlsBottomDistance - compact.controlsBottomDistance)
                    <= LayoutProbe.footerBottomStabilityTolerance,
                "the fixed-height footer must not shift across a window-height change (bottom edge moved \(abs(roomy.controlsBottomDistance - compact.controlsBottomDistance))pt)")
        #expect(roomy.editorBottomDistance >= roomy.controlsTopDistance,
                "the editor box must sit fully above the controls row after the resize")

        // Between two roomy heights the headers and footer are fixed, so the
        // editor box absorbs the window delta exactly.
        try await resize(
            window,
            to: NSSize(width: LayoutProbe.windowWidth, height: LayoutProbe.tallHeight))
        let tall = try measureEditorLayout(in: window)
        let heightGrowth = tall.contentHeight - roomy.contentHeight
        #expect(heightGrowth > 0, "the resize must have grown the content view")
        let editorGrowth = tall.editorHeight - roomy.editorHeight
        #expect(abs(editorGrowth - heightGrowth) <= LayoutProbe.growthTolerance,
                "the editor must absorb the window growth exactly (editor +\(editorGrowth), window +\(heightGrowth))")
        #expect(tall.controlsBottomDistance <= LayoutProbe.footerBottomMaxDistance,
                "the controls row must stay anchored at the tall height too")
    }

    // MARK: - Light and dark appearances

    /// The real controls render and stay drivable under both appearances.
    /// Semantic colors only (`primary`, `secondary`, accent, `.bar`) are
    /// used in these surfaces, so the assertion is label-based and
    /// structural: every authored control renders in BOTH appearances and a
    /// real Save press works in each.
    @Test func controlsRenderInBothAppearances() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        _ = Self.app
        for appearance in [NSAppearance(named: .aqua), NSAppearance(named: .darkAqua)] {
            let databaseURL = try tempDatabaseURL()
            defer { removeFixture(at: databaseURL.deletingLastPathComponent()) }
            let model = try makeModel(databaseURL: databaseURL)
            let window = try await host(
                WikiStrategyEditorView(store: model, wikiDisplayName: "Appearance Wiki"),
                model: model,
                appearance: appearance)
            defer { window.orderOut(nil) }
            let contentView = try #require(window.contentView)
            let appearanceName = String(describing: appearance?.name)
            #expect(findButton(labeled: "Save", in: window), "Save must exist under \(appearanceName)")
            #expect(findButton(labeled: "Cancel", in: window), "Cancel must exist under \(appearanceName)")
            #expect(findButton(labeled: "Reset to Default", in: window), "Reset must exist under \(appearanceName)")
            #expect(instructionsTextView(in: contentView) != nil)
            #expect(nameField(in: contentView) != nil)
            #expect(Self.pickerButtonLabels.contains { findButton(labeled: $0, in: window) },
                    "the template picker must render under \(appearanceName)")

            // A real end-to-end press under this appearance.
            try await setName("Dark Save", in: window, store: model)
            try type("x", into: try #require(instructionsTextView(in: contentView)), in: window)
            try await settle()
            try press(labeled: "Save", in: window)
            try await settle()
            #expect(try #require(try model.internalStore.getWikiStrategy()).name == "Dark Save")
        }
    }
}

// MARK: - Small string helpers

private extension String {
    /// Normalized form for matching authored labels against discovered
    /// labels: case- and whitespace-insensitive, one ellipsis spelling.
    var normalizedLabel: String {
        lowercased()
            .replacingOccurrences(of: "…", with: "...")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
#endif
