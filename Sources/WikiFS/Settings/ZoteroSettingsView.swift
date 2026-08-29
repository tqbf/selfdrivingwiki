import AppKit
import SwiftUI
import WikiFSCore

/// The app's Zotero settings — the first Settings scene in the app (`⌘,`).
/// Fields: API key (Keychain-backed), library ID, an optional override of the
/// local Zotero data directory, and a "Test Connection" button that surfaces
/// failures via `.alert`, mirroring `WikiFSApp`'s `FileProviderSetupWarning`
/// pattern.
///
/// # Credential authority (#1159, plans/credential-service.md)
/// The API key is WRITE-ONLY from this view's perspective: the field starts
/// blank, never preloads the stored key, and `credentials` (a
/// `CredentialDescribing & CredentialWriting` handle) has NO method that can
/// return a value. Saving is explicit (Save Key button); removal is explicit
/// (Remove Key) — an untouched blank field no longer means "delete".
/// "Test Connection" resolves the stored key OUTSIDE the view through the
/// host-owned `verifyConnection` action and returns only a redacted outcome.
///
/// Library ID and directory override persist immediately via `.onChange(of:)`.
struct ZoteroSettingsView: View {
    let containerDirectory: URL
    /// UI-safe credential authority: describe (configured state) + write.
    /// Deliberately NOT a `CredentialResolving` — the view cannot read values.
    let credentials: any CredentialDescribing & CredentialWriting
    /// Host-owned privileged action: resolves the stored key outside the view
    /// and verifies it. Returns `nil` on success or a redacted failure message.
    let verifyConnection: @Sendable (_ libraryID: String) async -> String?

    @State private var apiKeyText = ""
    @State private var isKeyConfigured = false
    @State private var libraryIDText = ""
    @State private var zoteroDirText = ""
    @State private var testPhase: TestPhase = .idle

    private enum TestPhase: Equatable {
        case idle
        case testing
        case succeeded
        case failed(String)
    }

    init(
        containerDirectory: URL,
        credentials: (any CredentialDescribing & CredentialWriting)? = nil,
        verifyConnection: (@Sendable (_ libraryID: String) async -> String?)? = nil,
        fetcher: any ZoteroClient.RequestFetcher = URLSessionZoteroFetcher()
    ) {
        self.containerDirectory = containerDirectory
        self.credentials = credentials ?? KeychainCredentialService()
        // Default action: host-owned privileged resolution (see
        // HostCredentialActions) — the view itself never resolves a value.
        self.verifyConnection = verifyConnection
            ?? HostCredentialActions.verifyZotero(fetcher: fetcher)
    }

    var body: some View {
        Form {
            Section {
                SecureField("API Key", text: $apiKeyText, prompt: Text(isKeyConfigured ? "Configured — enter a new key to replace" : "Enter API key"))
                    .accessibilityIdentifier("zotero.apiKey.field")
                HStack {
                    configuredStatusLabel
                    Spacer()
                    Button("Save Key") { saveCredential() }
                        .disabled(CredentialValue.normalized(apiKeyText) == nil)
                        .accessibilityIdentifier("zotero.apiKey.save")
                    Button("Remove Key", role: .destructive) { removeCredential() }
                        .disabled(!isKeyConfigured)
                        .accessibilityIdentifier("zotero.apiKey.remove")
                }
                TextField("Library ID", text: $libraryIDText)
            } header: {
                Text("Zotero Account")
            } footer: {
                Text("Generate a key at zotero.org/settings/keys. Your library ID is the numeric userID shown on that page. The key is stored in your Keychain and is never shown after you save it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    TextField(
                        "Zotero Folder", text: $zoteroDirText,
                        prompt: Text(ZoteroLocalStorage.defaultDirectory().path)
                    )
                    Button("Choose…") { chooseDirectory() }
                }
            } header: {
                Text("Local Library")
            } footer: {
                Text("Leave blank to use the default location.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                testConnectionRow
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: Metrics.width)
        .onAppear { load() }
        .alert(
            "Couldn't Connect to Zotero",
            isPresented: isShowingTestError,
            presenting: testErrorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .onChange(of: libraryIDText) { _, _ in saveConfig() }
        .onChange(of: zoteroDirText) { _, _ in saveConfig() }
    }

    /// Configured state from `CredentialDescribing` — never a value.
    private var configuredStatusLabel: some View {
        Group {
            if isKeyConfigured {
                Label("Key configured", systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
            } else {
                Text("No key stored")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .accessibilityIdentifier("zotero.apiKey.status")
    }

    // MARK: - Test Connection row

    private var testConnectionRow: some View {
        HStack(spacing: 10) {
            Button("Test Connection") { testConnection() }
                .disabled(testPhase == .testing || libraryIDText.isEmpty || !isKeyConfigured)
                .accessibilityIdentifier("zotero.testConnection")
            switch testPhase {
            case .testing:
                ProgressView().controlSize(.small)
            case .succeeded:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            case .idle, .failed:
                EmptyView()
            }
        }
    }

    private var isShowingTestError: Binding<Bool> {
        Binding(
            get: { if case .failed = testPhase { return true } else { return false } },
            set: { if !$0, case .failed = testPhase { testPhase = .idle } }
        )
    }

    private var testErrorMessage: String? {
        if case .failed(let message) = testPhase { return message }
        return nil
    }

    // MARK: - Load / save

    private func load() {
        // Write-only: the key field starts BLANK. Only the configured state
        // is read back (CredentialDescribing — no value surface).
        isKeyConfigured = credentials.describe(.zoteroAPIKey()).isConfigured
        let config = ZoteroConfig.load(from: containerDirectory)
        libraryIDText = config.libraryID ?? ""
        zoteroDirText = config.zoteroDirOverride ?? ""
    }

    /// Explicit save: normalized write (whitespace-only = no-op), then clear
    /// the draft and refresh the configured state.
    private func saveCredential() {
        let value = CredentialValue.normalized(apiKeyText)
        guard value != nil else { return }
        DebugLog.trying("set Zotero API key", operation: {
            try credentials.set(value, for: .zoteroAPIKey())
        })
        apiKeyText = ""
        isKeyConfigured = credentials.describe(.zoteroAPIKey()).isConfigured
    }

    /// Explicit removal — an untouched blank field never deletes anything.
    private func removeCredential() {
        DebugLog.trying("remove Zotero API key", operation: {
            try credentials.unset(.zoteroAPIKey())
        })
        apiKeyText = ""
        isKeyConfigured = credentials.describe(.zoteroAPIKey()).isConfigured
    }

    private func saveConfig() {
        var config = ZoteroConfig.load(from: containerDirectory)
        let trimmedLibraryID = libraryIDText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDir = zoteroDirText.trimmingCharacters(in: .whitespacesAndNewlines)
        config.libraryID = trimmedLibraryID.isEmpty ? nil : trimmedLibraryID
        config.zoteroDirOverride = trimmedDir.isEmpty ? nil : trimmedDir
        DebugLog.trying("save config", operation: { try config.save(to: containerDirectory) })
    }

    private func chooseDirectory() {
        guard let url = WikiFilePanels.chooseDirectory(
            title: "Choose Zotero Folder", prompt: "Choose"
        ) else { return }
        zoteroDirText = url.path
    }

    /// Host-owned action: the view never sees the key; the outcome is only
    /// connected / failed-with-redacted-message.
    private func testConnection() {
        let libraryID = libraryIDText.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = verifyConnection
        testPhase = .testing
        Task {
            if let failureMessage = await action(libraryID) {
                testPhase = .failed(failureMessage)
            } else {
                testPhase = .succeeded
            }
        }
    }

    private enum Metrics {
        static let width: CGFloat = 460
    }
}
