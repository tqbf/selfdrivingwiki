import AppKit
import SwiftUI
import WebKit
import WikiFSCore
import WikiFSTypes

// MARK: - Sheet

/// The foreground page-lint review sheet: findings list + document pane
/// (Rendered/Source), inline repair choices, full candidate diff preview,
/// and the Apply/Discard handoff. One instance per active run, owned by the
/// wiki session. The page stays the main content; the sheet never autosaves
/// or discards editor drafts.
struct ForegroundLintSheet: View {
    @Bindable var session: ForegroundLintSession
    let pageTitle: String
    /// The Apply handoff: performs the app-model composed write with the
    /// previewed candidate pinned. The closure returns the outcome; the sheet
    /// routes it back into the session (committed version / stale / refusal).
    let onApply: (LintRepairProposal, String) async -> LintApplyOutcome
    let onClose: () -> Void

    enum DocumentMode: Hashable {
        case rendered
        case source
    }

    @State private var documentMode: DocumentMode = .rendered
    @State private var applyError: String?

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            notices
            HSplitView {
                findingsList
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
                    .frame(maxHeight: .infinity)
                documentPane
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minHeight: 320)
            if session.proposal != nil {
                Divider()
                previewBar
            }
        }
        .frame(minWidth: 720, idealWidth: 920, minHeight: 500, idealHeight: 640)
    }

    // MARK: Status bar

    @ViewBuilder
    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal")
                .foregroundStyle(.secondary)
            Text("Lint — \(pageTitle)")
                .font(.headline)
            statusBadge
            Spacer()
            if session.canRerun {
                Button("Rerun") { session.rerun() }
                    .accessibilityIdentifier("lint-rerun")
            }
            if session.canCancel {
                ProgressView()
                    .controlSize(.small)
                Button("Cancel") { session.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("lint-cancel")
            } else {
                Button("Close") {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("lint-close")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch session.phase {
        case .preparing:
            Label("Preparing…", systemImage: "hourglass")
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .accessibilityIdentifier("lint-status")
        case .checking:
            Label("Checking…", systemImage: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
                .accessibilityIdentifier("lint-status")
        case .reviewing:
            if session.canRerun {
                Label("Repair applied — Rerun to re-check the page", systemImage: "checkmark.seal")
                    .foregroundStyle(.indigo)
                    .font(.caption)
                    .accessibilityIdentifier("lint-status")
            } else if session.isIncomplete {
                Text("Incomplete — a check failed")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("lint-status")
            } else if session.findings.isEmpty {
                Text("No findings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("lint-status")
            } else {
                Text("\(session.findings.count) finding\(session.findings.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("lint-status")
            }
        case .proposing:
            Label("Preparing repair…", systemImage: "wand.and.stars")
                .foregroundStyle(.secondary)
                .font(.caption)
                .accessibilityIdentifier("lint-status")
        case .previewing:
            Text("Preview — review the diff, then Apply")
                .font(.caption)
                .foregroundStyle(.indigo)
                .accessibilityIdentifier("lint-status")
        case .applying:
            Text("Applying…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("lint-status")
        case .stale:
            Label("Stale — the page changed. Rerun lint.", systemImage: "exclamationmark.arrow.circlepath")
                .foregroundStyle(.orange)
                .font(.caption)
                .accessibilityIdentifier("lint-status")
        case .cancelling:
            Text("Cancelling…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("lint-status")
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon")
                .foregroundStyle(.red)
                .font(.caption)
                .lineLimit(2)
                .accessibilityIdentifier("lint-status")
        }
    }

    // MARK: Notices

    @ViewBuilder
    private var notices: some View {
        let messages = noticeMessages
        if !messages.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(messages.indices, id: \.self) { index in
                    Label(messages[index], systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("lint-notice-\(index)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quinary)
            Divider()
        }
    }

    private var noticeMessages: [String] {
        var messages: [String] = []
        if !session.didRunModelStep, !session.modelNotice.isEmpty {
            messages.append(session.modelNotice)
        }
        for failure in session.stepFailures {
            messages.append("Check '\(failure.id.rawValue)' failed: \(failure.message)")
        }
        for disabled in session.disabledStepIDs {
            messages.append("Check '\(disabled.rawValue)' is disabled by configuration.")
        }
        if !session.validatorFailures.isEmpty {
            messages.append(session.validatorFailures.joined(separator: " "))
        }
        if let applyError {
            messages.append(applyError)
        }
        return messages
    }

    // MARK: Findings list

    private var findingsList: some View {
        List(selection: Binding(
            get: { session.selectedFindingID },
            set: { id in
                if let id { session.select(findingID: id) }
            })) {
            if session.findings.isEmpty, !session.isBusy {
                ContentUnavailableView(
                    "No findings",
                    systemImage: "checkmark.seal",
                    description: Text(
                        session.canRerun
                            ? "The repair was applied. Rerun lint to check the updated page."
                            : session.isIncomplete
                                ? "The checks that ran reported nothing. A failed check is listed above."
                                : "The page passed every check."))
            }
            if !session.pageFindings.isEmpty {
                Section("Page") {
                    ForEach(session.pageFindings) { finding in
                        findingRow(finding)
                    }
                }
            }
            if !session.passageFindings.isEmpty {
                Section("Passages") {
                    ForEach(session.passageFindings) { finding in
                        findingRow(finding)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func findingRow(_ finding: LintFinding) -> some View {
        let isSelected = session.selectedFindingID == finding.id
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: severitySymbol(finding.severity))
                    .foregroundStyle(severityColor(finding.severity))
                    .accessibilityLabel(finding.severity.rawValue)
                Text(finding.message)
                    .font(.callout)
                    .lineLimit(3)
                if case .page = finding.scope {
                    Text("Page")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
            Text("Check: \(finding.stepID.rawValue)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if finding.repairOptions.isEmpty {
                Text("Report-only — no safe automatic repair")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if isSelected, session.canStartRepair {
                // Inline choice list — a real button per option (no native
                // pop-up menu automation; see the hosted-test notes).
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(finding.repairOptions) { option in
                        Button {
                            session.choose(option: option, for: finding)
                        } label: {
                            Label(option.label, systemImage: "wand.and.rays")
                        }
                        .accessibilityLabel("Repair: \(option.label)")
                        .accessibilityIdentifier("lint-repair-\(option.recipeID.rawValue)")
                    }
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { session.select(findingID: finding.id) }
        .background(
            isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Finding: \(finding.message). Check \(finding.stepID.rawValue).")
    }

    private func severitySymbol(_ severity: LintSeverity) -> String {
        switch severity {
        case .error: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    private func severityColor(_ severity: LintSeverity) -> Color {
        switch severity {
        case .error: .red
        case .warning: .orange
        case .info: .blue
        }
    }

    // MARK: Document pane

    @ViewBuilder
    private var documentPane: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("View", selection: $documentMode) {
                    Text("Rendered").tag(DocumentMode.rendered)
                    Text("Source").tag(DocumentMode.source)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            if session.phase == .previewing, let proposal = session.proposal,
               let candidate = session.candidate, let snapshot = session.snapshot {
                previewPane(proposal: proposal, candidate: candidate, snapshot: snapshot)
            } else {
                documentBody
            }
        }
    }

    @ViewBuilder
    private var documentBody: some View {
        switch documentMode {
        case .rendered:
            LintDocumentWebView(
                markdown: session.snapshot?.body ?? "",
                highlightRanges: selectedPassageByteRanges)
        case .source:
            LintSourceTextView(
                text: session.snapshot?.body ?? "",
                highlightUTF16Ranges: selectedPassageNSRanges)
        }
    }

    @ViewBuilder
    private func previewPane(
        proposal: LintRepairProposal, candidate: String, snapshot: LintPageSnapshot
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.right")
                    .foregroundStyle(.indigo)
                Text("Proposed change — \(optionLabel(for: proposal))")
                    .font(.callout.weight(.medium))
                Spacer()
                Button("Discard") {
                    session.discardProposal()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("lint-discard")
                Button("Apply") {
                    applyError = nil
                    Task {
                        let outcome = await onApply(proposal, candidate)
                        switch outcome {
                        case .committed(let versionID):
                            session.commitApplied(versionID: versionID)
                        case .stale(let message):
                            applyError = message
                            session.markStale()
                        case .refused(let message):
                            applyError = message
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(session.phase != .previewing)
                .accessibilityLabel("Apply proposed change")
                .accessibilityIdentifier("lint-apply")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            SplitDiffView(
                leftLabel: "Current",
                rightLabel: "After repair",
                left: snapshot.body,
                right: candidate)
        }
    }

    private func optionLabel(for proposal: LintRepairProposal) -> String {
        session.findings
            .first { $0.id == proposal.findingID }?
            .repairOptions
            .first { $0.id == proposal.optionID }?
            .label ?? proposal.optionID.rawValue
    }

    private var previewBar: some View {
        EmptyView()
    }

    // MARK: Highlight payloads

    /// The selected finding's validated byte ranges (rendered markers).
    private var selectedPassageByteRanges: [Range<Int>] {
        guard let id = session.selectedFindingID,
              let finding = session.findings.first(where: { $0.id == id }) else {
            return []
        }
        return finding.passageRanges.map { $0.bounds }
    }

    /// The selected finding's UTF-16 ranges (source text highlights).
    private var selectedPassageNSRanges: [NSRange] {
        guard let body = session.snapshot?.body else { return [] }
        var ranges: [NSRange] = []
        for bytes in selectedPassageByteRanges {
            do {
                ranges.append(try LintLocationAdapter.nsRange(forUTF8Range: bytes, in: body))
            } catch {
                DebugLog.lint("Lint sheet: source highlight conversion failed: \(error)")
            }
        }
        return ranges
    }
}

// MARK: - Apply outcome

/// The Apply handoff's result, routed back into the session.
enum LintApplyOutcome: Sendable {
    case committed(PageVersionID)
    /// The page changed / was deleted / the draft went dirty: zero writes.
    case stale(String)
    /// The write was refused before any version (canonicalization moved).
    case refused(String)
}

// MARK: - Rendered document (script-disabled WKWebView)

/// The lint sheet's rendered document: the production `MarkdownHTMLRenderer`
/// over the captured body, with inert block markers for the selected
/// finding's ranges. Scripts are disabled; highlight payloads are encoded
/// data in the HTML itself (attributes), never interpolated JavaScript.
struct LintDocumentWebView: View {
    let markdown: String
    let highlightRanges: [Range<Int>]

    var body: some View {
        LintDocumentWebViewRep(html: renderedHTML)
    }

    private var renderedHTML: String {
        let prepared = ReaderMarkdown.preparedDocument(markdown)
        var highlights: [MarkdownSourceRange] = []
        for range in highlightRanges {
            do {
                highlights.append(try MarkdownSourceRange(
                    lowerBound: range.lowerBound, upperBound: range.upperBound))
            } catch {
                DebugLog.lint("LintDocumentWebView: dropping invalid highlight range: \(error)")
            }
        }
        let options = MarkdownRenderOptions.disabled.withLintHighlights(highlights)
        let bodyHTML = MarkdownHTMLRenderer.render(prepared, projection: nil, options: options)
        return Self.pageHTML(bodyHTML)
    }

    /// The document wrapper: system text styles, light/dark aware, and the
    /// `.wiki-lint-mark` outline. No scripts.
    static func pageHTML(_ bodyHTML: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><style>
        :root { color-scheme: light dark; }
        body {
          font: -apple-system-body;
          font-family: ui-serif, Georgia, serif;
          margin: 1.2em 1.5em;
          line-height: 1.5;
          color:-textColor;
        }
        pre, code { font-family: ui-monospace, Menlo, monospace; font-size: 0.9em; }
        .wiki-lint-mark > :first-child {
          outline: 2px solid rgba(255, 159, 10, 0.55);
          outline-offset: 3px;
          border-radius: 3px;
          background: rgba(255, 159, 10, 0.10);
        }
        </style></head><body>\(bodyHTML)</body></html>
        """
    }
}

private struct LintDocumentWebViewRep: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = false
        config.defaultWebpagePreferences = prefs
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.underPageBackgroundColor = .textBackgroundColor
        webView.navigationDelegate = context.coordinator
        context.coordinator.load(html, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // No synchronous state writes — the coordinator compares and loads.
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.load(html, into: webView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML: String?
        /// Set when the just-loaded document contains lint marks; on
        /// navigation finish, the first marked block is scrolled into view
        /// (centered) so a clicked passage is immediately visible.
        var pendingScrollToMark = false

        func load(_ html: String, into webView: WKWebView) {
            loadedHTML = html
            // `data-lint-mark` appears only on actually-marked blocks — the
            // stylesheet mentions the class name unconditionally.
            pendingScrollToMark = html.contains("data-lint-mark")
            webView.loadHTMLString(html, baseURL: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            guard pendingScrollToMark else { return }
            pendingScrollToMark = false
            // Host-driven JS runs even though page scripts are disabled.
            // Multiple ranges mark multiple blocks; the first is the
            // finding's primary anchor.
            webView.evaluateJavaScript(
                "var m = document.querySelector('.wiki-lint-mark');"
                    + "if (m) { m.scrollIntoView({block: 'center'}); }",
                completionHandler: nil)
        }
    }
}

// MARK: - Source text view (read-only, exact UTF-16 highlights)

/// The lint sheet's Source mode: a read-only `NSTextView` showing the exact
/// captured bytes, with the selected finding's ranges highlighted via
/// temporary attributes and scrolled into view. Programmatic mutations are
/// flag-bracketed so the delegate never reports them back into SwiftUI
/// (the "modifying state during view update" trap).
struct LintSourceTextView: NSViewRepresentable {
    let text: String
    let highlightUTF16Ranges: [NSRange]

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.autoresizingMask = [.width]
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        context.coordinator.isApplyingProgrammaticChange = true
        textView.string = text
        context.coordinator.isApplyingProgrammaticChange = false
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // Flag-bracket every programmatic mutation (AppKit setters fire
        // delegate callbacks synchronously).
        context.coordinator.isApplyingProgrammaticChange = true
        defer { context.coordinator.isApplyingProgrammaticChange = false }
        if textView.string != text {
            textView.string = text
        }
        // Clear old marks, then apply the current payload.
        let full = NSRange(location: 0, length: (textView.string as NSString).length)
        textView.textStorage?.removeAttribute(.backgroundColor, range: full)
        guard let effective = textView.layoutManager else { return }
        for range in highlightUTF16Ranges where NSIntersectionRange(range, full).length == range.length {
            textView.textStorage?.addAttribute(
                .backgroundColor, value: NSColor.systemOrange.withAlphaComponent(0.28),
                range: range)
            effective.addTemporaryAttributes(
                [.backgroundColor: NSColor.systemOrange.withAlphaComponent(0.28)],
                forCharacterRange: range)
        }
        if let first = highlightUTF16Ranges.first, first.location <= full.length {
            textView.scrollRangeToVisible(first)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        /// Suppresses write-back while the representable is the mutator.
        var isApplyingProgrammaticChange = false

        func textViewDidChangeSelection(_ notification: Notification) {
            // Programmatic mutation is not user input; nothing to report.
            _ = isApplyingProgrammaticChange
        }
    }
}
