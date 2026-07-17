import SwiftUI
import WikiFSCore

/// The detail-pane tab for one `Connection`. Two modes:
///
/// - **Config** — a native `SchemaForm` rendered from the provider manifest's
///   JSON schema, plus "Test Connection" and "Save". This is the surface that
///   replaces the per-provider hand-written settings screen (issue #483): a new
///   provider contributes a schema, not Swift.
/// - **Workspace** — the configured connection's browse/add surface. For Zotero
///   that's the native search picker (`ZoteroConnectionWorkspaceView`).
///
/// Opens in Workspace when already configured, else Config. The Connection is
/// read from the per-wiki `WikiStoreModel` (backed by the SQLite `connections`
/// table), so a save here is visible in the sidebar's Connections section
/// immediately.
struct ConnectionDetailView: View {
    @Bindable var store: WikiStoreModel
    let connectionID: String

    @State private var isEditing = false
    @State private var didInitMode = false
    /// Merged config + secret values driving the form (secrets split out on Save).
    @State private var formValues: [String: String] = [:]
    @State private var testPhase: TestPhase = .idle

    private enum TestPhase: Equatable {
        case idle, testing, ok
        case failed(String)
    }

    var body: some View {
        content
            .onAppear(perform: initModeIfNeeded)
    }

    @ViewBuilder
    private var content: some View {
        if let connection = store.connection(id: connectionID),
           let manifest = store.manifest(for: connection) {
            VStack(spacing: 0) {
                header(connection: connection, manifest: manifest)
                Divider()
                if isEditing {
                    configForm(connection: connection, manifest: manifest)
                } else {
                    workspace(connection: connection, manifest: manifest)
                }
            }
        } else {
            ContentUnavailableView {
                Label("Connection Unavailable", systemImage: "cable.connector.slash")
            } description: {
                Text("This connection or its provider is no longer available.")
            }
        }
    }

    // MARK: - Header

    private func header(connection: Connection, manifest: ProviderManifest) -> some View {
        HStack(spacing: 10) {
            Image(systemName: manifest.icon)
                .font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                // Renames in place exactly like a page/source title (double-click
                // or right-click → Rename). Commit persists via the store and
                // retitles the open tab; the sidebar row updates observably.
                EditableTitle(
                    title: connection.label,
                    placeholder: manifest.displayName,
                    font: .headline
                ) { newLabel in
                    store.renameConnection(id: connection.id, to: newLabel)
                }
                Text(manifest.displayName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isEditing {
                Button("Done") {
                    save(connection: connection, manifest: manifest)
                }
            } else {
                Button {
                    loadFormValues(connection: connection, manifest: manifest)
                    testPhase = .idle
                    isEditing = true
                } label: {
                    Label("Configure", systemImage: "gearshape")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Config mode

    @ViewBuilder
    private func configForm(connection: Connection, manifest: ProviderManifest) -> some View {
        // The action bar is pinned as a bottom safe-area inset, NOT stacked after
        // the form: a `.grouped` Form is greedy vertically and would otherwise
        // push "Save" off the bottom of the pane (the bug where you could set a
        // folder but never reach a way to finish).
        SchemaForm(schema: manifest.config, values: $formValues)
            .safeAreaInset(edge: .bottom) {
                actionBar(connection: connection, manifest: manifest)
            }
    }

    private func actionBar(connection: Connection, manifest: ProviderManifest) -> some View {
        HStack(spacing: 10) {
            switch testPhase {
            case .idle:
                EmptyView()
            case .testing:
                ProgressView().controlSize(.small)
                Text("Testing…").font(.callout).foregroundStyle(.secondary)
            case .ok:
                Label("Connection OK", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
            if supportsConnectionTest(connection) {
                Button("Test Connection") { testConnection(connection: connection) }
                    .disabled(testPhase == .testing)
            }
            Button("Save") { save(connection: connection, manifest: manifest) }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    /// The Save button is enabled only when the form has enough to configure the
    /// connection — so an empty folder path can't be "saved" into a dead state.
    private var canSave: Bool {
        guard let connection = store.connection(id: connectionID) else { return false }
        switch connection.providerID {
        case ZoteroConnection.providerID:
            let lib = formValues[ZoteroConnection.libraryIDKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let key = formValues[ZoteroConnection.apiKeyField]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !lib.isEmpty && !key.isEmpty
        default:
            return true
        }
    }

    // MARK: - Workspace mode

    @ViewBuilder
    private func workspace(connection: Connection, manifest: ProviderManifest) -> some View {
        if !isConfigured(connection) {
            notConfiguredState(manifest: manifest, connection: connection)
        } else if connection.providerID == ZoteroConnection.providerID {
            let apiKey = store.secret(for: connection, field: ZoteroConnection.apiKeyField)
            ZoteroConnectionWorkspaceView(
                store: store,
                client: ZoteroConnection.client(for: connection, apiKey: apiKey),
                zoteroDir: ZoteroConnection.zoteroDirectory(for: connection))
        } else {
            ContentUnavailableView {
                Label("Nothing to browse yet", systemImage: "tray")
            } description: {
                Text("This provider doesn't have a browse surface yet.")
            }
        }
    }

    private func notConfiguredState(manifest: ProviderManifest, connection: Connection) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Label("\(manifest.displayName) isn't set up yet", systemImage: manifest.icon)
                .font(.body)
            Text(manifest.description)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Configure…") {
                loadFormValues(connection: connection, manifest: manifest)
                isEditing = true
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Mode / form helpers

    private func initModeIfNeeded() {
        guard !didInitMode else { return }
        didInitMode = true
        guard let connection = store.connection(id: connectionID),
              let manifest = store.manifest(for: connection) else { return }
        loadFormValues(connection: connection, manifest: manifest)
        isEditing = !isConfigured(connection)
    }

    /// Seed the form from the connection's stored config + secrets.
    private func loadFormValues(connection: Connection, manifest: ProviderManifest) {
        var values = connection.config
        for field in manifest.config.fields where field.secret {
            values[field.name] = store.secret(for: connection, field: field.name) ?? ""
        }
        formValues = values
    }

    private func isConfigured(_ connection: Connection) -> Bool {
        switch connection.providerID {
        case ZoteroConnection.providerID:
            let apiKey = store.secret(for: connection, field: ZoteroConnection.apiKeyField)
            return ZoteroConnection.isConfigured(connection, apiKey: apiKey)
        default:
            return false
        }
    }

    /// Whether this provider has a credentialed endpoint worth a "Test
    /// Connection" round-trip (Zotero). A folder just needs a valid path, which
    /// the picker + `isConfigured` already enforce.
    private func supportsConnectionTest(_ connection: Connection) -> Bool {
        connection.providerID == ZoteroConnection.providerID
    }

    // MARK: - Save / Test

    private func save(connection: Connection, manifest: ProviderManifest) {
        let secretNames = manifest.config.secretFieldNames
        var updated = connection
        // Non-secret fields → connection config (drop empties to keep it tidy).
        var config: [String: String] = [:]
        for field in manifest.config.fields where !field.secret {
            let value = formValues[field.name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty { config[field.name] = value }
        }
        updated.config = config
        store.upsertConnection(updated)
        // Secret fields → Keychain.
        for name in secretNames {
            store.setSecret(formValues[name] ?? "", for: updated, field: name)
        }
        if isConfigured(updated) {
            isEditing = false
        }
    }

    private func testConnection(connection: Connection) {
        testPhase = .testing
        let apiKey = formValues[ZoteroConnection.apiKeyField]
        var probe = connection
        var config = connection.config
        config[ZoteroConnection.libraryIDKey] = formValues[ZoteroConnection.libraryIDKey]
        probe.config = config
        guard let client = ZoteroConnection.client(for: probe, apiKey: apiKey) else {
            testPhase = .failed("Enter an API key and library ID first.")
            return
        }
        Task {
            do {
                try await client.verifyConnection()
                testPhase = .ok
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                testPhase = .failed(message)
            }
        }
    }
}
