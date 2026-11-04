import SwiftUI
import WikiFSEngine
import WikiFSCore
import WikiFSTypes

// MARK: - Window context

/// Identifies which page to lint. Value-driven `WindowGroup(for:)` identity:
/// `==` is based on pageID + wikiID together (mirroring
/// `PageVersionCompareContext`), so `openWindow(value:)` re-opening the same
/// page in the same wiki FOCUSES the existing window instead of duplicating.
/// The lint review is a real, resizable, NON-modal window — the same idiom as
/// Compare Versions — not a sheet blocking the page.
struct LintWindowContext: Codable, Hashable {
    let pageID: PageID
    let title: String
    let wikiID: WikiID

    static func == (lhs: LintWindowContext, rhs: LintWindowContext) -> Bool {
        lhs.pageID == rhs.pageID && lhs.wikiID == rhs.wikiID
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(pageID)
        hasher.combine(wikiID)
    }
}

// MARK: - Window root

/// Resolves the owning wiki's session for the lint window via the shared
/// `SessionManager` (mirrors `PageVersionCompareWindow`). If the session is
/// no longer alive, shows an empty state.
struct LintWindowRoot: View {
    let sessionManager: SessionManager
    let context: LintWindowContext?

    var body: some View {
        if let context,
           let session = sessionManager.sessions[context.wikiID] {
            ForegroundLintWindow(session: session, context: context)
        } else {
            ContentUnavailableView {
                Label("No Page to Lint", systemImage: "checkmark.seal")
            } description: {
                Text("Open a wiki and page, then choose Lint.")
            }
            .frame(minWidth: 480, minHeight: 320)
        }
    }
}

// MARK: - Window content

/// The lint review window's content: opens (or focuses) the coordinator's
/// run for the context's page ONCE per window, then hosts the review sheet
/// non-modally. Closing the window cancels in-flight work and discards
/// uncommitted proposals.
struct ForegroundLintWindow: View {
    let session: any WikiSessionProtocol
    let context: LintWindowContext

    @Environment(ForegroundLintCoordinator.self) private var lintCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var lintSession: ForegroundLintSession?
    @State private var refusal: String?
    @State private var started = false
    /// The window's close confirmation delegate (real `NSWindowDelegate`).
    @State private var closeDelegate = LintWindowCloseDelegate()

    var body: some View {
        Group {
            if let lintSession {
                ForegroundLintSheet(
                    session: lintSession,
                    pageTitle: context.title,
                    onApply: { proposal, candidate in
                        applyLintProposal(proposal, candidate)
                    },
                    onClose: {
                        closeDelegate.requestClose()
                    })
            } else if let refusal {
                ContentUnavailableView {
                    Label("Lint Unavailable", systemImage: "xmark.octagon")
                } description: {
                    Text(refusal)
                }
                .frame(minWidth: 480, minHeight: 320)
            } else {
                ProgressView("Preparing lint…")
                    .frame(minWidth: 480, minHeight: 320)
            }
        }
        .frame(minWidth: 720, minHeight: 500)
        .background(WindowActivator())
        .background(WindowCloseConfirmation(delegate: closeDelegate))
        .onAppear {
            // The delegate's closures read live state; set them once —
            // @State reads inside the closures stay current.
            closeDelegate.isBusy = { lintSession?.isBusy == true }
            closeDelegate.onConfirmedClose = {
                lintCoordinator.close(wikiID: context.wikiID)
                dismiss()
            }
        }
        .task(id: context) {
            await openOnce()
        }
        .onDisappear {
            // Window closed by any means: cancel in-flight work, discard
            // proposals, and free the per-wiki run slot.
            lintCoordinator.close(wikiID: context.wikiID)
        }
    }

    /// Idempotent open+start. Reopening the same page's window focuses
    /// without restarting; a second page is refused while a run is active.
    private func openOnce() async {
        guard !started else { return }
        started = true
        if lintCoordinator.isActive(pageID: context.pageID, wikiID: context.wikiID),
           let active = lintCoordinator.activeSession(for: context.wikiID) {
            lintSession = active
            return
        }
        guard let active = lintCoordinator.open(
            pageID: context.pageID,
            wikiID: context.wikiID,
            store: session.store,
            configDirectory: ForegroundLintCoordinator.resolvedConfigDirectory()) else {
            refusal = "A lint run is already active for this wiki. Close it before linting another page."
            return
        }
        let strategy = session.store.lintStrategyContext
        active.start(
            pageID: context.pageID,
            strategyRevision: strategy.revision,
            strategyContext: strategy.rendered)
        lintSession = active
    }

    /// The exact Apply handoff: the composed write with the previewed
    /// candidate pinned. Every refusal path writes nothing.
    private func applyLintProposal(
        _ proposal: LintRepairProposal, _ candidate: String
    ) -> LintApplyOutcome {
        guard let snapshot = lintSession?.snapshot else {
            return .refused("The lint run has no captured snapshot — rerun lint.")
        }
        guard !session.store.hasDirtyDraft else {
            return .stale("This page has unsaved edits. Save or Cancel editing, then rerun lint. Nothing was written.")
        }
        do {
            let versionID = try session.store.lintApply(
                pageID: proposal.pageID,
                title: snapshot.title,
                canonicalCandidate: candidate,
                expectedHead: snapshot.headVersionID)
            return .committed(versionID)
        } catch WikiStoreModel.LintApplyRefused.dirtyDraft {
            return .stale("This page has unsaved edits. Nothing was written.")
        } catch is PageCanonicalizationConflictError {
            return .refused("The page's links changed since the preview — rerun lint and preview again. Nothing was written.")
        } catch is PageExpectedTargetMissingError {
            return .stale("The page was deleted or renamed since the lint run. Nothing was written.")
        } catch is PageConflictError {
            return .stale("The page changed since the lint run. Rerun lint. Nothing was written.")
        } catch {
            DebugLog.lint("Lint Apply failed: \(error)")
            return .refused("Apply failed: \(error)")
        }
    }
}

// MARK: - Close confirmation

/// The lint window's close confirmation, implemented as a real
/// `NSWindowDelegate` (the standard AppKit confirm-close pattern).
///
/// While a run is busy, `windowShouldClose(_:)` vetoes the close and
/// presents the confirmation as an ASYNC SHEET on the window
/// (`beginSheetModal(for:)` — never `runModal`, whose nested loop inside
/// `performClose:` hangs SwiftUI's close pipeline). Confirming tears down
/// the run and closes via `onConfirmedClose`. When idle, close decisions
/// forward to SwiftUI's original delegate unchanged. Every other delegate
/// call forwards too, so scene behavior is otherwise untouched.
@MainActor
final class LintWindowCloseDelegate: NSObject, NSWindowDelegate {
    var isBusy: () -> Bool = { false }
    /// Runs after the user confirms the busy close: tears down the run and
    /// dismisses the window (wired to the content's coordinator + dismiss).
    var onConfirmedClose: () -> Void = {}
    /// The window the delegate is attached to (set by `attach`/`reassert`),
    /// so the Close button can present the confirmation sheet on it.
    private weak var attachedWindow: NSWindow?
    /// SwiftUI's own window delegate — idle close decisions and all
    /// non-intercepted delegate calls forward here. `nonisolated(unsafe)`
    /// because the NSObject forwarding overrides are nonisolated while the
    /// state is MainActor; sound because the property and its readers only
    /// ever run on the main thread (attach in `viewDidMoveToWindow`/
    /// `reassert`, and AppKit dispatches window-delegate calls on main).
    // swiftlint:disable:next nonisolated_unsafe
    nonisolated(unsafe) weak var originalDelegate: (any NSWindowDelegate)?
    /// Guards against stacking confirmation sheets on repeated close
    /// attempts while one is already on screen.
    private var isConfirming = false

    /// Install as the window's delegate, saving whatever was there. A
    /// second attach with ourselves installed is a no-op (re-saving would
    /// make the forwarding chain recurse into the proxy).
    func attach(to window: NSWindow) {
        attachedWindow = window
        guard window.delegate !== self else { return }
        originalDelegate = window.delegate
        window.delegate = self
    }

    /// Re-install if SwiftUI replaced the delegate after our attach.
    func reassert(on window: NSWindow?) {
        guard let window else { return }
        attach(to: window)
    }

    /// The single close entry point, shared by the red close button
    /// (via `windowShouldClose`), Cmd+W, and the in-window Close button:
    /// busy → present the confirmation sheet on the window; idle → run the
    /// confirmed-close path immediately.
    func requestClose() {
        if isBusy(), let attachedWindow {
            requestConfirmation(window: attachedWindow)
            return
        }
        onConfirmedClose()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isBusy() {
            requestConfirmation(window: sender)
            return false
        }
        if let originalDelegate,
           originalDelegate.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))) {
            return originalDelegate.windowShouldClose?(sender) ?? true
        }
        return true
    }

    private func requestConfirmation(window: NSWindow) {
        guard !isConfirming else { return }
        isConfirming = true
        let alert = NSAlert()
        alert.messageText = "Lint work in progress"
        alert.informativeText = "A check or repair is still running. Close the window and cancel it?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close and Cancel")
        alert.addButton(withTitle: "Keep Window")
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.isConfirming = false
            if response == .alertFirstButtonReturn {
                self?.onConfirmedClose()
            }
        }
    }

    override func responds(to aSelector: Selector) -> Bool {
        super.responds(to: aSelector) || originalDelegate?.responds(to: aSelector) == true
    }

    override func forwardingTarget(for aSelector: Selector) -> Any? {
        originalDelegate
    }
}

/// Bridges the window content to its `LintWindowCloseDelegate`: installs
/// the delegate when the view joins the window and refreshes the closures
/// on every update. The delegate itself is owned by the content (`@State`)
/// so the Close button routes through the same confirmation.
struct WindowCloseConfirmation: NSViewRepresentable {
    let delegate: LintWindowCloseDelegate

    func makeNSView(context: Context) -> NSView {
        let view = ConfirmationView()
        view.closeDelegate = delegate
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let view = view as? ConfirmationView else { return }
        view.closeDelegate = delegate
        delegate.reassert(on: view.window)
    }

    /// Grabs the hosting window the moment the view enters one.
    @MainActor
    final class ConfirmationView: NSView {
        weak var closeDelegate: LintWindowCloseDelegate?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let closeDelegate else { return }
            closeDelegate.attach(to: window)
        }
    }
}

// MARK: - Foreground on appear

/// Raises and keys the hosting window the moment the lint content attaches.
/// `openWindow(value:)` creates the window but does not reliably raise it —
/// without this, the review opens behind the main window and the only trace
/// is the Window menu entry. One activation per window attach.
struct WindowActivator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ActivatorView() }
    func updateNSView(_ view: NSView, context: Context) {}

    /// MainActor: AppKit window ordering is main-thread only.
    @MainActor
    final class ActivatorView: NSView {
        private var didActivate = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !didActivate else { return }
            didActivate = true
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

