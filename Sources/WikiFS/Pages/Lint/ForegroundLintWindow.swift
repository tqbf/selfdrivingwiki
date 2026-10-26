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
                        lintCoordinator.close(wikiID: context.wikiID)
                        dismiss()
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
