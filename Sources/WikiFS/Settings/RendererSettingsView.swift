#if os(macOS)
import Foundation
import AppKit
import Observation
import SwiftUI
import WikiFSEngine
import WikiFSCore
import WikiFSTypes

// pattern: Functional Core

struct RendererSettingsRow: Identifiable, Hashable {
    let record: RendererPackageInstallRecord
    let displayName: String
    let registrations: [String]

    var id: String { "\(record.packageID.rawValue)@\(record.version.rawValue)" }
}

/// Settings-facing adapter for machine package management and source-specific
/// preferences. It deliberately owns no renderer-resolution state: the machine
/// index and WikiStoreModel remain authoritative, while InstalledRendererHost
/// refreshes only future registry snapshots. Existing panes retain their pinned
/// reference.
@MainActor
@Observable
final class RendererSettingsModel {
    let host: InstalledRendererHost
    private(set) var wiki: WikiStoreModel?

    private(set) var rows: [RendererSettingsRow] = []
    private(set) var isBusy = false
    private(set) var diagnostic: String?
    private(set) var lastError: String?

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

    func refresh() async {
        isBusy = true
        defer { isBusy = false }
        await host.refresh()
        rebuildRows()
    }

    func install(directory: URL) async {
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        guard await host.installRendererDirectory(directory) else {
            lastError = "The renderer package could not be validated or installed."
            return
        }
        diagnostic = "Renderer registry refreshed after installation."
        rebuildRows()
    }

    func remove(_ row: RendererSettingsRow) async {
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        guard await host.removeRenderer(packageID: row.record.packageID, version: row.record.version) else {
            lastError = "The renderer version could not be removed."
            return
        }
        diagnostic = "Removed \(row.record.packageID.rawValue) \(row.record.version.rawValue). Source data and wiki preferences were preserved."
        rebuildRows()
    }

    func resetSafeMode(_ row: RendererSettingsRow) async {
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        guard await host.resetInstalledRendererSafeMode(
            packageID: row.record.packageID,
            version: row.record.version) else {
            lastError = "Safe-mode reset was rejected."
            return
        }
        diagnostic = "Safe mode reset for \(row.record.packageID.rawValue) \(row.record.version.rawValue)."
        rebuildRows()
    }

    func report(error: String) {
        lastError = error
    }

    /// Version selection is an exact preference on a source. This keeps
    /// rollback scoped to the user's source choice rather than mutating the
    /// machine registry or replacing an active pane pin.
    func selectVersion(_ descriptor: RendererDescriptor, for source: SourceID) {
        guard let wiki else {
            lastError = "Open a wiki before selecting a renderer version."
            return
        }
        wiki.setRendererSourcePreference(
            sourceID: source,
            preference: .exact(descriptor.reference))
        diagnostic = "Selected \(descriptor.displayName) \(descriptor.reference.version.rawValue) for this source."
    }

    func descriptors(for row: RendererSettingsRow) -> [RendererDescriptor] {
        host.machineIndex?.records
            .first(where: { $0.packageID == row.record.packageID && $0.version == row.record.version })?
            .validatedDescriptors ?? []
    }

    private func rebuildRows() {
        rows = (host.machineIndex?.records ?? [])
            .filter { $0.state != .removed }
            .sorted()
            .map { record in
                let descriptor = record.validatedDescriptors.first
                return RendererSettingsRow(
                    record: record,
                    displayName: descriptor?.displayName ?? record.packageID.rawValue,
                    registrations: record.validatedDescriptors.map { $0.reference.registrationID.rawValue })
            }
    }
}

struct RendererSettingsView: View {
    private let wiki: WikiStoreModel?
    private let wikiID: WikiID?
    @State private var model: RendererSettingsModel
    @State private var showingPackageHelp = false
    @State private var showingPicker = false
    @State private var removalCandidate: RendererSettingsRow?
    @State private var selectedSourceID: SourceID?

    init(host: InstalledRendererHost, wiki: WikiStoreModel?, wikiID: WikiID?) {
        self.wiki = wiki
        self.wikiID = wikiID
        _model = State(initialValue: RendererSettingsModel(host: host, wiki: wiki))
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                RendererPackageHelpControl(isPresented: $showingPackageHelp)
                DisclosureGroup("Advanced Local Renderer Package Import") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(RendererSettingsPackagePicker.localImportSourceMessage)
                        Text(RendererSettingsPackagePicker.localImportStorageMessage)
                        Text(RendererSettingsPackagePicker.localImportAfterMessage)
                        Text("Files and archives are not supported.")
                        Button(RendererSettingsPackagePicker.importButtonTitle, systemImage: "square.and.arrow.down") {
                            showingPicker = true
                        }
                        .disabled(model.isBusy)
                    }
                }
                .accessibilityLabel("Advanced local renderer package import")
                Button("Refresh Registry", systemImage: "arrow.clockwise") {
                    Task { await model.refresh() }
                }
                .disabled(model.isBusy)
                if model.isBusy {
                    ProgressView("Updating renderer packages…")
                        .controlSize(.small)
                        .accessibilityLabel("Updating renderer packages")
                        .accessibilityAddTraits(.updatesFrequently)
                }
            } header: {
                Text("Package Management")
            }

            Section {
                if model.rows.isEmpty {
                    ContentUnavailableView("No renderer packages are installed on this Mac.", systemImage: "square.stack.3d.up.slash")
                } else {
                    ForEach(model.rows) { row in
                        rendererRow(row, model: model)
                    }
                }
            } header: {
                Text("Installed on This Mac")
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
            }

            if let diagnostic = model.diagnostic {
                Section("Diagnostics") {
                    DisclosureGroup("Latest renderer diagnostic") {
                        Text(diagnostic)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                }
            }
            if let error = model.lastError {
                Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .accessibilityLabel("Renderer management unavailable. \(error)")
                } header: {
                    Text("Renderer management unavailable")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task(id: wikiID) {
            model.updateWiki(wiki)
            selectedSourceID = wiki?.sources.first?.id
            await model.refresh()
        }
        .onChange(of: model.isBusy) { _, isBusy in
            if isBusy {
                announceAccessibility("Updating renderer packages")
            }
        }
        .onChange(of: model.lastError) { _, error in
            if let error {
                announceAccessibility("Renderer management unavailable. \(error)")
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

    @ViewBuilder
    private func rendererRow(_ row: RendererSettingsRow, model: RendererSettingsModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading) {
                    Text(row.displayName).font(.headline)
                    Text("Version \(row.record.version.rawValue)").foregroundStyle(.secondary)
                }
                Spacer()
                Text(row.record.state == .validated ? "Validated" : row.record.state.rawValue.capitalized)
                    .foregroundStyle(row.record.state == .validated ? .green : .secondary)
            }
            if row.registrations.isEmpty == false {
                Text("Registrations: \(row.registrations.joined(separator: ", "))")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if row.record.isSafeModeSuppressed {
                    Button("Reset Safe Mode") { Task { await model.resetSafeMode(row) } }
                        .accessibilityLabel("Reset safe mode for \(row.displayName)")
                }
                Spacer()
                Button("Remove", role: .destructive) { removalCandidate = row }
                    .disabled(model.isBusy)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func sourceVersionControls(model: RendererSettingsModel) -> some View {
        if let source = model.wiki?.sources.first(where: { $0.id == selectedSourceID }) ?? model.wiki?.sources.first {
            Picker("Source for version selection", selection: Binding(
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
            ForEach(model.rows.filter { $0.record.state == .validated }) { row in
                ForEach(model.descriptors(for: row), id: \.reference) { descriptor in
                    let preference = model.wiki?.rendererSourcePreference(for: source.id)
                    let isSelected = isExactPreference(preference, matching: descriptor.reference)
                    Button {
                        model.selectVersion(descriptor, for: source.id)
                    } label: {
                        HStack {
                            Text("Use \(descriptor.displayName) \(descriptor.reference.version.rawValue) for \(source.effectiveName)")
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .accessibilityLabel("\(descriptor.displayName), version \(descriptor.reference.version.rawValue), for \(source.effectiveName)")
                    .accessibilityValue(isSelected ? "Selected renderer version" : "Not selected")
                }
            }
        }
    }

    private func announceAccessibility(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: message])
    }

    private func isExactPreference(
        _ preference: RendererPreferenceReference?,
        matching reference: RendererReference
    ) -> Bool {
        guard case let .exact(selectedReference) = preference else { return false }
        return selectedReference == reference
    }
}
#endif
