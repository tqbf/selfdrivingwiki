import AppKit
import SwiftUI
import WikiFSCore

/// The app's Zotero settings — the first Settings scene in the app (`⌘,`).
/// Fields: API key (Keychain-backed) and library ID.
///
/// Acquisition runs through the reviewed Zotero extractor package: the
/// attachment keys live in `zotero-config.json` (edited via
/// `wikictl zotero sync` today; a picker arrives with the later UI cycle),
/// and the key is resolved per operation through the seeded credential
/// authorization — this view never reads a value.
///
/// # Credential authority (#1159, plans/credential-service.md)
/// The API key is WRITE-ONLY from this view's perspective: the field starts
/// blank, never preloads the stored key, and `credentials` (a
/// `CredentialDescribing & CredentialWriting` handle) has NO method that can
/// return a value. Saving is explicit (Save Key button); removal is explicit
/// (Remove Key) — an untouched blank field never means "delete".
///
/// Library ID persists immediately via `.onChange(of:)`.
struct ZoteroSettingsView: View {
    let containerDirectory: URL
    /// UI-safe credential authority: describe (configured state) + write.
    /// Deliberately NOT a `CredentialResolving` — the view cannot read values.
    let credentials: any CredentialDescribing & CredentialWriting

    @State private var apiKeyText = ""
    @State private var isKeyConfigured = false
    @State private var libraryIDText = ""

    init(
        containerDirectory: URL,
        credentials: (any CredentialDescribing & CredentialWriting)? = nil
    ) {
        self.containerDirectory = containerDirectory
        self.credentials = credentials ?? KeychainCredentialService()
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
                Text("Generate a key at zotero.org/settings/keys. Your library ID is the numeric userID shown on that page. The key is stored in your Keychain and is never shown after you save it. Attachments sync via `wikictl zotero sync`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: Metrics.width)
        .onAppear { load() }
        .onChange(of: libraryIDText) { _, _ in saveConfig() }
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

    // MARK: - Load / save

    private func load() {
        // Write-only: the key field starts BLANK. Only the configured state
        // is read back (CredentialDescribing — no value surface).
        isKeyConfigured = credentials.describe(.zoteroAPIKey()).isConfigured
        let config = ZoteroConfig.load(from: containerDirectory)
        libraryIDText = config.libraryID ?? ""
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
        config.libraryID = trimmedLibraryID.isEmpty ? nil : trimmedLibraryID
        DebugLog.trying("save config", operation: { try config.save(to: containerDirectory) })
    }

    private enum Metrics {
        static let width: CGFloat = 460
    }
}
