import SwiftUI
import WikiFSCore

/// The wiki-scoped Strategy editor: the saved strategy (or Default), a local
/// draft with explicit Save / Cancel, Reset to Default with confirmation, a
/// starter-template picker, and conflict handling that keeps the draft and
/// offers Reload.
///
/// Scope, from the plan and the user guide (`docs/user-guide/wiki-strategy.md`):
/// - Changes apply to future runs. Saving never reorganizes existing pages
///   and never enqueues ingestion.
/// - The draft lives on ``WikiStoreModel`` (the §3.5 draft pattern), so
///   moving to another tab and back loses nothing; the tab-close and
///   in-place wiki-switch confirms protect the draft at the boundaries where
///   it would actually be destroyed.
/// - Templates copy text into the draft. They are not live dependencies.
struct WikiStrategyEditorView: View {
    @Bindable var store: WikiStoreModel
    /// The active wiki's display name — the editor is wiki-scoped, so the
    /// identity of the wiki being edited stays visible in the surface.
    let wikiDisplayName: String

    /// The in-surface confirmation awaiting a decision, if any.
    @State private var pendingAction: WikiStrategyEditorPendingAction?

    var body: some View {
        Group {
            if store.strategyLoadFailed {
                loadFailed
            } else if store.strategyDidLoad {
                editorForm
            } else {
                ProgressView("Loading strategy…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .navigationTitle("Strategy")
        .task {
            store.loadWikiStrategy()
            // A remounted editor (the draft persists on the model after the
            // tab was closed and reopened) sees no dirtiness TRANSITION, so
            // the marker below would never sync. Sync once at mount; the
            // onChange keeps it live afterwards.
            syncStrategyTabEditingMarker()
        }
        .onChange(of: store.strategyConflict == nil) { _, conflictCleared in
            // A resolved conflict invalidates a pending Reload confirmation.
            if conflictCleared, pendingAction == .reloadFromWiki {
                pendingAction = nil
            }
        }
        // Keep the STRATEGY tab's edit marker in sync with draft dirtiness so
        // the existing close-while-editing confirmation (pendingCloseTabID)
        // protects this draft exactly like a page draft. The tab is found by
        // SELECTION, not `activeTab`: a draft change that settles after the
        // user navigated elsewhere must never flag the tab they switched to.
        // At most one strategy tab exists (openTab dedups singletons).
        // Deliberately NOT cleared on disappear: the marker must survive
        // navigation away.
        .onChange(of: store.isStrategyDraftDirty) { _, _ in
            syncStrategyTabEditingMarker()
        }
    }

    /// Keep the STRATEGY tab's edit marker in sync with draft dirtiness so
    /// the existing close-while-editing confirmation (pendingCloseTabID)
    /// protects this draft exactly like a page draft. The tab is found by
    /// SELECTION, not `activeTab`: a draft change that settles after the
    /// user navigated elsewhere must never flag the tab they switched to.
    /// At most one strategy tab exists (openTab dedups singletons).
    /// Deliberately NOT cleared on disappear: the marker must survive
    /// navigation away.
    private func syncStrategyTabEditingMarker() {
        guard let tabID = store.tabs.first(where: { tab in
            if case .strategy = tab.selection { return true }
            return false
        })?.id else { return }
        store.setTabEditing(tabID: tabID, isEditing: store.isStrategyDraftDirty)
    }

    /// A failed read is never an endless spinner: state the failure and offer
    /// a retry. The store error sheet has already shown the underlying error.
    private var loadFailed: some View {
        ContentUnavailableView {
            Label("Strategy Unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text("The saved strategy could not be read from this wiki.")
        } actions: {
            Button("Try Again") { store.loadWikiStrategy() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Form

    /// The form fills the window instead of scrolling as one page: headers,
    /// banners, and the name field sit above a monospaced instructions
    /// editor that takes ALL remaining height (long drafts scroll inside the
    /// editor's own scroll view), and the controls row is a bottom-anchored
    /// footer separated by a native divider.
    ///
    /// Compact windows must not crowd the editor: `ViewThatFits` prefers the
    /// fixed-header layout, and when the headers cannot fit beside the
    /// editor's minimum floor (the fit test measures the editor's pinned
    /// IDEAL — see ``instructionsField(flexible:)``) it falls back to
    /// scrolling the headers while the editor keeps its floor and the footer
    /// stays anchored. (No `layoutPriority` here — a greedy frame beside a
    /// prioritized sibling can reduce the space available to the other
    /// controls.)
    private var editorForm: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .vertical) {
                VStack(spacing: 0) {
                    headerFields
                    instructionsField(flexible: true)
                }
                VStack(spacing: 0) {
                    ScrollView {
                        headerFields
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    instructionsField(flexible: false)
                }
            }
            Divider()
            controlsRow
                .padding(EdgeInsets(
                    top: WikiStrategyEditorMetrics.footerVerticalPadding,
                    leading: WikiStrategyEditorMetrics.contentPadding,
                    bottom: WikiStrategyEditorMetrics.footerVerticalPadding,
                    trailing: WikiStrategyEditorMetrics.contentPadding))
                .frame(maxWidth: WikiStrategyEditorMetrics.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Everything above the instructions editor: header, status line, scope
    /// note, conflict banner, pending confirmation, and the name field.
    private var headerFields: some View {
        VStack(alignment: .leading, spacing: WikiStrategyEditorMetrics.sectionSpacing) {
            header
            statusLine
            explainer

            if store.strategyConflict != nil && !store.isStrategyConflictDismissed {
                conflictBanner
            }
            if let pendingAction {
                WikiStrategyInlineConfirmation(
                    message: pendingAction.message,
                    confirmTitle: pendingAction.confirmTitle,
                    cancelTitle: WikiStrategyEditorPendingAction.cancelTitle,
                    onConfirm: { perform(pendingAction) },
                    onCancel: { self.pendingAction = nil })
            }

            nameField
        }
        .padding(EdgeInsets(
            top: WikiStrategyEditorMetrics.contentPadding,
            leading: WikiStrategyEditorMetrics.contentPadding,
            bottom: WikiStrategyEditorMetrics.sectionSpacing,
            trailing: WikiStrategyEditorMetrics.contentPadding))
        .frame(maxWidth: WikiStrategyEditorMetrics.contentMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: WikiStrategyEditorMetrics.labelSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Strategy")
                    .font(.title2)
                    .fontWeight(.semibold)
                if store.isStrategyDraftDirty {
                    Text("Edited")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, WikiStrategyEditorMetrics.editedCapsuleHorizontalPadding)
                        .padding(.vertical, WikiStrategyEditorMetrics.editedCapsuleVerticalPadding)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        .accessibilityLabel("Strategy has unsaved changes")
                }
            }
            // Wiki-scoped surface: name the wiki this strategy belongs to.
            Text("Editorial instructions for the wiki “\(wikiDisplayName)”.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Image(systemName: store.committedStrategy == nil ? "circle.dashed" : "checkmark.seal")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if let committed = store.committedStrategy {
                Text("Current: \(committed.name) — revision \(committed.revision.rawValue)")
            } else {
                Text("Current: Default strategy")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    /// The fixed scope note (user guide wording): what a save does and does
    /// not do.
    private var explainer: some View {
        Text("Changes apply to future runs. Saving does not reorganize existing pages. Normal ingestion can still update existing pages.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Conflict state: the draft is preserved untouched. Reload adopts the
    /// committed winner (with confirmation); Keep Draft dismisses the banner
    /// but keeps the STALE compare-and-swap expectation, so saving again
    /// conflicts again — keeping a draft never overwrites unseen work.
    private var conflictBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("This wiki's strategy changed elsewhere.")
                    .font(.callout.weight(.semibold))
                Text("Your draft is kept. Reload to replace it with the saved version, or keep the draft and save again to be asked again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Reload From Wiki") {
                        pendingAction = .reloadFromWiki
                    }
                    Button("Keep Draft", role: .cancel) {
                        store.dismissStrategyConflict()
                    }
                }
            }
        }
        .padding(WikiStrategyEditorMetrics.calloutPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: WikiStrategyEditorMetrics.cornerRadius)
                .fill(Color.secondary.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: WikiStrategyEditorMetrics.cornerRadius)
                .strokeBorder(Color.secondary.opacity(0.35))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Strategy conflict")
    }

    // MARK: - Fields

    private var nameField: some View {
        VStack(alignment: .leading, spacing: WikiStrategyEditorMetrics.labelSpacing) {
            Text("Display Name")
                .font(.headline)
            TextField("Display name", text: $store.strategyDraftName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Strategy display name")
            if store.strategyDraftName.count > WikiStrategyEditorMetrics.nameCountHintThreshold {
                Text("\(store.strategyDraftName.count) of \(WikiStrategy.nameCharacterLimit) characters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The instructions editor and its caption row. `TextEditor` owns its
    /// scroll view, so long drafts scroll inside the box. Height flexibility
    /// is the CALLER's choice: `flexible: true` grows to fill all offered
    /// height (the roomy layout); `flexible: false` pins the box at its
    /// minimum floor so the compact layout's scrolling headers take every
    /// leftover point instead of splitting it with a greedy sibling.
    ///
    /// Use the minimum editor height as its ideal height for `ViewThatFits`.
    /// Otherwise, a long draft can select the compact layout even when the
    /// headers and minimum editor height fit. The header scroll view then
    /// uses extra height as a gap instead of letting the editor grow.
    private func instructionsField(flexible: Bool) -> some View {
        VStack(alignment: .leading, spacing: WikiStrategyEditorMetrics.labelSpacing) {
            HStack {
                Text("Instructions")
                    .font(.headline)
                Spacer()
                Text(instructionSizeCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Strategy instruction size")
            }
            TextEditor(text: $store.strategyDraftInstructions)
                .font(.system(.body, design: .monospaced))
                .frame(
                    minHeight: WikiStrategyEditorMetrics.instructionsMinHeight,
                    idealHeight: WikiStrategyEditorMetrics.instructionsMinHeight,
                    maxHeight: flexible ? .infinity : WikiStrategyEditorMetrics.instructionsMinHeight,
                    alignment: .topLeading)
                .overlay(
                    RoundedRectangle(cornerRadius: WikiStrategyEditorMetrics.cornerRadius)
                        .strokeBorder(Color.primary.opacity(0.15))
                )
                .accessibilityLabel("Strategy instructions")
                .accessibilityHint("Markdown editorial instructions for future runs")
        }
        .padding(.horizontal, WikiStrategyEditorMetrics.contentPadding)
        .padding(.bottom, WikiStrategyEditorMetrics.editorBottomPadding)
        .frame(maxWidth: WikiStrategyEditorMetrics.contentMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controlsRow: some View {
        HStack(spacing: 12) {
            Button("Save") {
                store.saveStrategyDraft()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!store.isStrategyDraftDirty || validationProblem != nil)

            Button("Cancel") {
                store.cancelStrategyDraft()
            }
            .disabled(!store.isStrategyDraftDirty)

            Button("Reset to Default") {
                pendingAction = .resetToDefault
            }
            .disabled(store.committedStrategy == nil && draftIsBlank)

            Spacer()

            WikiStrategyTemplatePicker { template in
                if draftIsBlank {
                    store.applyStrategyTemplate(template)
                } else {
                    pendingAction = .replaceWithTemplate(template)
                }
            }
        }
    }

    // MARK: - Derived helpers

    /// Live limit feedback using the SAME named constants the store's write
    /// boundary enforces (`WikiStrategy.validatedInput` stays authoritative —
    /// this mirror only pre-flights the buttons).
    private var validationProblem: String? {
        guard store.strategyDraftActive else { return nil }
        let trimmedName = store.strategyDraftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.count > WikiStrategy.nameCharacterLimit {
            return "The name is \(trimmedName.count) characters. The limit is \(WikiStrategy.nameCharacterLimit)."
        }
        let byteCount = store.strategyDraftInstructions.utf8.count
        if byteCount > WikiStrategy.instructionsUTF8ByteLimit {
            return "The instructions are \(byteCount) bytes. The limit is \(WikiStrategy.instructionsUTF8ByteLimit) bytes."
        }
        if trimmedName.isEmpty,
           !store.strategyDraftInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Give the strategy a name, or clear the instructions to use the default strategy."
        }
        return nil
    }

    private var instructionSizeCaption: String {
        let bytes = store.strategyDraftInstructions.utf8.count
        let shown = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let limit = ByteCountFormatter.string(
            fromByteCount: Int64(WikiStrategy.instructionsUTF8ByteLimit), countStyle: .file)
        return "\(shown) of \(limit)"
    }

    private var draftIsBlank: Bool {
        store.strategyDraftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && store.strategyDraftInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func perform(_ action: WikiStrategyEditorPendingAction) {
        pendingAction = nil
        switch action {
        case .replaceWithTemplate(let template):
            store.applyStrategyTemplate(template)
        case .resetToDefault:
            store.resetStrategyToDefault()
        case .reloadFromWiki:
            store.discardStrategyDraftAndReload()
        }
    }
}

/// Named layout metrics for the strategy editor (one owner, no magic numbers).
enum WikiStrategyEditorMetrics {
    static let sectionSpacing: CGFloat = 16
    static let labelSpacing: CGFloat = 6
    static let contentPadding: CGFloat = 20
    static let contentMaxWidth: CGFloat = 680
    static let cornerRadius: CGFloat = 6
    static let instructionsMinHeight: CGFloat = 240
    /// Breathing room between the editor box and the footer divider.
    static let editorBottomPadding: CGFloat = 12
    /// The controls row is a native bottom bar: divider above, tighter
    /// vertical padding than the content's 20 (the macOS detail-footer idiom).
    static let footerVerticalPadding: CGFloat = 10
    /// Start showing the live name counter above this character count.
    static let nameCountHintThreshold = 108
    /// Padding inside the conflict banner and the confirmation row.
    static let calloutPadding: CGFloat = 12
    /// The "Edited" capsule (header and sidebar footer share these).
    static let editedCapsuleHorizontalPadding: CGFloat = 6
    static let editedCapsuleVerticalPadding: CGFloat = 2
}
