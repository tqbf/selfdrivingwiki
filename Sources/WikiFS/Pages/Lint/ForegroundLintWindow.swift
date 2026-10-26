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
    /// Raised when a close attempt (red button, Cmd+W, Close button) was
    /// vetoed because a run is busy — the confirmation alert presents from
    /// here, never from inside `windowShouldClose`.
    @State private var showCloseConfirmation = false

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
                        requestClose()
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
        .background(
            WindowCloseInterceptor(
                isBusy: { lintSession?.isBusy == true },
                onCloseAttempt: { showCloseConfirmation = true })
        )
        .alert(
            "Lint work in progress",
            isPresented: $showCloseConfirmation
        ) {
            Button("Close and Cancel", role: .destructive) {
                lintCoordinator.close(wikiID: context.wikiID)
                dismiss()
            }
            Button("Keep Window", role: .cancel) {}
        } message: {
            Text("A check or repair is still running. Close the window and cancel it?")
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

    /// The sheet's Close button takes the same veto path as the red button
    /// and Cmd+W: while busy, raise the confirmation alert instead of
    /// closing; while idle, close immediately.
    private func requestClose() {
        if lintSession?.isBusy == true {
            showCloseConfirmation = true
            return
        }
        lintCoordinator.close(wikiID: context.wikiID)
        dismiss()
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

/// Intercepts the lint window's close (red close button AND Cmd+W — both
/// route through `performClose:`) while a run is busy, VETOES the close,
/// and hands the decision to a SwiftUI confirmation alert owned by the
/// window content.
///
/// Mechanism: installs a delegate proxy on the hosting NSWindow. While busy
/// it answers `windowShouldClose(_:)` with `false` (refusing the close) and
/// fires `onCloseAttempt`, which raises the alert; the alert's Confirm path
/// tears down the run and dismisses the scene. When idle, the proxy
/// forwards `windowShouldClose` to SwiftUI's original delegate so scene
/// behavior is unchanged. No nested modal loop runs inside
/// `windowShouldClose` — `NSAlert.runModal` there hangs or gets swallowed
/// by SwiftUI's close pipeline.
struct WindowCloseInterceptor: NSViewRepresentable {
    /// `true` while a run is busy — closing is vetoed and the confirmation
    /// alert is requested.
    var isBusy: () -> Bool
    /// Called on the main thread when a busy close attempt was vetoed.
    var onCloseAttempt: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = InterceptorView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.isBusy = isBusy
        context.coordinator.onCloseAttempt = onCloseAttempt
        // SwiftUI may install/replace its own delegate after we attach; make
        // sure ours stays the one answering close attempts.
        context.coordinator.reassert(on: view.window)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// MainActor: the delegate calls arrive on the main thread (AppKit
    /// dispatches window-delegate calls there) and the callbacks read the
    /// session's MainActor-isolated state.
    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        var isBusy: () -> Bool = { false }
        var onCloseAttempt: () -> Void = {}
        /// SwiftUI's own window delegate — when idle, close decisions
        /// forward here so scene behavior is unchanged. `nonisolated(unsafe)`
        /// is required because the NSObject forwarding overrides are
        /// nonisolated while the state is MainActor; it is sound because
        /// the property is only ever touched on the main thread (attach in
        /// `viewDidMoveToWindow`/`reassert`, and AppKit dispatches
        /// window-delegate calls on the main thread).
        // swiftlint:disable:next nonisolated_unsafe
        nonisolated(unsafe) weak var originalDelegate: NSWindowDelegate?

        /// Install the proxy once per window; never clobber the saved
        /// original with ourselves (a second attach must be a no-op, or the
        /// forwarding chain would recurse into the proxy).
        func attach(to window: NSWindow) {
            guard window.delegate !== self else { return }
            originalDelegate = window.delegate
            window.delegate = self
        }

        /// Re-install after SwiftUI may have replaced the delegate.
        func reassert(on window: NSWindow?) {
            guard let window, window.delegate !== self else { return }
            attach(to: window)
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if isBusy() {
                onCloseAttempt()
                return false
            }
            if let originalDelegate,
               originalDelegate.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))) {
                return originalDelegate.windowShouldClose?(sender) ?? true
            }
            return true
        }

        override func responds(to aSelector: Selector) -> Bool {
            super.responds(to: aSelector) || originalDelegate?.responds(to: aSelector) == true
        }

        override func forwardingTarget(for aSelector: Selector) -> Any? {
            originalDelegate
        }
    }

    /// Grabs the hosting window the moment the view enters one.
    final class InterceptorView: NSView {
        var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let coordinator else { return }
            coordinator.attach(to: window)
        }
    }
}
