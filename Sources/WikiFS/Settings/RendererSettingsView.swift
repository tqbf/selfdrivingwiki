#if os(macOS)
import Foundation
import AppKit
import Observation
import SwiftUI
import WikiFSEngine
import WikiFSCore
import WikiFSTypes

// pattern: Functional Core

/// What one installed package version can do right now, derived from the
/// machine record instead of stored as a cluster of flags. The machine index
/// keeps the lifecycle state, the safe-mode suppression, and a closed redacted
/// diagnostic as three separate fields; settings has to present one answer, so
/// this enum resolves them in precedence order once and every column, tint, and
/// explanation reads from it.
enum RendererPackageStatus: Hashable {
    case available
    case superseded
    case safeModeSuppressed
    /// The record exists but never became renderable. The associated value is
    /// the machine index's closed diagnostic, which may be absent on an
    /// unvalidated reservation that has not failed yet.
    case unavailable(RendererPackageInstallDiagnostic?)

    static func resolve(_ record: RendererPackageInstallRecord) -> RendererPackageStatus {
        switch record.state {
        case .unvalidated, .quarantined, .removed:
            return .unavailable(record.diagnostic)
        case .validated, .superseded:
            if record.isSafeModeSuppressed { return .safeModeSuppressed }
            return record.state == .superseded ? .superseded : .available
        }
    }

    /// The short Status column label. It never wraps, so the icon carries the
    /// state and the sentence lives in ``explanation``.
    var label: String {
        switch self {
        case .available: "Available"
        case .superseded: "Superseded"
        case .safeModeSuppressed: "Safe mode"
        case .unavailable: "Unavailable"
        }
    }

    var systemImage: String {
        switch self {
        case .available: "checkmark.circle.fill"
        case .superseded: "clock.arrow.circlepath"
        case .safeModeSuppressed: "exclamationmark.shield.fill"
        case .unavailable: "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .available: .green
        case .superseded: .secondary
        case .safeModeSuppressed: .orange
        case .unavailable: .red
        }
    }

    /// The inline diagnostic sentence shown with the package it belongs to.
    var explanation: String {
        switch self {
        case .available:
            "This version is validated. Every wiki on this Mac can use it."
        case .superseded:
            "A newer version is installed. This version stays available for rollback."
        case .safeModeSuppressed:
            "A renderer failure suppressed this exact version. Reset safe mode to use it again."
        case .unavailable(let diagnostic):
            switch diagnostic {
            case .packageValidationFailed:
                "Validation rejected this version, so it never became available."
            case .packageQuarantined:
                "This version is quarantined and cannot render."
            case .packageRemoved:
                "This version was removed from this Mac."
            case .indexConsistencyFailure:
                "The machine index is inconsistent for this version. Refresh the registry."
            case nil:
                "This version is not validated yet, so it cannot render."
            }
        }
    }
}

struct RendererSettingsRow: Identifiable, Hashable {
    let record: RendererPackageInstallRecord
    let displayName: String
    let registrations: [String]
    let status: RendererPackageStatus

    var id: String { "\(record.packageID.rawValue)@\(record.version.rawValue)" }
}

/// Where a settings outcome belongs. A package-scoped outcome renders with the
/// row it describes; the pane scope is for outcomes no installed row owns — an
/// import that never produced a record, or a removal whose row is now gone.
enum RendererSettingsNoticeScope: Hashable {
    case pane
    case package(RendererSettingsRow.ID)
}

/// One settings outcome, kept scoped so the message can render next to the
/// package it is about rather than in a shared diagnostics section.
struct RendererSettingsNotice: Hashable {
    enum Severity: Hashable {
        case success
        case failure
    }

    let severity: Severity
    let message: String
    let scope: RendererSettingsNoticeScope
}

/// Settings-facing adapter for machine package management and source-specific
/// preferences. It deliberately owns no renderer-resolution state: the machine
/// index and WikiStoreModel remain authoritative, while InstalledRendererHost
/// refreshes only future registry snapshots. Existing panes retain their pinned
/// reference.
@MainActor
@Observable
final class RendererSettingsModel {
    static let installFailureMessage = "The renderer package could not be validated or installed."

    let host: InstalledRendererHost
    private(set) var wiki: WikiStoreModel?

    private(set) var rows: [RendererSettingsRow] = []
    private(set) var isBusy = false
    /// The single latest outcome. Severity and scope are derived from it rather
    /// than tracked as parallel fields, so an error can never outlive the
    /// success that replaced it.
    private(set) var notice: RendererSettingsNotice?

    var diagnostic: String? {
        guard let notice, notice.severity == .success else { return nil }
        return notice.message
    }

    var lastError: String? {
        guard let notice, notice.severity == .failure else { return nil }
        return notice.message
    }

    init(host: InstalledRendererHost, wiki: WikiStoreModel?) {
        self.host = host
        self.wiki = wiki
        rebuildRows()
    }

    /// Settings is app-scoped, while source preferences are session-scoped.
    /// Refresh the adapter whenever the active session changes so a long-lived
    /// Settings scene never writes through a stale store.
    func updateWiki(_ wiki: WikiStoreModel?) {
        guard self.wiki !== wiki else { return }
        self.wiki = wiki
        rebuildRows()
    }

    func notice(for row: RendererSettingsRow) -> RendererSettingsNotice? {
        guard let notice, notice.scope == .package(row.id) else { return nil }
        return notice
    }

    var paneNotice: RendererSettingsNotice? {
        guard let notice, notice.scope == .pane else { return nil }
        return notice
    }

    func refresh() async {
        isBusy = true
        notice = nil
        defer { isBusy = false }
        await host.refresh()
        rebuildRows()
    }

    func install(directory: URL) async {
        isBusy = true
        notice = nil
        defer { isBusy = false }
        let known = Set(rows.map(\.id))
        guard await host.installRendererDirectory(directory) else {
            notice = RendererSettingsNotice(
                severity: .failure,
                message: Self.installFailureMessage,
                scope: .pane)
            return
        }
        rebuildRows()
        // Scope the success to the row the import produced so the confirmation
        // lands on the new package. An import that replaced nothing visible
        // falls back to the pane.
        let added = rows.map(\.id).filter { known.contains($0) == false }
        notice = RendererSettingsNotice(
            severity: .success,
            message: "Renderer registry refreshed after installation.",
            scope: added.count == 1 ? .package(added[0]) : .pane)
    }

    func remove(_ row: RendererSettingsRow) async {
        isBusy = true
        notice = nil
        defer { isBusy = false }
        guard await host.removeRenderer(packageID: row.record.packageID, version: row.record.version) else {
            notice = RendererSettingsNotice(
                severity: .failure,
                message: "The renderer version could not be removed.",
                scope: .package(row.id))
            return
        }
        rebuildRows()
        // The row this described is gone, so the confirmation belongs to the pane.
        notice = RendererSettingsNotice(
            severity: .success,
            message: "Removed \(row.displayName) \(row.record.version.rawValue). Source data and wiki preferences were preserved.",
            scope: .pane)
    }

    func resetSafeMode(_ row: RendererSettingsRow) async {
        isBusy = true
        notice = nil
        defer { isBusy = false }
        guard await host.resetInstalledRendererSafeMode(
            packageID: row.record.packageID,
            version: row.record.version) else {
            notice = RendererSettingsNotice(
                severity: .failure,
                message: "Safe-mode reset was rejected.",
                scope: .package(row.id))
            return
        }
        rebuildRows()
        notice = RendererSettingsNotice(
            severity: .success,
            message: "Safe mode reset. This version can render again.",
            scope: .package(row.id))
    }

    func report(error: String) {
        notice = RendererSettingsNotice(severity: .failure, message: error, scope: .pane)
    }

    /// Version selection is an exact preference on a source. This keeps
    /// rollback scoped to the user's source choice rather than mutating the
    /// machine registry or replacing an active pane pin.
    func selectVersion(_ descriptor: RendererDescriptor, for source: SourceID) {
        guard let wiki else {
            notice = RendererSettingsNotice(
                severity: .failure,
                message: "Open a wiki before selecting a renderer version.",
                scope: .pane)
            return
        }
        wiki.setRendererSourcePreference(
            sourceID: source,
            preference: .exact(descriptor.reference))
        notice = RendererSettingsNotice(
            severity: .success,
            message: "Selected \(descriptor.displayName) \(descriptor.reference.version.rawValue) for this source.",
            scope: .pane)
    }

    /// Clearing the preference returns the source to automatic resolution. It
    /// is a distinct operation from pinning, not a pin to a sentinel version.
    func clearVersionSelection(for source: SourceID) {
        guard let wiki else {
            notice = RendererSettingsNotice(
                severity: .failure,
                message: "Open a wiki before selecting a renderer version.",
                scope: .pane)
            return
        }
        wiki.removeRendererSourcePreference(sourceID: source)
        notice = RendererSettingsNotice(
            severity: .success,
            message: "Cleared the renderer for this source. It opens as Source until you choose one.",
            scope: .pane)
    }

    func descriptors(for row: RendererSettingsRow) -> [RendererDescriptor] {
        host.machineIndex?.records
            .first(where: { $0.packageID == row.record.packageID && $0.version == row.record.version })?
            .validatedDescriptors ?? []
    }

    /// Every renderer a source can be pinned to. Only validated records project
    /// descriptors, so an unavailable package cannot become a pinned choice.
    var selectableDescriptors: [RendererDescriptor] {
        rows.filter { $0.record.state == .validated }.flatMap { descriptors(for: $0) }
    }

    /// Every package version the machine index still holds, except removal
    /// tombstones. Unavailable versions stay in the table on purpose: their
    /// status is the only place a quarantine or a validation failure is
    /// explained to the user.
    private func rebuildRows() {
        rows = (host.machineIndex?.records ?? [])
            .filter { $0.state != .removed }
            .sorted()
            .map { record in
                let descriptor = record.validatedDescriptors.first
                return RendererSettingsRow(
                    record: record,
                    displayName: descriptor?.displayName ?? record.packageID.rawValue,
                    registrations: record.validatedDescriptors.map { $0.reference.registrationID.rawValue },
                    status: .resolve(record))
            }
    }
}

/// The package table's height, in one place because the table has no intrinsic
/// content size: SwiftUI cannot ask an `NSTableView`-backed `Table` how tall its
/// rows are, so settings has to compute it.
///
/// The height follows the row count between a floor and a ceiling. A short list
/// leaves no dead space under its rows, and a long one scrolls inside the
/// table's own scroll area rather than growing the Settings window.
enum RendererPackageTableMetrics {
    /// One `Table` row at the regular control size, and the header above the
    /// rows. Both are measured from the live pane's accessibility geometry.
    static let rowHeight: CGFloat = 24
    static let headerHeight: CGFloat = 28
    /// A one-row table reads as a stray strip next to the action bar, so two
    /// rows is the floor even when only one package is installed.
    static let minimumVisibleRows = 2
    static let maximumVisibleRows = 8
    /// The empty state is a `ContentUnavailableView` with an image, a title,
    /// and a description. It needs more room than the row floor gives.
    static let emptyHeight: CGFloat = 148

    static func height(forRowCount count: Int) -> CGFloat {
        guard count > 0 else { return emptyHeight }
        let visibleRows = min(max(count, minimumVisibleRows), maximumVisibleRows)
        return headerHeight + CGFloat(visibleRows) * rowHeight
    }
}

struct RendererSettingsView: View {
    private enum Metrics {
        static let detailSpacing: CGFloat = 6
        static let sectionSpacing: CGFloat = 10
        static let actionBarSpacing: CGFloat = 6
    }

    private let wiki: WikiStoreModel?
    private let wikiID: WikiID?
    @State private var model: RendererSettingsModel
    @State private var showingPackageHelp = false
    @State private var showingPicker = false
    @State private var removalCandidate: RendererSettingsRow?
    @State private var selectedPackageID: RendererSettingsRow.ID?
    @State private var selectedSourceID: SourceID?

    init(host: InstalledRendererHost, wiki: WikiStoreModel?, wikiID: WikiID?) {
        self.wiki = wiki
        self.wikiID = wikiID
        _model = State(initialValue: RendererSettingsModel(host: host, wiki: wiki))
    }

    private var selectedRow: RendererSettingsRow? {
        model.rows.first { $0.id == selectedPackageID }
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                packageTable
            } header: {
                HStack {
                    Text("Installed on This Mac")
                    Spacer()
                    RendererPackageHelpControl(isPresented: $showingPackageHelp)
                        .buttonStyle(.borderless)
                        .labelStyle(.iconOnly)
                }
            } footer: {
                Text("\(RendererSettingsPackagePicker.localImportSourceMessage) \(RendererSettingsPackagePicker.localImportStorageMessage) \(RendererSettingsPackagePicker.localImportAfterMessage)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if let wiki = model.wiki {
                    if wiki.sources.isEmpty {
                        Text("Add a source to choose an exact renderer version.")
                            .foregroundStyle(.secondary)
                    } else {
                        sourceVersionControls(model: model)
                    }
                } else {
                    Text("Open a wiki to choose an exact renderer version for a source.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Source Renderer Preferences")
            } footer: {
                Text("Choose which installed renderer opens one source in this wiki. A source with no renderer opens as Source. This pins an exact version, so a source keeps the renderer you chose after a newer version is installed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .task(id: wikiID) {
            model.updateWiki(wiki)
            selectedSourceID = wiki?.sources.first?.id
            await model.refresh()
            selectFirstPackageIfNeeded()
        }
        .onChange(of: model.rows) { _, _ in
            selectFirstPackageIfNeeded()
        }
        // An outcome that belongs to one package selects it, so its inline
        // diagnostic is the one on screen when the message appears.
        .onChange(of: model.notice) { _, notice in
            if case .package(let id) = notice?.scope {
                selectedPackageID = id
            }
            if let notice, notice.severity == .failure {
                announceAccessibility(notice.message)
            }
        }
        .onChange(of: model.isBusy) { _, isBusy in
            if isBusy {
                announceAccessibility("Updating renderer packages")
            }
        }
        .onChange(of: showingPicker) { _, isPresented in
            guard isPresented else { return }
            let panel = RendererSettingsPackagePicker.makePanel()
            panel.begin { response in
                showingPicker = false
                guard response == .OK else { return }
                do {
                    let directory = try RendererSettingsPackagePicker.selectedDirectory(from: panel)
                    Task { await model.install(directory: directory) }
                } catch {
                    model.report(error: RendererSettingsPackagePicker.v1FormatMessage)
                }
            }
        }
        .confirmationDialog(
            "Remove renderer version?",
            isPresented: Binding(
                get: { removalCandidate != nil },
                set: { if !$0 { removalCandidate = nil } }),
            presenting: removalCandidate) { row in
                Button("Remove", role: .destructive) {
                    Task { await model.remove(row) }
                    removalCandidate = nil
                }
                Button("Cancel", role: .cancel) {}
            } message: { row in
                Text("Remove \(row.displayName) \(row.record.version.rawValue). Source data stays available and this wiki's preference remains inactive until the package is installed again.")
            }
    }

    // MARK: - Installed package table

    /// The package table, its add/remove bar, and the inline detail for the
    /// selected package. The table takes a fixed height and scrolls internally
    /// so a machine with many installed versions cannot stretch the Settings
    /// window.
    @ViewBuilder
    private var packageTable: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            Table(model.rows, selection: $selectedPackageID) {
                TableColumn("Package") { (row: RendererSettingsRow) in
                    Text(row.displayName)
                        .help(row.record.packageID.rawValue)
                }
                .width(min: 160, ideal: 220)
                TableColumn("Version") { (row: RendererSettingsRow) in
                    Text(row.record.version.rawValue)
                        .monospacedDigit()
                }
                .width(min: 80, ideal: 90)
                TableColumn("Renders") { (row: RendererSettingsRow) in
                    Text(row.registrations.isEmpty ? "—" : row.registrations.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
                .width(min: 120, ideal: 160)
                // The status is the row's own diagnostic in short form: the
                // icon carries the state, and the full sentence renders in the
                // detail below the table.
                TableColumn("Status") { (row: RendererSettingsRow) in
                    Label(row.status.label, systemImage: row.status.systemImage)
                        .foregroundStyle(row.status.tint)
                        .help(row.status.explanation)
                }
                .width(min: 110, ideal: 130)
            }
            .frame(height: RendererPackageTableMetrics.height(forRowCount: model.rows.count))
            .accessibilityIdentifier("renderer-package-table")
            .accessibilityLabel("Renderer packages installed on this Mac")
            .overlay {
                if model.rows.isEmpty {
                    ContentUnavailableView(
                        "No renderer packages are installed on this Mac.",
                        systemImage: "square.stack.3d.up.slash",
                        description: Text("Use Add to import a local renderer package folder."))
                }
            }

            packageActionBar

            if model.isBusy {
                ProgressView("Updating renderer packages…")
                    .controlSize(.small)
                    .accessibilityLabel("Updating renderer packages")
                    .accessibilityAddTraits(.updatesFrequently)
            }

            if let row = selectedRow {
                packageDetail(row)
            }

            // Outcomes no installed row owns: a rejected import, or a removal
            // whose row has already left the table.
            if let notice = model.paneNotice {
                noticeLabel(notice)
            }
        }
    }

    /// The add/remove bar beneath the table, in the macOS table idiom: Add
    /// creates a package, the destructive action applies to the selected row,
    /// and registry refresh sits opposite them.
    private var packageActionBar: some View {
        HStack(spacing: Metrics.actionBarSpacing) {
            Button("Add Package…", systemImage: "plus") {
                showingPicker = true
            }
            .disabled(model.isBusy)
            .accessibilityIdentifier("renderer-package-add-button")
            .accessibilityLabel("Add a renderer package")
            .help("Add a local renderer package folder. Files and archives are not supported.")

            Button("Remove", systemImage: "minus", role: .destructive) {
                removalCandidate = selectedRow
            }
            .disabled(model.isBusy || selectedRow == nil)
            .accessibilityIdentifier("renderer-package-remove-button")
            .accessibilityLabel("Remove the selected renderer package")

            Spacer()

            Button("Refresh Registry", systemImage: "arrow.clockwise") {
                Task { await model.refresh() }
            }
            .disabled(model.isBusy)
            .accessibilityLabel("Refresh the renderer registry")
        }
        .controlSize(.small)
    }

    /// The selected package's diagnostics, kept with the package they describe:
    /// the machine index's own status sentence first, then the latest outcome
    /// scoped to this package, then the one recovery this pane may perform.
    @ViewBuilder
    private func packageDetail(_ row: RendererSettingsRow) -> some View {
        VStack(alignment: .leading, spacing: Metrics.detailSpacing) {
            Label(row.status.explanation, systemImage: row.status.systemImage)
                .font(.body)
                .foregroundStyle(row.status.tint)
                .accessibilityLabel("\(row.displayName) \(row.record.version.rawValue). \(row.status.label). \(row.status.explanation)")

            LabeledContent("Package", value: row.record.packageID.rawValue)
                .font(.callout)
            if row.registrations.isEmpty == false {
                LabeledContent("Registrations", value: row.registrations.joined(separator: ", "))
                    .font(.callout)
            }

            if let notice = model.notice(for: row) {
                noticeLabel(notice)
            }

            if row.record.isSafeModeSuppressed {
                Button("Reset Safe Mode") { Task { await model.resetSafeMode(row) } }
                    .controlSize(.small)
                    .disabled(model.isBusy)
                    .accessibilityLabel("Reset safe mode for \(row.displayName)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Diagnostics for \(row.displayName) \(row.record.version.rawValue)")
    }

    @ViewBuilder
    private func noticeLabel(_ notice: RendererSettingsNotice) -> some View {
        Label(
            notice.message,
            systemImage: notice.severity == .failure ? "exclamationmark.triangle" : "checkmark.circle")
            .font(.callout)
            .foregroundStyle(notice.severity == .failure ? AnyShapeStyle(Color.red) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
            .textSelection(.enabled)
    }

    // MARK: - Source renderer preferences

    /// Two pop-ups instead of a list of one-shot buttons: pick the source, then
    /// pick the renderer it is pinned to. `None` is a real choice here — it
    /// clears the preference rather than pinning a sentinel. Clearing does not
    /// hand the choice back to the matcher: `RendererResolution.preferred`
    /// returns nil without a stored preference, so the source opens as Source.
    @ViewBuilder
    private func sourceVersionControls(model: RendererSettingsModel) -> some View {
        if let source = model.wiki?.sources.first(where: { $0.id == selectedSourceID }) ?? model.wiki?.sources.first {
            Picker("Source", selection: Binding(
                get: {
                    guard let selectedSourceID,
                          model.wiki?.sources.contains(where: { $0.id == selectedSourceID }) == true else {
                        return model.wiki?.sources.first?.id
                    }
                    return selectedSourceID
                },
                set: { selectedSourceID = $0 })) {
                ForEach(model.wiki?.sources ?? []) { source in
                    Text(source.effectiveName).tag(Optional(source.id))
                }
            }
            .accessibilityLabel("Source for renderer version selection")

            Picker("Renderer", selection: rendererBinding(for: source, model: model)) {
                Text("None (show Source)").tag(RendererReference?.none)
                ForEach(model.selectableDescriptors, id: \.reference) { descriptor in
                    Text("\(descriptor.displayName) \(descriptor.reference.version.rawValue)")
                        .tag(Optional(descriptor.reference))
                }
            }
            .accessibilityLabel("Selected renderer version for \(source.effectiveName)")
            .accessibilityValue(pinnedRendererDescription(for: source, model: model))
        }
    }

    private func rendererBinding(
        for source: SourceSummary,
        model: RendererSettingsModel
    ) -> Binding<RendererReference?> {
        Binding(
            get: {
                guard case let .exact(reference) = model.wiki?.rendererSourcePreference(for: source.id) else {
                    return nil
                }
                return reference
            },
            set: { reference in
                guard let reference,
                      let descriptor = model.selectableDescriptors.first(where: { $0.reference == reference })
                else {
                    model.clearVersionSelection(for: source.id)
                    return
                }
                model.selectVersion(descriptor, for: source.id)
            })
    }

    private func pinnedRendererDescription(for source: SourceSummary, model: RendererSettingsModel) -> String {
        guard case let .exact(reference) = model.wiki?.rendererSourcePreference(for: source.id),
              let descriptor = model.selectableDescriptors.first(where: { $0.reference == reference })
        else { return "None, opens as Source" }
        return "\(descriptor.displayName) \(reference.version.rawValue)"
    }

    private func selectFirstPackageIfNeeded() {
        guard model.rows.contains(where: { $0.id == selectedPackageID }) == false else { return }
        selectedPackageID = model.rows.first?.id
    }

    private func announceAccessibility(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: message])
    }
}
#endif
