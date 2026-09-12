import Foundation
import SwiftUI
import WikiFSCore

// MARK: - Shared delete-confirmation flow (issue #219 hardening)
//
// One coordinator owns the decision both the pages and the sources containers
// make when the user deletes items: load the deletion impact (throwing — a
// failed read NEVER reads as "nothing references this"), then route to one of
// four typed states. The containers render only these states and invoke only
// the typed decisions this coordinator maps, so both surfaces stay in lockstep.

/// How the user chose to handle incoming links. The typed decision the
/// containers pass back to the model — never a raw Bool.
enum DeletionDecision: Equatable {
    /// Convert matching incoming links/embeds to plain display text.
    case unlink
    /// Keep incoming Markdown as ghost links (bookmarks still go).
    case preserve
}

/// The action set a confirmation dialog offers, in display order.
enum DeletionDialogAction: Hashable, CaseIterable {
    case unlinkAndDelete
    case delete
    case cancel
}

/// Presentation for the "what still references these items?" dialog.
struct DeletionDialogPresentation: Equatable {
    let title: String
    let message: String
    /// True when incoming links exist, so Unlink and Delete is offered.
    let offersUnlink: Bool

    /// The exact action set for this presentation, in display order.
    var actions: [DeletionDialogAction] {
        offersUnlink ? [.unlinkAndDelete, .delete, .cancel] : [.delete, .cancel]
    }
}

/// Presentation for the provenance-blocked state. The dialog stays a delete
/// confirmation, but instead of a dead end it names the blocking pages as
/// clickable entries the user can open to remove the reference.
struct DeletionBlockedPresentation: Equatable {
    let title: String
    /// The explanatory intro (why deletion is blocked).
    let intro: String
    /// The distinct blocking pages with resolved titles, in deterministic
    /// order — each renders as a clickable "Open …" action.
    let blockingPages: [DeletionLinkingPage]
}

/// Presentation for a failed impact read (or any deletion-surface error the
/// user must see before anything was touched).
struct DeletionFailurePresentation: Equatable {
    let title: String
    let message: String
}

/// The finite typed state of a delete confirmation (issue #219 hardening).
enum DeletionConfirmationOutcome: Equatable {
    /// Nothing references the selection and nothing blocks it — delete now,
    /// no dialog.
    case deleteImmediately
    /// Show the confirmation dialog with the given action set.
    case confirm(DeletionDialogPresentation)
    /// A provenance blocker forbids deletion; only OK is offered.
    case blocked(DeletionBlockedPresentation)
    /// The impact read failed (or the store rejected the request); show the
    /// store error and never invoke deletion.
    case failed(DeletionFailurePresentation)

    var dialogTitle: String {
        switch self {
        case .deleteImmediately: return ""
        case .confirm(let p): return p.title
        case .blocked(let p): return p.title
        case .failed(let p): return p.title
        }
    }

    var dialogMessage: String {
        switch self {
        case .deleteImmediately: return ""
        case .confirm(let p): return p.message
        case .blocked(let p): return p.intro
        case .failed(let p): return p.message
        }
    }

    /// True while a dialog surface should be on screen.
    var isDialogVisible: Bool {
        switch self {
        case .deleteImmediately: return false
        case .confirm, .blocked, .failed: return true
        }
    }

    /// The pages named by the blocked state, for the clickable "Open …"
    /// actions. Empty for every other state.
    var blockingPages: [DeletionLinkingPage] {
        if case .blocked(let p) = self { return p.blockingPages }
        return []
    }

    /// The destructive actions this outcome may invoke. Only `.confirm`
    /// exposes any — blocked and failed states can never route a deletion
    /// through a dialog action. (The blocked state's "Open …" actions are
    /// navigation, not deletion.)
    var availableActions: [DeletionDialogAction] {
        switch self {
        case .confirm(let p): return p.actions
        case .deleteImmediately, .blocked, .failed: return []
        }
    }
}

/// Which resource family a coordinator drives — carries the user-facing
/// wording so pages and sources stay grammatical without duplicated logic.
enum DeletionResourceKind {
    case page
    case source

    func dialogTitle(count: Int) -> String {
        switch self {
        case .page: return count == 1 ? "Delete Page?" : "Delete \(count) Pages?"
        case .source: return count == 1 ? "Delete Source?" : "Delete \(count) Sources?"
        }
    }

    var failureTitle: String {
        switch self {
        case .page: return "Couldn't Delete Page"
        case .source: return "Couldn't Delete Source"
        }
    }

    /// Title for the provenance-blocked dialog. Provenance blockers only
    /// exist for sources (a page version citing the source as evidence), so
    /// both kind branches use the same source wording; the count picks the
    /// plural.
    func blockedTitle(blockedSourceCount: Int) -> String {
        blockedSourceCount == 1 ? "Source Is In Use" : "Sources Are In Use"
    }

    func failureMessage(for error: Error) -> String {
        switch self {
        case .page: return "Could not check the page: \(error.localizedDescription)"
        case .source: return "Could not check the source: \(error.localizedDescription)"
        }
    }
}

/// Shared, testable delete-confirmation coordinator. A value type: the
/// container constructs one per deletion request with an impact loader and a
/// delete callback, evaluates it once, and renders the outcome. Tests drive
/// `evaluate()` and `perform(_:)` directly with stub loaders and record
/// whether deletion was invoked.
struct DeletionConfirmationCoordinator {
    let kind: DeletionResourceKind
    /// Loads one impact per selected id. Throwing — a failed load routes to
    /// `.failed` and can never reach `onDelete`.
    let loadImpacts: () throws -> [DeletionImpact]
    /// The typed decision sink — called ONLY for `.deleteImmediately` and
    /// `perform(.unlinkAndDelete / .delete)`. Never for blocked, failed, or
    /// canceled flows.
    let onDelete: (DeletionDecision) -> Void
    /// Optional live-title resolver for provenance-blocking pages (they are
    /// not necessarily linking pages, so the impact may not carry their
    /// titles). Containers pass a summaries lookup; tests may pass nil.
    var pageTitle: ((PageID) -> String?)? = nil
    /// Number of selected items — for the dialog title's pluralization.
    let selectionCount: Int

    /// Evaluate the current references and produce the typed state.
    func evaluate() -> DeletionConfirmationOutcome {
        let impact: DeletionImpact
        do {
            impact = DeletionImpact.aggregated(try loadImpacts())
        } catch {
            // An impact-read failure must never read as "no references"
            // (AC.10): produce the failed state; deletion stays unreachable.
            return .failed(DeletionFailurePresentation(
                title: kind.failureTitle,
                message: kind.failureMessage(for: error)))
        }
        if impact.isProvenanceBlocked {
            return .blocked(blockedPresentation(for: impact))
        }
        guard impact.hasReferences else { return .deleteImmediately }
        return .confirm(confirmPresentation(for: impact))
    }

    /// Map a dialog action to the typed decision and invoke deletion. Cancel
    /// invokes nothing.
    func perform(_ action: DeletionDialogAction) {
        switch action {
        case .unlinkAndDelete: onDelete(.unlink)
        case .delete: onDelete(.preserve)
        case .cancel: break
        }
    }

    // MARK: - Presentation builders

    private func confirmPresentation(for impact: DeletionImpact) -> DeletionDialogPresentation {
        var lines: [String] = []
        switch kind {
        case .page:
            if !impact.linkingPages.isEmpty {
                let names = impact.linkingPages.compactMap(\.title).joined(separator: ", ")
                let noun = impact.linkingPages.count == 1 ? "page" : "pages"
                lines.append("Linked from \(impact.linkingPages.count) \(noun): \(names).")
            }
        case .source:
            if !impact.linkingPages.isEmpty {
                let names = impact.linkingPages.compactMap(\.title).joined(separator: ", ")
                let noun = impact.linkingPages.count == 1 ? "page" : "pages"
                lines.append("Cited by \(impact.linkingPages.count) \(noun): \(names).")
            }
        }
        if !impact.bookmarks.isEmpty {
            let noun = impact.bookmarks.count == 1 ? "bookmark" : "bookmarks"
            let paths = Set(impact.bookmarks.map(\.folderPath)).sorted().joined(separator: ", ")
            lines.append("\(impact.bookmarks.count) \(noun) point to this and will be removed (\(paths)).")
        }
        if !impact.linkingPages.isEmpty {
            let noun = kind == .page ? "links" : "citations"
            lines.append("Unlink and Delete converts the \(noun) to plain text.")
        }
        return DeletionDialogPresentation(
            title: kind.dialogTitle(count: selectionCount),
            message: lines.joined(separator: "\n"),
            offersUnlink: !impact.linkingPages.isEmpty)
    }

    private func blockedPresentation(for impact: DeletionImpact) -> DeletionBlockedPresentation {
        // Distinct blocking sources set the plural; distinct blocking pages
        // become the clickable entries (titled only — an untitled row cannot
        // be opened).
        let sourceCount = Set(impact.provenanceBlockers.map(\.sourceID)).count
        var seen = Set<PageID>()
        var pages: [DeletionLinkingPage] = []
        for blocker in impact.provenanceBlockers where seen.insert(blocker.pageID).inserted {
            let title = pageTitle?(blocker.pageID)
                ?? impact.linkingPages.first { $0.pageID == blocker.pageID }?.title
            if let title {
                pages.append(DeletionLinkingPage(pageID: blocker.pageID, title: title))
            }
        }
        return DeletionBlockedPresentation(
            title: kind.blockedTitle(blockedSourceCount: sourceCount),
            intro: "This source is referenced as evidence by page versions. "
                + "Remove those references before deleting:",
            blockingPages: pages)
    }
}

// MARK: - Impact aggregation (batch semantics)

extension DeletionImpact {
    /// Merge the per-id impacts of a batch deletion into one: distinct
    /// linking pages (first title wins), distinct bookmark nodes, all
    /// provenance blockers deduplicated, and summed incoming-link edge
    /// counts. Deterministic — every list keeps its raw-ULID order.
    static func aggregated(_ impacts: [DeletionImpact]) -> DeletionImpact {
        guard impacts.count > 1 else { return impacts.first ?? DeletionImpact(
            linkingPages: [], bookmarks: [], provenanceBlockers: [], incomingLinkCount: 0) }

        var linkingByID: [PageID: DeletionLinkingPage] = [:]
        var bookmarksByID: [BookmarkID: DeletionBookmarkImpact] = [:]
        var blockers = Set<ProvenanceDeletionBlocker>()
        var incomingLinkCount = 0
        for impact in impacts {
            for page in impact.linkingPages where linkingByID[page.pageID] == nil {
                linkingByID[page.pageID] = page
            }
            for bookmark in impact.bookmarks where bookmarksByID[bookmark.nodeID] == nil {
                bookmarksByID[bookmark.nodeID] = bookmark
            }
            blockers.formUnion(impact.provenanceBlockers)
            incomingLinkCount += impact.incomingLinkCount
        }
        return DeletionImpact(
            linkingPages: linkingByID.values.sorted { $0.pageID.rawValue < $1.pageID.rawValue },
            bookmarks: bookmarksByID.values.sorted { $0.nodeID.rawValue < $1.nodeID.rawValue },
            provenanceBlockers: blockers.sorted { a, b in
                if a.pageID.rawValue != b.pageID.rawValue { return a.pageID.rawValue < b.pageID.rawValue }
                if a.pageVersionID.rawValue != b.pageVersionID.rawValue {
                    return a.pageVersionID.rawValue < b.pageVersionID.rawValue
                }
                return a.sourceID.rawValue < b.sourceID.rawValue
            },
            incomingLinkCount: incomingLinkCount)
    }
}

// MARK: - Shared dialog surface (both containers)

/// Renders the coordinator's outcome as the one confirmationDialog both the
/// pages and the sources containers show. Each outcome surfaces exactly its
/// own action set: confirm → the presentation's actions, blocked → the
/// blocking pages as clickable "Open …" actions plus Cancel, failed → OK
/// only, immediate → nothing (the caller deletes without a dialog).
struct DeletionOutcomeDialog: ViewModifier {
    @Binding var outcome: DeletionConfirmationOutcome?
    let onAction: (DeletionDialogAction) -> Void
    /// Opens one of the blocked state's blocking pages (the containers route
    /// this to a page tab). Nil where blockers cannot occur (pages).
    var onOpenPage: ((PageID) -> Void)? = nil

    func body(content: Content) -> some View {
        content.confirmationDialog(
            outcome?.dialogTitle ?? "",
            isPresented: Binding(
                get: { outcome?.isDialogVisible ?? false },
                set: { if !$0 { outcome = nil } }
            ),
            titleVisibility: (outcome?.dialogTitle.isEmpty == false) ? .visible : .automatic
        ) {
            dialogActions
        } message: {
            if let message = outcome?.dialogMessage, !message.isEmpty {
                Text(message)
            }
        }
    }

    @ViewBuilder
    private var dialogActions: some View {
        switch outcome {
        case .confirm(let presentation):
            ForEach(presentation.actions, id: \.self) { action in
                actionButton(action)
            }
        case .blocked(let presentation):
            // The blocking pages as clickable entries: opening one dismisses
            // the dialog so the user can remove the reference, then retry.
            ForEach(presentation.blockingPages, id: \.pageID) { page in
                Button("Open “\(page.title ?? page.pageID.rawValue)”") {
                    onOpenPage?(page.pageID)
                    outcome = nil
                }
            }
            Button("Cancel", role: .cancel) { outcome = nil }
        case .failed:
            Button("OK", role: .cancel) { outcome = nil }
        case .deleteImmediately, .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private func actionButton(_ action: DeletionDialogAction) -> some View {
        switch action {
        case .unlinkAndDelete:
            Button("Unlink and Delete", role: .destructive) { fire(action) }
        case .delete:
            Button("Delete", role: .destructive) { fire(action) }
        case .cancel:
            Button("Cancel", role: .cancel) { fire(action) }
        }
    }

    private func fire(_ action: DeletionDialogAction) {
        onAction(action)
        outcome = nil
    }
}

extension View {
    /// Attach the shared delete-confirmation surface driven by the
    /// `DeletionConfirmationCoordinator` outcome. `onOpenPage` handles the
    /// blocked state's clickable blocking pages (pass nil where blockers
    /// cannot occur).
    func deletionOutcomeDialog(
        _ outcome: Binding<DeletionConfirmationOutcome?>,
        onAction: @escaping (DeletionDialogAction) -> Void,
        onOpenPage: ((PageID) -> Void)? = nil
    ) -> some View {
        modifier(DeletionOutcomeDialog(
            outcome: outcome, onAction: onAction, onOpenPage: onOpenPage))
    }
}
