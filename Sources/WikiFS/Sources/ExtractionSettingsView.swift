import AppKit
import SwiftUI
import WikiFSEngine
import WikiFSCore
import WikiFSTypes

/// Settings for source extraction. Unified PDF and HTML extractor pickers list
/// reviewed packages, installed packages, built-in adapters, and connected
/// services without exposing the legacy backend/package precedence. Mirrors `ZoteroSettingsView`
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
    /// Provides the enabled-provider list for the ACP backend picker.
    let launcher: AgentLauncher
    /// Loads the installed-package lifecycle snapshot (active registrations +
    /// failed activations + applied generation) from the process extraction
    /// context. Nil (tests, headless hosts) hides the package section entirely —
    /// the app process wires the context in.
    let packageSnapshot: (@Sendable () async -> ExtractorPackageSettingsSnapshot)?
    /// Installs one local package directory into the extractor store. App-only:
    /// the catalog writer rejects non-app roles, and only the app wiring
    /// supplies this closure. Nil hides the import affordance (read-only view).
    let importPackage: (@Sendable (URL) async -> ExtractorPackageMutationOutcome)?
    /// Removes one exact revision from the extractor store. Same app-only rule
    /// as `importPackage`. Nil hides the Remove buttons.
    let removePackage: (@Sendable (ExtractorPackageRevisionID) async -> ExtractorPackageMutationOutcome)?

    // Drafts initialized from config + Keychain in `init`; every change is
    // written straight back by `persistAll()`.
    @State private var pdfExtractorSelection: PDFExtractorSettingsSelection
    @State private var acpProviderSelection: String
    @State private var doclingEndpointText: String
    @State private var doclingTokenText: String
    @State private var doclingTest = TestPhase.idle
    // Issue #799 PR1: HTML + Podcast backend drafts (optional — nil = no
    // default yet, user is prompted to pick on first extraction). Seeded from
    // `ExtractionConfig` in `init`, written back in `writeConfig`.
    @State private var htmlExtractorSelection: HTMLExtractorSettingsSelection
    @State private var draftPodcastBackend: PodcastTranscriptionBackend?
    // Installed-package lifecycle (dynamic-extractor-packages Phase 7).
    @State private var packageModel: ExtractorPackageSettingsModel
    @State private var showingImportPicker = false
    @State private var removalCandidate: ExtractorPackageSettingsRow?

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
        fetcher: any HTTPRequestFetcher = URLSessionRequestFetcher(),
        packageSnapshot: (@Sendable () async -> ExtractorPackageSettingsSnapshot)? = nil,
        importPackage: (@Sendable (URL) async -> ExtractorPackageMutationOutcome)? = nil,
        removePackage: (@Sendable (ExtractorPackageRevisionID) async -> ExtractorPackageMutationOutcome)? = nil
    ) {
        self.containerDirectory = containerDirectory
        self.launcher = launcher
        self.credentialStore = credentialStore
        self.fetcher = fetcher
        self.packageSnapshot = packageSnapshot
        self.importPackage = importPackage
        self.removePackage = removePackage

        // Seed the drafts once, at construction — so there's no onAppear race
        // where an `.onChange` fires before the loaded values are in place.
        let config = ExtractionConfig.load(from: containerDirectory)
        _pdfExtractorSelection = State(initialValue: ExtractorSettingsSelectionMapping.pdfSelection(from: config))
        _acpProviderSelection = State(initialValue: ExtractorSettingsSelectionMapping.acpProviderSelection(from: config))
        _doclingEndpointText = State(initialValue: config.doclingServeEndpoint ?? "")
        _doclingTokenText = State(initialValue: credentialStore.secret(.doclingServeToken) ?? "")
        _htmlExtractorSelection = State(initialValue: ExtractorSettingsSelectionMapping.htmlSelection(from: config))
        _draftPodcastBackend = State(initialValue: config.podcastBackend)
        _packageModel = State(initialValue: ExtractorPackageSettingsModel(
            loadSnapshot: packageSnapshot,
            importPackage: importPackage,
            removePackage: removePackage))
    }

    var body: some View {
        Form {
            Section {
                unifiedPDFExtractorPicker
                unifiedHTMLExtractorPicker

                Picker("Podcast Transcript", selection: podcastBackendBinding) {
                    Text("Prompt me when transcribing").tag(nil as PodcastTranscriptionBackend?)
                    ForEach(PodcastTranscriptionBackend.allCases, id: \.self) { backend in
                        Text(backend.displayName).tag(backend as PodcastTranscriptionBackend?)
                    }
                }
                .onChange(of: draftPodcastBackend) { persistAll() }
                .accessibilityLabel("Default podcast transcript extractor")
            } header: {
                Text("Default Extractors")
            } footer: {
                Text("Reviewed packages run outside the app through the extractor protocol. Installed packages are local additions. Connected services use host-managed providers. Podcast transcripts are not package-backed in protocol revision 1.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Only a selected host service needs configuration here. Package
            // readiness and lifecycle belong to the package management section.
            backendConfigSection

            // Installed extractor-package lifecycle (Phase 7): read-only list
            // of exact registry admissions with progressive disclosure, plus
            // app-only import/removal. Hidden when no snapshot loader was
            // wired (tests, headless hosts).
            if packageSnapshot != nil {
                installedPackagesSection
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: Metrics.width, minHeight: Metrics.height)
        // Async model mutations stay on the main actor; the load closure hops
        // to the process registry off-main and returns a value snapshot.
        .task { await packageModel.refresh() }
        .alert("Couldn't Connect to Docling Serve", isPresented: doclingErrorBinding,
               presenting: doclingErrorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .confirmationDialog(
            "Remove extractor package?",
            isPresented: Binding(
                get: { removalCandidate != nil },
                set: { if !$0 { removalCandidate = nil } }),
            titleVisibility: .visible,
            presenting: removalCandidate) { row in
                Button("Remove Package", role: .destructive) {
                    removalCandidate = nil
                    Task { await packageModel.remove(row) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { row in
                Text("Remove \(row.packageID) \(row.version) from this Mac? Its registrations fall back to the built-in backends. A default selection that points at this package keeps falling back until you change it.")
            }
        .onChange(of: showingImportPicker) { _, isPresented in
            guard isPresented else { return }
            let panel = ExtractorSettingsPackagePicker.makePanel()
            panel.begin { response in
                showingImportPicker = false
                guard response == .OK else { return }
                do {
                    let directory = try ExtractorSettingsPackagePicker.selectedDirectory(from: panel)
                    Task { await packageModel.importPackage(from: directory) }
                } catch {
                    packageModel.reportImportSelectionError()
                }
            }
        }
        .onChange(of: packageModel.isBusy) { _, isBusy in
            if isBusy, let message = packageModel.busyMessage {
                announceAccessibility(message)
            }
        }
        .onChange(of: packageModel.lastError) { _, error in
            if let error {
                announceAccessibility("Extractor package operation failed. \(error)")
            }
        }
        .onChange(of: packageModel.lastDiagnostic) { _, diagnostic in
            if let diagnostic {
                announceAccessibility(diagnostic)
            }
        }
    }

    // MARK: - Unified extractor selection

    private var unifiedPDFExtractorPicker: some View {
        Picker("PDF", selection: $pdfExtractorSelection) {
            extractorOption("pdf2md", source: "Reviewed package")
                .tag(PDFExtractorSettingsSelection.reviewedPdf2md)
            ForEach(pdfPackageChoices) { choice in
                extractorOption(choice.packageID, source: "Installed package")
                    .tag(PDFExtractorSettingsSelection.installed(choice.logical))
            }
            stalePDFSelectionOption
            Divider()
            extractorOption("ACP Provider", source: "Connected service")
                .tag(PDFExtractorSettingsSelection.host(.acp))
            extractorOption("Docling Serve", source: "Connected service")
                .tag(PDFExtractorSettingsSelection.host(.doclingServe))
        }
        .onChange(of: pdfExtractorSelection) { _, _ in persistAll() }
        .accessibilityIdentifier(PackageAccessibility.pdfSelection)
        .accessibilityLabel("Default PDF extractor")
    }

    private var unifiedHTMLExtractorPicker: some View {
        Picker("HTML", selection: $htmlExtractorSelection) {
            Text("Prompt me when extracting")
                .tag(HTMLExtractorSettingsSelection.prompt)
            extractorOption("Defuddle", source: "Reviewed package")
                .tag(HTMLExtractorSettingsSelection.reviewedDefuddle)
            ForEach(htmlPackageChoices) { choice in
                extractorOption(choice.packageID, source: "Installed package")
                    .tag(HTMLExtractorSettingsSelection.installed(choice.logical))
            }
            staleHTMLSelectionOption
            Divider()
            extractorOption("Tag-based", source: "Built in")
                .tag(HTMLExtractorSettingsSelection.host(.tagBased))
        }
        .onChange(of: htmlExtractorSelection) { _, _ in persistAll() }
        .accessibilityIdentifier(PackageAccessibility.htmlSelection)
        .accessibilityLabel("Default HTML extractor")
    }

    private func extractorOption(_ name: String, source: String) -> Text {
        Text("\(name) — \(source)")
    }

    @ViewBuilder private var stalePDFSelectionOption: some View {
        if packageModel.hasLoaded,
           case .installed(let logical) = pdfExtractorSelection,
           pdfPackageChoices.contains(where: { $0.logical == logical }) == false {
            Text("\(logical.packageID.rawValue) — Not installed")
                .tag(pdfExtractorSelection)
                .accessibilityIdentifier("\(PackageAccessibility.staleSelection).pdf")
                .accessibilityValue("Not installed. Reviewed pdf2md fallback is active")
        }
    }

    @ViewBuilder private var staleHTMLSelectionOption: some View {
        if packageModel.hasLoaded,
           case .installed(let logical) = htmlExtractorSelection,
           htmlPackageChoices.contains(where: { $0.logical == logical }) == false {
            Text("\(logical.packageID.rawValue) — Not installed")
                .tag(htmlExtractorSelection)
                .accessibilityIdentifier("\(PackageAccessibility.staleSelection).html")
                .accessibilityValue("Not installed. Tag-based fallback is active")
        }
    }

    private var pdfPackageChoices: [ExtractorPackageChoice] {
        choices(for: .pdf).filter { $0.logical != ProcessExtractionServices.reviewedPDFLogical }
    }

    private var htmlPackageChoices: [ExtractorPackageChoice] {
        choices(for: .html).filter { $0.logical != ProcessExtractionServices.reviewedHTMLLogical }
    }

    // MARK: - Selected service configuration

    @ViewBuilder private var backendConfigSection: some View {
        switch pdfExtractorSelection {
        case .host(.acp): acpSection
        case .host(.doclingServe): doclingSection
        case .host(.anthropic), .host(.gemini), .host(.localPdf2md), .reviewedPdf2md, .installed:
            EmptyView()
        }
    }

    // MARK: - Installed extractor packages (Phase 7)

    /// Lifecycle list of the process registry's installed exact registrations,
    /// packages that failed to activate, app-only import + removal, and the
    /// per-kind default package selection persisted into `ExtractionConfig`.
    /// Each control carries a stable accessibility identifier, an accessible
    /// name, and a state value (Phase 7.10); the contract test asserts these
    /// strings exist.
    @ViewBuilder private var installedPackagesSection: some View {
        Section {
            Button {
                Task { await packageModel.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(packageModel.isBusy)
            .accessibilityIdentifier(PackageAccessibility.refreshButton)
            .accessibilityLabel("Refresh installed extractor packages")

            if packageModel.canImport {
                DisclosureGroup {
                    importDisclosureContent
                } label: {
                    Text(ExtractorSettingsPackagePicker.disclosureTitle)
                }
                .accessibilityIdentifier(PackageAccessibility.importDisclosure)
                .accessibilityLabel("Advanced local extractor package import")
            }

            if packageModel.isBusy {
                ProgressView(packageModel.busyMessage ?? ExtractorPackageSettingsModel.checkingMessage)
                    .controlSize(.small)
                    .accessibilityIdentifier(PackageAccessibility.progress)
                    .accessibilityLabel(packageModel.busyMessage ?? "Working on extractor packages")
                    .accessibilityAddTraits(.updatesFrequently)
            }

            if packageModel.snapshot.rows.isEmpty && packageModel.snapshot.failedPackages.isEmpty {
                Text(packageModel.hasLoaded
                    ? "No extractor packages are installed on this Mac."
                    : "Checking installed extractor packages…")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(PackageAccessibility.emptyState)
            } else {
                ForEach(packageModel.snapshot.rows) { row in
                    packageRow(row)
                }
                ForEach(packageModel.snapshot.failedPackages) { failure in
                    failedPackageRow(failure)
                }
            }

            if let diagnostic = packageModel.lastDiagnostic {
                Label(diagnostic, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(PackageAccessibility.diagnostic)
            }
            if let error = packageModel.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier(PackageAccessibility.error)
                    .accessibilityLabel("Extractor package operation failed. \(error)")
            }
        } header: {
            Text("Installed Extractor Packages")
        } footer: {
            Text("Manage exact validated package revisions available on this Mac. Choose defaults in the Default Extractors section above.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The import disclosure's body: the local-directory contract, the
    /// executable-code trust warning, and the import button. Local directories
    /// only — the panel refuses files, and the boundary revalidates every
    /// accepted selection.
    @ViewBuilder private var importDisclosureContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ExtractorSettingsPackagePicker.localImportSourceMessage)
            Text(ExtractorSettingsPackagePicker.localImportStorageMessage)
            Text(ExtractorSettingsPackagePicker.localImportAfterMessage)
            Text(ExtractorSettingsPackagePicker.filesUnsupportedMessage)
            Label(Self.trustWarningMessage, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityIdentifier(PackageAccessibility.trustWarning)
                .accessibilityLabel("Executable code warning. \(Self.trustWarningMessage)")
            Button(ExtractorSettingsPackagePicker.importButtonTitle, systemImage: "square.and.arrow.down") {
                showingImportPicker = true
            }
            .disabled(packageModel.isBusy)
            .accessibilityIdentifier(PackageAccessibility.importButton)
            .accessibilityLabel("Import a local extractor package folder")
        }
        .font(.caption)
    }

    @ViewBuilder private func packageRow(_ row: ExtractorPackageSettingsRow) -> some View {
        DisclosureGroup {
            LabeledContent("Kind", value: kindDisplayName(row.kind))
                .font(.caption)
            LabeledContent("Digest", value: row.digestPrefix)
                .font(.caption)
                .accessibilityIdentifier("\(PackageAccessibility.digestPrefix).\(row.id)")
            LabeledContent("Registration", value: row.registrationID)
                .font(.caption)
                .accessibilityIdentifier("\(PackageAccessibility.registrationPrefix).\(row.id)")
            if packageModel.canRemove {
                HStack {
                    Spacer()
                    Button("Remove Package…", role: .destructive) {
                        removalCandidate = row
                    }
                    .disabled(packageModel.isBusy)
                    .accessibilityIdentifier("\(PackageAccessibility.removePrefix).\(row.id)")
                    .accessibilityLabel("Remove \(row.packageID), version \(row.version)")
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.packageID)
                Text("version \(row.version), \(kindDisplayName(row.kind))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("\(PackageAccessibility.rowPrefix).\(row.id)")
        .accessibilityLabel("\(row.packageID), version \(row.version), for \(kindDisplayName(row.kind))")
        .accessibilityValue("Active")
    }

    /// A catalog revision whose activation failed in this process. It occupies
    /// the store but resolved to no backend, so it shows its redacted failure
    /// message and a "Not ready" state instead of an Active row.
    @ViewBuilder private func failedPackageRow(_ failure: ExtractorPackageFailureSummary) -> some View {
        DisclosureGroup {
            Text(failure.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .accessibilityIdentifier("\(PackageAccessibility.failureMessagePrefix).\(failure.id)")
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(failure.packageID)
                Text("version \(failure.version), not ready")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("\(PackageAccessibility.failurePrefix).\(failure.id)")
        .accessibilityLabel("\(failure.packageID), version \(failure.version), failed to activate")
        .accessibilityValue("Not ready")
    }

    /// Unique installed logical references for one kind, built from the active
    /// registration rows. Identity is package + registration (version-free);
    /// the resolver picks the highest compatible exact revision at run time.
    private func choices(for kind: ExtractionBackendKind) -> [ExtractorPackageChoice] {
        var seen: Set<String> = []
        var result: [ExtractorPackageChoice] = []
        for row in packageModel.snapshot.rows where row.kind == kind {
            guard let packageID = ExtractorPackageID(rawValue: row.packageID),
                  let registrationID = ExtractorRegistrationID(rawValue: row.registrationID)
            else { continue }
            let key = "\(row.packageID)/\(row.registrationID)"
            guard seen.insert(key).inserted else { continue }
            result.append(ExtractorPackageChoice(
                logical: LogicalExtractorReference(
                    packageID: packageID,
                    registrationID: registrationID),
                packageID: row.packageID,
                registrationID: row.registrationID))
        }
        return result
    }

    private func kindDisplayName(_ kind: ExtractionBackendKind) -> String {
        switch kind {
        case .pdf: "PDF"
        case .html: "HTML"
        default: kind.rawValue
        }
    }

    /// The executable-code disclosure shown before any local import.
    static let trustWarningMessage = "Extractor packages contain executable code that runs with this app's permissions on your user account. Import only packages you trust. The app's lifecycle and capability controls do not create a security sandbox."

    /// Stable accessibility identifiers for the package lifecycle controls.
    /// Row/digest/registration/remove/failure identifiers append the row's
    /// `id` so each exact revision has a unique, derivable identifier.
    private enum PackageAccessibility {
        static let refreshButton = "extraction.packages.refresh"
        static let emptyState = "extraction.packages.empty"
        static let rowPrefix = "extraction.packages.row"
        static let digestPrefix = "extraction.packages.digest"
        static let registrationPrefix = "extraction.packages.registration"
        static let importDisclosure = "extraction.packages.import.disclosure"
        static let importButton = "extraction.packages.import.button"
        static let trustWarning = "extraction.packages.import.trust"
        static let removePrefix = "extraction.packages.remove"
        static let failurePrefix = "extraction.packages.failure"
        static let failureMessagePrefix = "extraction.packages.failure.message"
        static let pdfSelection = "extraction.packages.selection.pdf"
        static let htmlSelection = "extraction.packages.selection.html"
        static let staleSelection = "extraction.packages.selection.stale"
        static let progress = "extraction.packages.progress"
        static let diagnostic = "extraction.packages.diagnostic"
        static let error = "extraction.packages.error"
    }

    // MARK: - ACP Provider section

    @ViewBuilder private var acpSection: some View {
        Section {
            Picker("Provider", selection: $acpProviderSelection) {
                Text("Default (use app's default provider)").tag("")
                ForEach(launcher.providersConfig().enabledProviders, id: \.id) { provider in
                    Text(provider.label).tag(provider.id.rawValue)
                }
            }
            .onChange(of: acpProviderSelection) { persistAll() }
        } header: {
            Text("ACP Provider")
        } footer: {
            Text("Delegates PDF extraction to your configured ACP provider. Reuses the API key from Settings → Providers — no separate credentials needed. The provider reads the PDF from disk and returns markdown. Choose \"Default\" to use the same provider as chat and ingest.")
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

    private var doclingErrorBinding: Binding<Bool> {
        Binding(get: { if case .failed = doclingTest { return true } else { return false } },
                set: { if !$0, case .failed = doclingTest { doclingTest = .idle } })
    }
    private var doclingErrorMessage: String? {
        if case .failed(let m) = doclingTest { return m }; return nil
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
        DebugLog.trying("save extraction config", operation: { try config.save(to: containerDirectory) })

        DebugLog.trying("set Docling token", operation: { try credentialStore.setSecret(doclingTokenText.isEmpty ? nil : doclingTokenText, .doclingServeToken) })
    }

    /// Write every non-secret draft into `config`.
    private func writeConfig(into config: inout ExtractionConfig) {
        ExtractorSettingsSelectionMapping.writePDF(pdfExtractorSelection, into: &config)
        config.acpProviderId = acpProviderSelection.isEmpty ? nil : acpProviderSelection
        let endpoint = doclingEndpointText.trimmingCharacters(in: .whitespacesAndNewlines)
        config.doclingServeEndpoint = endpoint.isEmpty ? nil : endpoint
        ExtractorSettingsSelectionMapping.writeHTML(htmlExtractorSelection, into: &config)
        config.podcastBackend = draftPodcastBackend
    }

    // MARK: - Test Connection

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

    private func announceAccessibility(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: message])
    }

    private enum Metrics {
        static let width: CGFloat = 460
        /// A fixed height tall enough for the multi-line footers and so that
        /// switching backends (sections of different heights) doesn't resize
        /// the window. A short section just leaves space below it.
        static let height: CGFloat = 420
    }
}

// MARK: - Unified extractor selection

enum PDFExtractorSettingsSelection: Hashable, Sendable {
    case reviewedPdf2md
    case installed(LogicalExtractorReference)
    case host(ExtractionBackend)
}

enum HTMLExtractorSettingsSelection: Hashable, Sendable {
    case prompt
    case reviewedDefuddle
    case installed(LogicalExtractorReference)
    case host(HtmlExtractionBackend)
}

enum ExtractorSettingsSelectionMapping {
    static let claudeACPProviderID = ProviderID(rawValue: "claude-acp")
    static let geminiACPProviderID = ProviderID(rawValue: "gemini")

    static func pdfSelection(from config: ExtractionConfig) -> PDFExtractorSettingsSelection {
        switch config.pdfExtractor {
        case .installed(let logical):
            return logical == ProcessExtractionServices.reviewedPDFLogical
                ? .reviewedPdf2md
                : .installed(logical)
        case .builtIn(.pdf(let backend)):
            return visiblePDFSelection(for: backend)
        case .builtIn(.html), .none:
            return visiblePDFSelection(for: config.backend)
        }
    }

    static func acpProviderSelection(from config: ExtractionConfig) -> String {
        switch effectivePDFBackend(from: config) {
        case .anthropic:
            return claudeACPProviderID.rawValue
        case .gemini:
            return geminiACPProviderID.rawValue
        case .acp, .doclingServe, .localPdf2md:
            return config.acpProviderId ?? ""
        }
    }

    private static func visiblePDFSelection(for backend: ExtractionBackend) -> PDFExtractorSettingsSelection {
        switch backend {
        case .localPdf2md:
            return .reviewedPdf2md
        case .anthropic, .gemini:
            return .host(.acp)
        case .acp, .doclingServe:
            return .host(backend)
        }
    }

    private static func effectivePDFBackend(from config: ExtractionConfig) -> ExtractionBackend {
        if case .builtIn(.pdf(let backend)) = config.pdfExtractor {
            return backend
        }
        return config.backend
    }

    static func htmlSelection(from config: ExtractionConfig) -> HTMLExtractorSettingsSelection {
        switch config.htmlExtractor {
        case .installed(let logical):
            return logical == ProcessExtractionServices.reviewedHTMLLogical
                ? .reviewedDefuddle
                : .installed(logical)
        case .builtIn(.html(let backend)):
            return backend == .defuddle ? .reviewedDefuddle : .host(backend)
        case .builtIn(.pdf), .none:
            guard let backend = config.htmlBackend else { return .prompt }
            return backend == .defuddle ? .reviewedDefuddle : .host(backend)
        }
    }

    static func writePDF(
        _ selection: PDFExtractorSettingsSelection,
        into config: inout ExtractionConfig
    ) {
        switch selection {
        case .reviewedPdf2md:
            config.backend = .localPdf2md
            config.pdfExtractor = .installed(ProcessExtractionServices.reviewedPDFLogical)
        case .installed(let logical):
            config.pdfExtractor = .installed(logical)
        case .host(let backend):
            config.backend = backend
            config.pdfExtractor = .builtIn(.pdf(backend))
        }
    }

    static func writeHTML(
        _ selection: HTMLExtractorSettingsSelection,
        into config: inout ExtractionConfig
    ) {
        switch selection {
        case .prompt:
            config.htmlBackend = nil
            config.htmlExtractor = nil
        case .reviewedDefuddle:
            config.htmlBackend = .defuddle
            config.htmlExtractor = .installed(ProcessExtractionServices.reviewedHTMLLogical)
        case .installed(let logical):
            config.htmlExtractor = .installed(logical)
        case .host(let backend):
            config.htmlBackend = backend
            config.htmlExtractor = .builtIn(.html(backend))
        }
    }
}

// MARK: - Package lifecycle value types (Settings → Extraction)

/// Value snapshot of the installed-package lifecycle as presented by Settings:
/// the process registry's active exact registrations, catalog revisions whose
/// activation failed in this process (bounded, redacted reconciler
/// diagnostics), and the generation the reconciler last applied.
struct ExtractorPackageSettingsSnapshot: Sendable, Equatable {
    var rows: [ExtractorPackageSettingsRow] = []
    var failedPackages: [ExtractorPackageFailureSummary] = []
    var appliedGeneration: UInt64?

    static let empty = ExtractorPackageSettingsSnapshot()
}

/// One failed package, copied out of the reconciler's public failure struct so
/// the Settings surface depends on its own value type, not a live report.
struct ExtractorPackageFailureSummary: Identifiable, Hashable, Sendable {
    let packageID: String
    let version: String
    let digestPrefix: String
    let message: String

    init(packageID: String, version: String, digestPrefix: String, message: String) {
        self.packageID = packageID
        self.version = version
        self.digestPrefix = digestPrefix
        self.message = message
    }

    var id: String { "\(packageID)/\(version)/\(digestPrefix)" }
}

/// One installed logical (version-free) reference offered in the default
/// extractor pickers. `logical` is the persisted value; the rest is labeling.
struct ExtractorPackageChoice: Identifiable, Hashable, Sendable {
    let logical: LogicalExtractorReference
    let packageID: String
    let registrationID: String

    var id: String { "\(packageID)/\(registrationID)" }
    var label: String { "\(packageID) — \(registrationID)" }
}

/// Result of an app-only package mutation, already reduced to user-facing
/// strings so the closure seam carries no throwing errors across the UI.
enum ExtractorPackageMutationOutcome: Sendable, Equatable {
    case succeeded(String?)
    case failed(String)
}

/// Fixed, path-free diagnostics for package mutations. Errors from the store
/// and admission layers are enumerated so no incidental detail (paths,
/// environment, errno strings) can leak into the UI.
enum ExtractorPackageMutationMessage {
    static func describe(_ error: Error) -> String {
        switch error as? ExtractorPackageStoreError {
        case .mutationForbidden:
            return "Extractor packages can only be changed from the app."
        case .lockTimedOut:
            return "The extractor store was busy. Try again in a moment."
        case .staleGeneration:
            return "The extractor store changed during the operation. Try again."
        case .conflictingRevision, .packageRootAlreadyExists:
            return "A different revision of this package already occupies its place in the store."
        case .packageMissing:
            return "The package is no longer present in the extractor store."
        case .packageRemovalFailed:
            return "The package was removed from the catalog but its files could not be fully cleaned up."
        case .recoveryFailed:
            return "Extractor store recovery failed."
        case .corruptCatalog, .catalogTooLarge:
            return "The extractor catalog could not be read."
        case .filesystemFailure:
            return "The extractor store could not be updated on disk."
        case .none:
            break
        }
        switch error as? ExtractorDirectoryAdmissionError {
        case .nonFileURL, .sourceNotDirectory:
            return "Select one local extractor package folder."
        case .sourceChanged, .symlink, .hardLink, .specialFile, .deviceChanged,
             .metadataChanged, .modeChanged, .containment:
            return "The package folder changed or is unsafe to import."
        case .collision, .copyFailed, .preparationFailed, .validationFailed,
             .expectedRevisionMismatch, .invalidStagingID, .limitExceeded:
            return "The package failed validation and was not installed."
        case .manifest:
            return "The package manifest failed validation."
        case .mutationForbidden:
            return "Extractor packages can only be changed from the app."
        case .none:
            return "The extractor package operation failed. See Console for details."
        }
    }
}

/// The local-only package-directory contract used by Extraction settings,
/// mirroring `RendererSettingsPackagePicker`. AppKit's panel configuration is
/// only the first safeguard: every accepted selection is revalidated at this
/// boundary so files, archives, and multiple URLs cannot enter the import
/// workflow through another call path.
@MainActor
enum ExtractorSettingsPackagePicker {
    static let disclosureTitle = "Advanced Local Package Import"
    static let importButtonTitle = "Import Extractor Package…"
    static let localImportSourceMessage = "Select one local extractor package folder as an import source."
    static let localImportStorageMessage = "Self Driving Wiki validates and copies it into the extractor store on this Mac."
    static let localImportAfterMessage = "The selected source folder is not used after import."
    static let filesUnsupportedMessage = "Files and archives are not supported."
    static let selectionErrorMessage = "Select one local extractor package folder as an import source. Self Driving Wiki validates and copies it. Files and archives are not supported."

    static func makePanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.prompt = importButtonTitle
        panel.title = importButtonTitle
        panel.message = selectionErrorMessage
        return panel
    }

    static func validatedDirectory(from selection: [URL]) throws -> URL {
        guard selection.count == 1, let url = selection.first else {
            throw PickerSelectionError.expectedOneDirectory
        }
        guard !isArchive(url), isDirectory(url) else {
            throw PickerSelectionError.fileOrArchiveNotSupported
        }
        return url
    }

    static func selectedDirectory(from panel: NSOpenPanel) throws -> URL {
        try validatedDirectory(from: panel.urls)
    }

    enum PickerSelectionError: Error, Equatable {
        case expectedOneDirectory
        case fileOrArchiveNotSupported
    }

    private static func isDirectory(_ url: URL) -> Bool {
        do {
            return try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        } catch {
            DebugLog.extraction("Extractor package picker could not inspect the selected URL.")
            return false
        }
    }

    private static func isArchive(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar":
            true
        default:
            false
        }
    }
}

/// Loads, mutates, and holds the installed extractor-package lifecycle for the
/// Settings section. All mutations run on the main actor (Phase 7.12); the
/// closures hop to the process registry/context off-main and return value
/// snapshots and outcomes. No SwiftUI state is written from a representable
/// update — refreshes happen from `.task` and user actions.
@MainActor
@Observable
final class ExtractorPackageSettingsModel {
    private let loadSnapshot: (@Sendable () async -> ExtractorPackageSettingsSnapshot)?
    private let importAction: (@Sendable (URL) async -> ExtractorPackageMutationOutcome)?
    private let removeAction: (@Sendable (ExtractorPackageRevisionID) async -> ExtractorPackageMutationOutcome)?

    private(set) var snapshot = ExtractorPackageSettingsSnapshot.empty
    private(set) var isBusy = false
    private(set) var busyMessage: String?
    private(set) var hasLoaded = false
    private(set) var lastError: String?
    private(set) var lastDiagnostic: String?

    static let checkingMessage = "Checking installed extractor packages…"
    static let importingMessage = "Validating and installing package…"
    static let removingMessage = "Removing package…"

    init(
        loadSnapshot: (@Sendable () async -> ExtractorPackageSettingsSnapshot)?,
        importPackage: (@Sendable (URL) async -> ExtractorPackageMutationOutcome)? = nil,
        removePackage: (@Sendable (ExtractorPackageRevisionID) async -> ExtractorPackageMutationOutcome)? = nil
    ) {
        self.loadSnapshot = loadSnapshot
        self.importAction = importPackage
        self.removeAction = removePackage
    }

    /// Import/removal are read-only-hidden when the app wiring did not supply
    /// the app-only mutation closures.
    var canImport: Bool { importAction != nil }
    var canRemove: Bool { removeAction != nil }

    func refresh() async {
        guard let loadSnapshot, !isBusy else { return }
        isBusy = true
        busyMessage = Self.checkingMessage
        snapshot = await loadSnapshot()
        hasLoaded = true
        isBusy = false
        busyMessage = nil
    }

    func importPackage(from directory: URL) async {
        guard let importAction, !isBusy else { return }
        isBusy = true
        busyMessage = Self.importingMessage
        lastError = nil
        lastDiagnostic = nil
        let outcome = await importAction(directory)
        apply(outcome, successDiagnostic: "Extractor package installed.")
        isBusy = false
        busyMessage = nil
        await refresh()
    }

    func remove(_ row: ExtractorPackageSettingsRow) async {
        guard let removeAction, !isBusy else { return }
        isBusy = true
        busyMessage = Self.removingMessage
        lastError = nil
        lastDiagnostic = nil
        let outcome = await removeAction(row.revision)
        apply(outcome, successDiagnostic: "Removed \(row.packageID) \(row.version).")
        isBusy = false
        busyMessage = nil
        await refresh()
    }

    func reportImportSelectionError() {
        lastError = ExtractorSettingsPackagePicker.selectionErrorMessage
    }

    private func apply(_ outcome: ExtractorPackageMutationOutcome, successDiagnostic: String) {
        switch outcome {
        case .succeeded(let diagnostic):
            lastDiagnostic = diagnostic ?? successDiagnostic
        case .failed(let message):
            lastError = message
        }
    }
}
