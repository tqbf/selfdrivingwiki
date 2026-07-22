import SwiftUI
import WikiFSEngine
import WikiFSCore
import WikiFSEngine

/// Settings for PDF→Markdown extraction — the second Settings scene tab. Picks
/// the backend (Local pdf2md / Claude / Gemini / Docling Serve) and configures
/// the selected backend's credentials + endpoint. Mirrors `ZoteroSettingsView`
/// for structure (secrets in Keychain, non-secret prefs in `ExtractionConfig`)
/// but **auto-saves on change** instead of an explicit Save button: every edit
/// persists immediately, so closing the window can never drop a just-typed value
/// (the failure mode a focus-loss/Save pattern risks).
///
/// Only the selected backend's config section is shown — picking another backend
/// swaps the section in place, so the form stays uncluttered and Test Connection
/// is unambiguous (it always targets the visible section).
struct ExtractionSettingsView: View {
    let containerDirectory: URL
    let credentialStore: any ExtractionCredentialStore
    let fetcher: any HTTPRequestFetcher
    /// Observed so the panel can lock itself while a PDF extraction is running —
    /// changing the backend or keys mid-conversion is unsafe.
    let launcher: AgentLauncher
    @Environment(QueueActivityTracker.self) private var tracker

    // Drafts initialized from config + Keychain in `init`; every change is
    // written straight back by `persistAll()`.
    @State private var draftBackend: ExtractionBackend
    @State private var acpProviderSelection: String
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
    // Issue #799 PR1: HTML + Podcast backend drafts (optional — nil = no
    // default yet, user is prompted to pick on first extraction). Seeded from
    // `ExtractionConfig` in `init`, written back in `writeConfig`.
    @State private var draftHtmlBackend: HtmlExtractionBackend?
    @State private var draftPodcastBackend: PodcastTranscriptionBackend?

    private enum TestPhase: Equatable {
        case idle
        case testing
        case succeeded
        case failed(String)
    }

    init(
        containerDirectory: URL,
        launcher: AgentLauncher,
        credentialStore: any ExtractionCredentialStore = KeychainExtractionCredentialStore(),
        fetcher: any HTTPRequestFetcher = URLSessionRequestFetcher()
    ) {
        self.containerDirectory = containerDirectory
        self.launcher = launcher
        self.credentialStore = credentialStore
        self.fetcher = fetcher

        // Seed the drafts once, at construction — so there's no onAppear race
        // where an `.onChange` fires before the loaded values are in place.
        let config = ExtractionConfig.load(from: containerDirectory)
        _draftBackend = State(initialValue: config.backend)
        _acpProviderSelection = State(initialValue: config.acpProviderId ?? "")
        _anthropicKeyText = State(initialValue: credentialStore.secret(.anthropicAPIKey) ?? "")
        _modelText = State(initialValue: config.anthropicModel == ExtractionConfig.defaultAnthropicModel ? "" : config.anthropicModel)
        _baseURLText = State(initialValue: config.anthropicBaseURLOverride ?? "")
        _geminiKeyText = State(initialValue: credentialStore.secret(.geminiAPIKey) ?? "")
        _geminiModelText = State(initialValue: config.geminiModel == ExtractionConfig.defaultGeminiModel ? "" : config.geminiModel)
        _geminiBaseURLText = State(initialValue: config.geminiBaseURLOverride ?? "")
        _doclingEndpointText = State(initialValue: config.doclingServeEndpoint ?? "")
        _doclingTokenText = State(initialValue: credentialStore.secret(.doclingServeToken) ?? "")
        _draftHtmlBackend = State(initialValue: config.htmlBackend)
        _draftPodcastBackend = State(initialValue: config.podcastBackend)
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

            // Issue #799 PR1: HTML + Podcast backend pickers. These are
            // scaffolding only — the trigger UI (PR2) and the removal of
            // auto-extraction at ingest (PR3) land in later PRs. The user
            // picks a default here so the eventual trigger has a backend
            // to run without prompting each time; nil = "prompt me".
            Section {
                Picker("Backend", selection: htmlBackendBinding) {
                    Text("Prompt me when extracting").tag(nil as HtmlExtractionBackend?)
                    ForEach(HtmlExtractionBackend.allCases, id: \.self) { backend in
                        Text(backend.displayName).tag(backend as HtmlExtractionBackend?)
                    }
                }
                .onChange(of: draftHtmlBackend) { persistAll() }
            } header: {
                Text("HTML Extraction")
            } footer: {
                Text("The backend to use when extracting an HTML source to markdown. Defuddle runs the bundled article-extraction binary; tag-based is built-in and always available but lower fidelity. Extraction still runs automatically at ingest for now (PR3 removes that).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Backend", selection: podcastBackendBinding) {
                    Text("Prompt me when transcribing").tag(nil as PodcastTranscriptionBackend?)
                    ForEach(PodcastTranscriptionBackend.allCases, id: \.self) { backend in
                        Text(backend.displayName).tag(backend as PodcastTranscriptionBackend?)
                    }
                }
                .onChange(of: draftPodcastBackend) { persistAll() }
            } header: {
                Text("Podcast Transcription")
            } footer: {
                Text("The backend to use when transcribing a podcast episode. Apple Podcasts transcript fetches the transcript over the network (requires the bundled signing helper — disabled in app-store builds). Transcription still runs automatically at ingest for now (PR4 removes that).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Only the selected backend's config — swap in place on change.
            backendConfigSection
        }
        .formStyle(.grouped)
        .frame(minWidth: Metrics.width, minHeight: Metrics.height)
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
        case .acp: acpSection
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

    // MARK: - ACP Provider section

    @ViewBuilder private var acpSection: some View {
        Section {
            Picker("Provider", selection: $acpProviderSelection) {
                Text("Default (use app's default provider)").tag("")
                ForEach(launcher.providersConfig().enabledProviders, id: \.id) { provider in
                    Text(provider.label).tag(provider.id)
                }
            }
            .onChange(of: acpProviderSelection) { persistAll() }
        } header: {
            Text("ACP Provider")
        } footer: {
            Text("Delegates PDF extraction to your configured ACP provider. Reuses the API key from Settings → Agents — no separate credentials needed. The provider reads the PDF from disk and returns markdown. Choose \"Default\" to use the same provider as chat and ingest.")
                .font(.caption)
                .foregroundStyle(.secondary)
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

    /// `Picker`'s `selection:` can't bind directly to `@State var x: T?` when
    /// the option set includes a "no default" nil tag — wrap it so SwiftUI gets
    /// a plain `Binding<HtmlExtractionBackend?>` it can read/write. Writing
    /// through the binding updates `draftHtmlBackend`, which `.onChange` watches
    /// to trigger `persistAll()` — same auto-save flow as every other field.
    private var htmlBackendBinding: Binding<HtmlExtractionBackend?> {
        Binding(
            get: { draftHtmlBackend },
            set: { draftHtmlBackend = $0 })
    }

    private var podcastBackendBinding: Binding<PodcastTranscriptionBackend?> {
        Binding(
            get: { draftPodcastBackend },
            set: { draftPodcastBackend = $0 })
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
        config.acpProviderId = acpProviderSelection.isEmpty ? nil : acpProviderSelection
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
        config.htmlBackend = draftHtmlBackend
        config.podcastBackend = draftPodcastBackend
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

    private enum Metrics {
        static let width: CGFloat = 460
        /// A fixed height tall enough for the multi-line footers and so that
        /// switching backends (sections of different heights) doesn't resize
        /// the window. A short section just leaves space below it.
        static let height: CGFloat = 420
    }
}
