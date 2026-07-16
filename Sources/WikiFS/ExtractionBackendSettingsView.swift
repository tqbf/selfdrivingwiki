import SwiftUI
import WikiFSEngine
import WikiFSCore

/// Reusable view for PDF→Markdown extraction backend selection and
/// configuration — the backend picker (Local pdf2md / Claude / Gemini /
/// Docling Serve) plus the selected backend's credentials, endpoint, and
/// Test Connection button. Extracted from `ExtractionSettingsView` so it
/// can appear both in Settings → Extraction and in the Extraction Queue
/// activity window's gear button sheet (issue #449).
///
/// Auto-saves on every edit (every field's `.onChange` calls
/// `persistAll()`), mirroring the persistence pattern of
/// `ExtractionSettingsView`. Secrets go through `ExtractionCredentialStore`
/// (Keychain), never into the JSON config file.
///
/// Only the selected backend's config section is shown — picking another
/// backend swaps the section in place, so the form stays uncluttered and
/// Test Connection is unambiguous (it always targets the visible section).
struct ExtractionBackendSettingsView: View {
    let containerDirectory: URL
    let credentialStore: any ExtractionCredentialStore
    let fetcher: any HTTPRequestFetcher
    /// Observed so the panel can lock itself while a PDF extraction is
    /// running — changing the backend or keys mid-conversion is unsafe.
    @Environment(QueueActivityTracker.self) private var tracker

    // Drafts initialized from config + Keychain in `init`; every change is
    // written straight back by `persistAll()`.
    @State private var draftBackend: ExtractionBackend
    @State private var anthropicKeyText: String
    @State private var modelText: String
    @State private var baseURLText: String
    @State private var geminiKeyText: String
    @State private var geminiModelText: String
    @State private var geminiBaseURLText: String
    @State private var doclingEndpointText: String
    @State private var doclingTokenText: String
    @State private var anthropicTest = TestPhase.idle
    @State private var geminiTest = TestPhase.idle
    @State private var doclingTest = TestPhase.idle

    private enum TestPhase: Equatable {
        case idle
        case testing
        case succeeded
        case failed(String)
    }

    init(
        containerDirectory: URL,
        credentialStore: any ExtractionCredentialStore = KeychainExtractionCredentialStore(),
        fetcher: any HTTPRequestFetcher = URLSessionRequestFetcher()
    ) {
        self.containerDirectory = containerDirectory
        self.credentialStore = credentialStore
        self.fetcher = fetcher

        // Seed the drafts once, at construction — so there's no onAppear race
        // where an `.onChange` fires before the loaded values are in place.
        let config = ExtractionConfig.load(from: containerDirectory)
        _draftBackend = State(initialValue: config.backend)
        _anthropicKeyText = State(initialValue: credentialStore.secret(.anthropicAPIKey) ?? "")
        _modelText = State(initialValue: config.anthropicModel == ExtractionConfig.defaultAnthropicModel ? "" : config.anthropicModel)
        _baseURLText = State(initialValue: config.anthropicBaseURLOverride ?? "")
        _geminiKeyText = State(initialValue: credentialStore.secret(.geminiAPIKey) ?? "")
        _geminiModelText = State(initialValue: config.geminiModel == ExtractionConfig.defaultGeminiModel ? "" : config.geminiModel)
        _geminiBaseURLText = State(initialValue: config.geminiBaseURLOverride ?? "")
        _doclingEndpointText = State(initialValue: config.doclingServeEndpoint ?? "")
        _doclingTokenText = State(initialValue: credentialStore.secret(.doclingServeToken) ?? "")
    }

    var body: some View {
        Form {
            if extractionInProgress {
                Section {
                    Label("PDF extraction is in progress. Extraction settings are locked until it finishes or is cancelled.", systemImage: "lock.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                Picker("Backend", selection: $draftBackend) {
                    ForEach(ExtractionBackend.allCases, id: \.self) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .onChange(of: draftBackend) { persistAll() }
            } header: {
                Text("PDF Extraction")
            } footer: {
                Text(draftBackend.helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Only the selected backend's config — swap in place on change.
            backendConfigSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 420)
        .disabled(extractionInProgress)
        .alert("Couldn't Connect to Claude", isPresented: anthropicErrorBinding,
               presenting: anthropicErrorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .alert("Couldn't Connect to Gemini", isPresented: geminiErrorBinding,
               presenting: geminiErrorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .alert("Couldn't Connect to Docling Serve", isPresented: doclingErrorBinding,
               presenting: doclingErrorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Selected-backend config section

    @ViewBuilder private var backendConfigSection: some View {
        switch draftBackend {
        case .localPdf2md: localSection
        case .anthropic: claudeSection
        case .gemini: geminiSection
        case .doclingServe: doclingSection
        }
    }

    @ViewBuilder private var localSection: some View {
        Section {
            Text("Local pdf2md runs on-device via the bundled docling + granite VLM. It needs a one-time ~2 GB dependency download, triggered from the ingest flow the first time you extract a PDF. There's nothing to configure here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Local pdf2md")
        }
    }

    // MARK: - Claude section

    @ViewBuilder private var claudeSection: some View {
        Section {
            SecureField("API Key", text: $anthropicKeyText)
                .onChange(of: anthropicKeyText) { persistAll() }
            TextField("Model", text: $modelText, prompt: Text(ExtractionConfig.defaultAnthropicModel))
                .onChange(of: modelText) { persistAll() }
            TextField("Base URL", text: $baseURLText, prompt: Text(ExtractionConfig.defaultAnthropicBaseURL))
                .onChange(of: baseURLText) { persistAll() }
            testConnectionRow(phase: $anthropicTest, action: testAnthropic)
        } header: {
            Text("Claude (Anthropic API)")
        } footer: {
            Text("Get a key at console.anthropic.com (separate billing from a Claude subscription). The PDF leaves your Mac. Default is Sonnet 4.6 — a good fidelity/cost balance for transcription. Switch to Haiku 4.5 (cheapest) or Opus (hardest layouts).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Gemini section

    @ViewBuilder private var geminiSection: some View {
        Section {
            SecureField("API Key", text: $geminiKeyText)
                .onChange(of: geminiKeyText) { persistAll() }
            TextField("Model", text: $geminiModelText, prompt: Text(ExtractionConfig.defaultGeminiModel))
                .onChange(of: geminiModelText) { persistAll() }
            TextField("Base URL", text: $geminiBaseURLText, prompt: Text(ExtractionConfig.defaultGeminiBaseURL))
                .onChange(of: geminiBaseURLText) { persistAll() }
            testConnectionRow(phase: $geminiTest, action: testGemini)
        } header: {
            Text("Gemini (Google AI)")
        } footer: {
            Text("Get a key at aistudio.google.com. Has a free tier (rate-limited); the PDF leaves your Mac. Default is gemini-3.5-flash (good fidelity/cost). Flash-Lite is cheapest with the most generous free limits but weaker on complex layouts; Pro is most capable.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Docling section

    @ViewBuilder private var doclingSection: some View {
        Section {
            TextField("Endpoint", text: $doclingEndpointText, prompt: Text(ExtractionConfig.defaultDoclingServeEndpoint))
                .onChange(of: doclingEndpointText) { persistAll() }
            SecureField("API Token (optional)", text: $doclingTokenText)
                .onChange(of: doclingTokenText) { persistAll() }
            testConnectionRow(phase: $doclingTest, action: testDocling)
        } header: {
            Text("Docling Serve")
        } footer: {
            Text("Run `docling-serve run` locally, then point this at its base URL. Private to your network. The token is only needed if the server was started with DOCLING_SERVE_API_KEY.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Test Connection row (shared by all backends)

    @ViewBuilder
    private func testConnectionRow(phase: Binding<TestPhase>, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Button("Test Connection", action: action)
                .disabled(phase.wrappedValue == .testing)
            switch phase.wrappedValue {
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

    private var anthropicErrorBinding: Binding<Bool> {
        Binding(get: { if case .failed = anthropicTest { return true } else { return false } },
                set: { if !$0, case .failed = anthropicTest { anthropicTest = .idle } })
    }
    private var anthropicErrorMessage: String? {
        if case .failed(let m) = anthropicTest { return m }; return nil
    }
    private var geminiErrorBinding: Binding<Bool> {
        Binding(get: { if case .failed = geminiTest { return true } else { return false } },
                set: { if !$0, case .failed = geminiTest { geminiTest = .idle } })
    }
    private var geminiErrorMessage: String? {
        if case .failed(let m) = geminiTest { return m }; return nil
    }
    private var doclingErrorBinding: Binding<Bool> {
        Binding(get: { if case .failed = doclingTest { return true } else { return false } },
                set: { if !$0, case .failed = doclingTest { doclingTest = .idle } })
    }
    private var doclingErrorMessage: String? {
        if case .failed(let m) = doclingTest { return m }; return nil
    }

    /// True while a PDF extraction holds the slot (ingest-path or standalone).
    /// While busy the whole panel is disabled so a mid-extraction backend or key
    /// change can't derail the running conversion.
    private var extractionInProgress: Bool {
        !tracker.extractingSourceIDs.isEmpty
    }

    // MARK: - Auto-save

    /// Persist every non-secret draft into `ExtractionConfig` and every secret
    /// into Keychain. Called from each field's `.onChange`, so the panel is
    /// always up to date — no Save button, no lost-on-close window.
    private func persistAll() {
        var config = ExtractionConfig.load(from: containerDirectory)
        writeConfig(into: &config)
        try? config.save(to: containerDirectory)

        try? credentialStore.setSecret(anthropicKeyText.isEmpty ? nil : anthropicKeyText, .anthropicAPIKey)
        try? credentialStore.setSecret(geminiKeyText.isEmpty ? nil : geminiKeyText, .geminiAPIKey)
        try? credentialStore.setSecret(doclingTokenText.isEmpty ? nil : doclingTokenText, .doclingServeToken)
    }

    /// Write every non-secret draft into `config`.
    private func writeConfig(into config: inout ExtractionConfig) {
        config.backend = draftBackend
        let model = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
        config.anthropicModel = model.isEmpty ? ExtractionConfig.defaultAnthropicModel : model
        let baseURL = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        config.anthropicBaseURLOverride = baseURL.isEmpty ? nil : baseURL
        let geminiModel = geminiModelText.trimmingCharacters(in: .whitespacesAndNewlines)
        config.geminiModel = geminiModel.isEmpty ? ExtractionConfig.defaultGeminiModel : geminiModel
        let geminiBase = geminiBaseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        config.geminiBaseURLOverride = geminiBase.isEmpty ? nil : geminiBase
        let endpoint = doclingEndpointText.trimmingCharacters(in: .whitespacesAndNewlines)
        config.doclingServeEndpoint = endpoint.isEmpty ? nil : endpoint
    }

    // MARK: - Test Connection (per backend). Drafts are already persisted by
    // auto-save; each probe just builds a client from the live fields.

    private func testAnthropic() {
        anthropicTest = .testing
        let model = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = URL(string: baseURLText.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? URL(string: ExtractionConfig.defaultAnthropicBaseURL)!
        let client = AnthropicExtractionClient(
            model: model.isEmpty ? ExtractionConfig.defaultAnthropicModel : model,
            apiKey: anthropicKeyText,
            baseURL: baseURL,
            fetcher: fetcher)
        Task {
            do {
                try await client.verifyConnection()
                anthropicTest = .succeeded
            } catch {
                anthropicTest = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func testGemini() {
        geminiTest = .testing
        let model = geminiModelText.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = URL(string: geminiBaseURLText.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? URL(string: ExtractionConfig.defaultGeminiBaseURL)!
        let client = GeminiExtractionClient(
            model: model.isEmpty ? ExtractionConfig.defaultGeminiModel : model,
            apiKey: geminiKeyText,
            baseURL: baseURL,
            fetcher: fetcher)
        Task {
            do {
                try await client.verifyConnection()
                geminiTest = .succeeded
            } catch {
                geminiTest = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func testDocling() {
        doclingTest = .testing
        let endpoint = doclingEndpointText.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = DoclingServeClient(
            endpoint: endpoint, apiToken: doclingTokenText, fetcher: fetcher)
        Task {
            do {
                try await client.verifyConnection()
                doclingTest = .succeeded
            } catch {
                doclingTest = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }
}
