import SwiftUI

// MARK: - Header presentation

/// Everything `QueueJobHeaderView` renders for the selected job, derived by the
/// caller from `QueueItem` + report data *before* view evaluation (plain values
/// only — no `@Observable` reads in the header body).
///
/// The header shows one recognizable title, the operation/wiki/state line, the
/// current recorded phase with progress, exactly one elapsed clock, and the
/// state-driven actions (plan §1 "Selected job workspace"). Job errors and
/// pending permissions render here, above the parent's content selector.
struct QueueJobHeaderPresentation {
    /// Recognizable job title — first target name, "Lint 3 pages", or "Whole
    /// wiki" (caller composes; this layer only renders).
    let title: String
    /// Operation word: "Ingest" / "Extract" / "Lint".
    let operationLabel: String
    /// Wiki display name.
    let wikiName: String
    /// Job lifecycle — drives the status line and Cancel/Retry visibility.
    let lifecycle: QueueWorkspaceJobLifecycle
    /// Current recorded phase with optional observed counts. `nil` renders no
    /// progress region (queued jobs before a phase is recorded).
    let progress: QueueWorkspaceProgress?
    /// Run start; the ticking elapsed clock renders only while running.
    let startedAt: Date?
    /// Static duration for terminal states ("2m 14s"); the clock shows this
    /// instead of ticking.
    let durationText: String?
    /// Job-level error (failed command / aggregate failure). Inline and
    /// selectable — never buried in Run Details.
    let errorText: String?
    /// Whether `errorText` points at configuration the user can fix; shows the
    /// `configure` action when true. Reuse
    /// `ActivityWindowView.isConfigurationErrorMarker` at the call site.
    let isConfigurationError: Bool
    /// Pending always-ask permission summary ("Permission pending: Edit file"),
    /// rendered as the conspicuous yellow stall row.
    let pendingPermissionText: String?
    /// True while a Cancel/Retry/configure command is in flight — disables the
    /// actions so a double-click cannot submit duplicates. Do not optimistically
    /// claim success here; the caller flips this back on completion or failure.
    let isCommandPending: Bool

    init(
        title: String,
        operationLabel: String,
        wikiName: String,
        lifecycle: QueueWorkspaceJobLifecycle,
        progress: QueueWorkspaceProgress? = nil,
        startedAt: Date? = nil,
        durationText: String? = nil,
        errorText: String? = nil,
        isConfigurationError: Bool = false,
        pendingPermissionText: String? = nil,
        isCommandPending: Bool = false
    ) {
        self.title = title
        self.operationLabel = operationLabel
        self.wikiName = wikiName
        self.lifecycle = lifecycle
        self.progress = progress
        self.startedAt = startedAt
        self.durationText = durationText
        self.errorText = errorText
        self.isConfigurationError = isConfigurationError
        self.pendingPermissionText = pendingPermissionText
        self.isCommandPending = isCommandPending
    }
}

// MARK: - Header view

/// The selected job's header: responsive title/state/phase/progress/actions
/// band at the top of the workspace. Wide windows put actions right of the
/// title block; narrow windows wrap them beneath the title (plan: "At narrow
/// widths, wrap header actions beneath the title"). The Overview/Activity
/// selector and the inventory live below — the parent owns that composition.
struct QueueJobHeaderView: View {
    private let header: QueueJobHeaderPresentation
    private let onCancel: (() -> Void)?
    private let onRetry: (() -> Void)?
    private let configure: QueueWorkspaceAction?
    private let additionalActions: [QueueWorkspaceAction]

    /// - Parameters:
    ///   - header: Derived display values.
    ///   - onCancel: Rendered as Cancel for queued/running jobs when non-nil.
    ///   - onRetry: Rendered as "Retry Job" for failed/cancelled jobs when
    ///     non-nil. Retry keeps existing whole-job semantics.
    ///   - configure: The Settings call-to-action for configuration failures
    ///     (label like "Configure Agents…"); shown only with an error that
    ///     `isConfigurationError` marks as fixable.
    ///   - additionalActions: Quiet icon actions (e.g. Reveal Debug Folder).
    init(
        _ header: QueueJobHeaderPresentation,
        onCancel: (() -> Void)? = nil,
        onRetry: (() -> Void)? = nil,
        configure: QueueWorkspaceAction? = nil,
        additionalActions: [QueueWorkspaceAction] = []
    ) {
        self.header = header
        self.onCancel = onCancel
        self.onRetry = onRetry
        self.configure = configure
        self.additionalActions = additionalActions
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            wideLayout
            narrowLayout
        }
        .padding(.horizontal, QueueWorkspaceMetrics.Spacing.md)
        .padding(.vertical, QueueWorkspaceMetrics.Header.verticalPadding)
    }

    // MARK: Layouts

    /// Wide: content left, actions right on one band.
    private var wideLayout: some View {
        HStack(alignment: .top, spacing: QueueWorkspaceMetrics.Spacing.md) {
            contentBlock
            Spacer(minLength: QueueWorkspaceMetrics.Spacing.sm)
            actionsRow
        }
    }

    /// Narrow: actions wrap beneath the title block (no competing columns).
    private var narrowLayout: some View {
        VStack(alignment: .leading, spacing: QueueWorkspaceMetrics.Header.actionRowTopSpacing) {
            contentBlock
            actionsRow
        }
    }

    /// Title, operation/wiki/state line, phase/progress, error, permission —
    /// identical in both layouts so only the action placement changes.
    private var contentBlock: some View {
        VStack(alignment: .leading, spacing: QueueWorkspaceMetrics.Spacing.xs) {
            Text(header.title)
                .font(.title2)
                .lineLimit(QueueWorkspaceMetrics.Header.titleLineLimit)
            metaLine
            progressRegion
            errorRegion
            permissionRegion
        }
    }

    /// "Research Wiki · Running · 2m 14s" — wiki, state (symbol + text), and
    /// the job's single elapsed clock.
    private var metaLine: some View {
        HStack(spacing: QueueWorkspaceMetrics.Spacing.xs) {
            Text(header.wikiName)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(verbatim: "·")
                .font(.callout)
                .foregroundStyle(.tertiary)
            statusLabel
            clockLine
        }
    }

    /// Status symbol + text, styled by the semantic role (plan: pair every
    /// color-coded status with text and a symbol).
    private var statusLabel: some View {
        let status = header.lifecycle.status
        return Label(status.text, systemImage: status.symbol)
            .font(.callout)
            .foregroundStyle(Self.foregroundStyle(for: status.style))
            .accessibilityLabel("\(header.operationLabel) \(status.text)")
    }

    /// The one elapsed clock: ticking per second while running (so it moves
    /// even between usage updates), static duration otherwise, nothing for a
    /// queued job that never started.
    @ViewBuilder
    private var clockLine: some View {
        switch header.lifecycle {
        case .running:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(QueueWorkspaceFormat.elapsed(from: header.startedAt, to: context.date))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case .queued, .completed, .failed, .cancelled:
            if let duration = header.durationText {
                Text(verbatim: "· \(duration)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    /// Phase + counts + bar. Determinate only for a known total with an
    /// observed numerator; otherwise an indeterminate bar with a meaningful
    /// phase ("Staging sources" vs "Staging sources: 8 of 12").
    @ViewBuilder
    private var progressRegion: some View {
        if let progress = header.progress {
            VStack(alignment: .leading, spacing: QueueWorkspaceMetrics.Spacing.xs) {
                HStack(spacing: QueueWorkspaceMetrics.Spacing.xs) {
                    Text(progress.phaseText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let counts = progress.countsText {
                        Text(counts)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if progress.isRenderableDeterminate,
                   case .determinate(_, let completed, let total) = progress {
                    ProgressView(value: Double(completed), total: Double(total))
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .accessibilityLabel(progress.phaseText)
                        .accessibilityValue(progress.countsText ?? "")
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .accessibilityLabel(progress.phaseText)
                }
            }
        }
    }

    /// Inline recoverable error (red, selectable, bounded) plus the Settings
    /// call-to-action for configuration failures only.
    @ViewBuilder
    private var errorRegion: some View {
        if let error = header.errorText {
            VStack(alignment: .leading, spacing: QueueWorkspaceMetrics.Spacing.xs) {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .lineLimit(QueueWorkspaceMetrics.Header.errorLineLimit)
                if header.isConfigurationError, let configure {
                    Button {
                        configure.perform()
                    } label: {
                        Label(configure.label, systemImage: configure.systemImage)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(header.isCommandPending)
                    .help(configure.label)
                }
            }
        }
    }

    /// The yellow permission stall row — same treatment as the existing
    /// `PermissionPendingRow` so a parked run is conspicuous in the header.
    @ViewBuilder
    private var permissionRegion: some View {
        if let permission = header.pendingPermissionText {
            Label(permission, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .help(permission)
        }
    }

    /// State-driven actions: Retry Job (failed/cancelled), Cancel
    /// (queued/running), quiet additional actions. All disabled while a command
    /// is pending so rapid clicks cannot submit duplicates.
    private var actionsRow: some View {
        HStack(spacing: QueueWorkspaceMetrics.Spacing.xs) {
            if header.lifecycle.showsRetryAction, let onRetry {
                Button(action: onRetry) {
                    Label("Retry Job", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(header.isCommandPending)
                .help("Run this job again as a new attempt")
            }
            if header.lifecycle.showsCancelAction, let onCancel {
                // Deliberately no `.cancel` keyboard role: Escape must never
                // cancel work (plan keyboard rules).
                Button(action: onCancel) {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(header.isCommandPending)
                .help("Cancel this job")
            }
            ForEach(Array(additionalActions.enumerated()), id: \.offset) { _, action in
                Button {
                    action.perform()
                } label: {
                    Label(action.label, systemImage: action.systemImage)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(header.isCommandPending)
                .accessibilityLabel(action.label)
                .help(action.label)
            }
        }
    }

    /// Semantic style → foreground style, resolved in exactly one place.
    private static func foregroundStyle(for style: QueueWorkspaceStatus.Style) -> Color {
        switch style {
        case .primary: return .primary
        case .secondary: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .failure: return .red
        case .running: return .primary
        }
    }
}
