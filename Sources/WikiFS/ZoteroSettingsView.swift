import AppKit
import SwiftUI
import WikiFSCore

/// The app's Zotero settings — the first Settings scene in the app (`⌘,`).
/// Fields: API key (Keychain-backed), library ID, an optional override of the
/// local Zotero data directory, and a "Test Connection" button that surfaces
/// failures via `.alert`, mirroring `WikiFSApp`'s `FileProviderSetupWarning`
/// pattern.
///
/// Changes persist immediately via `.onChange(of:)` — no explicit save step.
/// The Keychain-backed API key is written on every keystroke; the config JSON
/// is written whenever the library ID or directory override change.
struct ZoteroSettingsView: View {
    let containerDirectory: URL
    let credentialStore: any ZoteroCredentialStore
    let fetcher: any ZoteroClient.RequestFetcher

    @State private var apiKeyText = ""
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
        credentialStore: any ZoteroCredentialStore = KeychainZoteroCredentialStore(),
        fetcher: any ZoteroClient.RequestFetcher = URLSessionZoteroFetcher()
    ) {
        self.containerDirectory = containerDirectory
        self.credentialStore = credentialStore
        self.fetcher = fetcher
    }

    var body: some View {
        Form {
            Section {
                SecureField("API Key", text: $apiKeyText)
                TextField("Library ID", text: $libraryIDText)
            } header: {
                Text("Zotero Account")
            } footer: {
                Text("Generate a key at zotero.org/settings/keys. Your library ID is the numeric userID shown on that page.")
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
        .frame(width: Metrics.width)
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
        .onChange(of: apiKeyText) { _, _ in saveCredential() }
        .onChange(of: libraryIDText) { _, _ in saveConfig() }
        .onChange(of: zoteroDirText) { _, _ in saveConfig() }
    }

    // MARK: - Test Connection row

    private var testConnectionRow: some View {
        HStack(spacing: 10) {
            Button("Test Connection") { testConnection() }
                .disabled(testPhase == .testing || libraryIDText.isEmpty || apiKeyText.isEmpty)
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
        apiKeyText = credentialStore.apiKey() ?? ""
        let config = ZoteroConfig.load(from: containerDirectory)
        libraryIDText = config.libraryID ?? ""
        zoteroDirText = config.zoteroDirOverride ?? ""
    }

    private func saveCredential() {
        try? credentialStore.setAPIKey(apiKeyText.isEmpty ? nil : apiKeyText)
    }

    private func saveConfig() {
        var config = ZoteroConfig.load(from: containerDirectory)
        let trimmedLibraryID = libraryIDText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDir = zoteroDirText.trimmingCharacters(in: .whitespacesAndNewlines)
        config.libraryID = trimmedLibraryID.isEmpty ? nil : trimmedLibraryID
        config.zoteroDirOverride = trimmedDir.isEmpty ? nil : trimmedDir
        try? config.save(to: containerDirectory)
    }

    private func chooseDirectory() {
        guard let url = WikiFilePanels.chooseDirectory(
            title: "Choose Zotero Folder", prompt: "Choose"
        ) else { return }
        zoteroDirText = url.path
    }

    private func testConnection() {
        let config = ZoteroClient.Config(
            libraryID: libraryIDText.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKeyText)
        let client = ZoteroClient(config: config, fetcher: fetcher)
        testPhase = .testing
        Task {
            do {
                try await client.verifyConnection()
                testPhase = .succeeded
            } catch {
                let message = (error as? ZoteroClient.ZoteroError)?.errorDescription
                    ?? error.localizedDescription
                testPhase = .failed(message)
            }
        }
    }

    private enum Metrics {
        static let width: CGFloat = 420
    }
}
