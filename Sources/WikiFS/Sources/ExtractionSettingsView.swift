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

    // Route table rows built from the PR 2 projection: host descriptors, the
    // package model's registration snapshots, and saved selections. Rebuilt
    // after config writes and package-snapshot refreshes.
    @State private var routeRows: [ExtractorRouteSettingsRow] = []
    /// One route-scoped, typed selection per table row (`row.id`). The picker
    /// binding writes through `ExtractorRouteSettingsMapping`, which keeps the
    /// legacy compatibility fields truthful while persisting the route record.
    @State private var routeSelections: [String: ExtractorRouteSettingsSelection] = [:]
    @State private var acpProviderSelection: String
    @State private var doclingEndpointText: String
    @State private var doclingTokenText: String
    @State private var doclingTest = TestPhase.idle
    // Issue #799 PR1: Podcast backend draft (optional — nil = no default yet,
    // user is prompted to pick on first transcription). Seeded from
    // `ExtractionConfig` in `init`, written back in `writeConfig`.
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
        _acpProviderSelection = State(initialValue: ExtractorSettingsSelectionMapping.acpProviderSelection(from: config))
        _doclingEndpointText = State(initialValue: config.doclingServeEndpoint ?? "")
        _doclingTokenText = State(initialValue: credentialStore.secret(.doclingServeToken) ?? "")
        _draftPodcastBackend = State(initialValue: config.podcastBackend)
        _packageModel = State(initialValue: ExtractorPackageSettingsModel(
            loadSnapshot: packageSnapshot,
            importPackage: importPackage,
            removePackage: removePackage))
    }

    var body: some View {
        Form {
            Section {
                extractorRouteTable

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
        .task {
            await packageModel.refresh()
            rebuildRouteRows()
        }
        .onChange(of: packageModel.snapshot) { _, _ in
            rebuildRouteRows()
        }
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

    // MARK: - Extractor route table

    /// The native, registration-driven route table: one row per extraction
    /// route (Format), a pop-up of compatible choices (Default extractor), and
    /// the live status. The fixed height keeps the Settings window bounded —
    /// the table scrolls internally when registrations add routes.
    private var extractorRouteTable: some View {
        Table(routeRows) {
            TableColumn("Format") { (row: ExtractorRouteSettingsRow) in
                Label(row.descriptor.displayName, systemImage: row.descriptor.systemImage ?? "doc")
                    // Technical MIME identity lives in help text, not a column.
                    .help("MIME type: \(row.route.mimeType.rawValue)")
            }
            .width(min: 90, ideal: 120)
            TableColumn("Default extractor") { (row: ExtractorRouteSettingsRow) in
                routePicker(row)
            }
            .width(min: 220, ideal: 280)
            TableColumn("Status") { (row: ExtractorRouteSettingsRow) in
                statusLabel(row)
            }
        }
        .frame(height: Metrics.routeTableHeight)
        .accessibilityIdentifier(RouteAccessibility.table)
        .accessibilityLabel("Default extractor routes")
    }

    /// One row's pop-up. Tags are the typed `ExtractorRouteSettingsSelection`
    /// values — no sentinel strings; the binding writes through the mapping
    /// that dual-writes the legacy compatibility fields.
    private func routePicker(_ row: ExtractorRouteSettingsRow) -> some View {
        Picker(selection: selectionBinding(row)) {
            ForEach(row.choices) { choice in
                Text(Self.optionLabel(choice)).tag(Self.selection(for: choice))
            }
        } label: {
            EmptyView()
        }
        .labelsHidden()
        .frame(maxWidth: 260)
        .accessibilityIdentifier("\(RouteAccessibility.pickerPrefix).\(Self.accessibilityKey(row.route))")
        .accessibilityLabel("Default extractor for \(row.descriptor.displayName)")
        .accessibilityValue(accessibilityValue(row))
    }

    private func selectionBinding(_ row: ExtractorRouteSettingsRow) -> Binding<ExtractorRouteSettingsSelection> {
        Binding(
            get: {
                routeSelections[row.id] ?? ExtractorRouteSettingsMapping.selection(
                    route: row.route, config: ExtractionConfig.load(from: containerDirectory), row: row)
            },
            set: { writeRouteSelection($0, for: row) })
    }

    /// Status cell + spoken/label text. The vocabulary is fixed: Available,
    /// Using fallback, Not installed, Waiting for host service, Failed to
    /// activate. The fallback description (what is actually being used) rides
    /// in help text and the accessibility value.
    /// Maps one table choice to its typed selection value — the picker tag.
    static func selection(for choice: ExtractorRouteChoice) -> ExtractorRouteSettingsSelection {
        switch choice.category {
        case .prompt:
            return .prompt
        case .reviewedPackage:
            return choice.reference == .installed(ProcessExtractionServices.reviewedPDFLogical)
                ? .reviewedPdf2md
                : .reviewedDefuddle
        case .installedPackage:
            if case .installed(let logical) = choice.reference { return .installed(logical) }
            return .prompt
        case .unavailable:
            if case .installed(let logical) = choice.reference { return .unavailableInstalled(logical) }
            return .prompt
        case .connectedService:
            if case .builtIn(.pdf(let backend)) = choice.reference { return .connectedService(backend) }
            return .prompt
        case .builtIn:
            return .builtInTagBased
        }
    }

    @ViewBuilder
    private func statusLabel(_ row: ExtractorRouteSettingsRow) -> some View {
        switch row.status {
        case .available:
            Text("Available")
                .foregroundStyle(.secondary)
        case .usingFallback(let description):
            Label("Using fallback", systemImage: "arrow.triangle.swap")
                .foregroundStyle(.orange)
                .help(description)
        case .notInstalled:
            Text("Not installed")
                .foregroundStyle(.orange)
        case .waitingForHostService:
            Label("Waiting for host service", systemImage: "clock")
                .foregroundStyle(.orange)
        case .failedActivation:
            Label("Failed to activate", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    private func accessibilityValue(_ row: ExtractorRouteSettingsRow) -> String {
        let selectedName: String
        if let selection = routeSelections[row.id],
           let choice = row.choices.first(where: { Self.selection(for: $0) == selection }) {
            selectedName = choice.displayName
        } else {
            selectedName = "No default"
        }
        return "\(selectedName), \(Self.statusText(row.status))"
    }

    /// The picker's option caption, matching the pickers this table replaced:
    /// "name — source".
    static func optionLabel(_ choice: ExtractorRouteChoice) -> String {
        "\(choice.displayName) — \(sourceName(choice.category))"
    }

    static func sourceName(_ category: ExtractorRouteSourceCategory) -> String {
        switch category {
        case .reviewedPackage: "Reviewed package"
        case .installedPackage: "Installed package"
        case .connectedService: "Connected service"
        case .builtIn: "Built in"
        case .prompt: "Prompt"
        case .unavailable: "Not installed"
        }
    }

    static func statusText(_ status: ExtractorRouteStatus) -> String {
        switch status {
        case .available: "Available"
        case .usingFallback: "Using fallback"
        case .notInstalled: "Not installed"
        case .waitingForHostService: "Waiting for host service"
        case .failedActivation: "Failed to activate"
        }
    }

    /// Rebuilds the rows and the derived per-route selections from the current
    /// config plus the package model's projection snapshot.
    private func rebuildRouteRows() {
        let config = ExtractionConfig.load(from: containerDirectory)
        routeRows = ExtractorRouteTableBuilder.build(.init(
            configuration: config,
            registrations: packageModel.snapshot.registrationSnapshots,
            failedPackageIDs: Set(packageModel.snapshot.failedPackages.map(\.packageID)),
            waitingRevisionIDs: packageModel.snapshot.waitingRevisionIDs))
        var selections: [String: ExtractorRouteSettingsSelection] = [:]
        for row in routeRows {
            selections[row.id] = ExtractorRouteSettingsMapping.selection(
                route: row.route, config: config, row: row)
        }
        routeSelections = selections
    }

    /// Persists one route picker change: the mapping keeps the legacy
    /// compatibility fields truthful, `setExtractorSelection` writes the typed
    /// route record, and the auto-save contract persists immediately.
    private func writeRouteSelection(_ selection: ExtractorRouteSettingsSelection, for row: ExtractorRouteSettingsRow) {
        var config = ExtractionConfig.load(from: containerDirectory)
        ExtractorRouteSettingsMapping.write(selection, route: row.route, into: &config)
        DebugLog.trying("save extraction config", operation: { try config.save(to: containerDirectory) })
        rebuildRouteRows()
    }

    /// Stable, derivable accessibility key for a route: kind plus MIME with
    /// the separator flattened ("pdf-application-pdf", "html-text-html").
    static func accessibilityKey(_ route: ExtractorRouteID) -> String {
        "\(route.kind.rawValue)-\(route.mimeType.rawValue.replacing("/", with: "-"))"
    }

    private enum RouteAccessibility {
        static let table = "extraction.routes.table"
        static let pickerPrefix = "extraction.routes.picker"
        static let statusPrefix = "extraction.routes.status"
    }

    // MARK: - Selected service configuration

    @ViewBuilder private var backendConfigSection: some View {
        switch routeSelections[ExtractorRouteID.canonicalPDF.description] {
        case .connectedService(.acp): acpSection
        case .connectedService(.doclingServe): doclingSection
        default: EmptyView()
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

    /// Write every non-secret draft into `config`. The route selections are
    /// not here — each table picker writes through
    /// `ExtractorRouteSettingsMapping.write` the moment it changes.
    private func writeConfig(into config: inout ExtractionConfig) {
        config.acpProviderId = acpProviderSelection.isEmpty ? nil : acpProviderSelection
        let endpoint = doclingEndpointText.trimmingCharacters(in: .whitespacesAndNewlines)
        config.doclingServeEndpoint = endpoint.isEmpty ? nil : endpoint
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
        /// The route table's fixed height: both canonical rows plus room for a
        /// few registration-derived rows, with internal scrolling beyond that
        /// so the Settings window never grows without bound.
        static let routeTableHeight: CGFloat = 132
    }
}

// MARK: - Route-scoped extractor selection

/// One route-scoped default-extractor selection. Replaces the separate
/// per-kind PDF and HTML settings enums: the route is the identity, the
/// associated values stay typed (`LogicalExtractorReference`,
/// `ExtractionBackend`), and no sentinel strings exist for prompt,
/// unavailable, or default state.
enum ExtractorRouteSettingsSelection: Hashable, Sendable {
    /// HTML only: no default — the user is prompted per extraction.
    case prompt
    case reviewedPdf2md
    case reviewedDefuddle
    case installed(LogicalExtractorReference)
    /// A saved installed selection whose package is no longer active.
    case unavailableInstalled(LogicalExtractorReference)
    /// PDF only: ACP or Docling Serve.
    case connectedService(ExtractionBackend)
    /// HTML only: the built-in tag-based extractor.
    case builtInTagBased
}

/// Maps between `ExtractionConfig` (route records + legacy fields) and the
/// route-scoped view selection, and writes a table pick through both layers:
/// the legacy `backend` / `htmlBackend` / `pdfExtractor` / `htmlExtractor`
/// fields stay truthful for old builds while `setExtractorSelection` persists
/// the typed route record.
enum ExtractorRouteSettingsMapping {
    /// The view selection for one route, applying the same display semantics
    /// the fixed pickers used (a legacy `localPdf2md` backend displays as the
    /// reviewed package; direct API backends display as ACP).
    static func selection(
        route: ExtractorRouteID,
        config: ExtractionConfig,
        row: ExtractorRouteSettingsRow
    ) -> ExtractorRouteSettingsSelection {
        let saved = config.extractorSelection(for: route)
        if route == .canonicalPDF {
            switch saved {
            case .installed(let logical):
                return logical == ProcessExtractionServices.reviewedPDFLogical
                    ? .reviewedPdf2md
                    : installedSelection(logical, row: row)
            case .builtIn(.pdf(let backend)):
                return visiblePDFSelection(for: backend)
            case .builtIn(.html), .none:
                return visiblePDFSelection(for: config.backend)
            }
        }
        if route == .canonicalHTML {
            switch saved {
            case .installed(let logical):
                return logical == ProcessExtractionServices.reviewedHTMLLogical
                    ? .reviewedDefuddle
                    : installedSelection(logical, row: row)
            case .builtIn(.html(let backend)):
                return backend == .defuddle ? .reviewedDefuddle : .builtInTagBased
            case .builtIn(.pdf), .none:
                guard let legacy = config.htmlBackend else { return .prompt }
                return legacy == .defuddle ? .reviewedDefuddle : .builtInTagBased
            }
        }
        // Future registration-derived routes carry package choices only.
        switch saved {
        case .installed(let logical):
            return installedSelection(logical, row: row)
        default:
            return .prompt
        }
    }

    private static func installedSelection(
        _ logical: LogicalExtractorReference,
        row: ExtractorRouteSettingsRow
    ) -> ExtractorRouteSettingsSelection {
        row.choices.contains { $0.category == .installedPackage && $0.reference == .installed(logical) }
            ? .installed(logical)
            : .unavailableInstalled(logical)
    }

    private static func visiblePDFSelection(for backend: ExtractionBackend) -> ExtractorRouteSettingsSelection {
        switch backend {
        case .localPdf2md:
            return .reviewedPdf2md
        case .anthropic, .gemini, .acp:
            return .connectedService(.acp)
        case .doclingServe:
            return .connectedService(.doclingServe)
        }
    }

    /// Persists one table pick. The legacy mapping mirrors the old
    /// `writePDF` / `writeHTML` semantics exactly; `setExtractorSelection`
    /// then dual-writes the route record and the matching legacy reference
    /// field.
    static func write(
        _ selection: ExtractorRouteSettingsSelection,
        route: ExtractorRouteID,
        into config: inout ExtractionConfig
    ) {
        let reference: ExtractionBackendReference?
        if route == .canonicalPDF {
            switch selection {
            case .reviewedPdf2md:
                config.backend = .localPdf2md
                reference = .installed(ProcessExtractionServices.reviewedPDFLogical)
            case .installed(let logical), .unavailableInstalled(let logical):
                reference = .installed(logical)
            case .connectedService(let backend):
                config.backend = backend
                reference = .builtIn(.pdf(backend))
            case .prompt, .reviewedDefuddle, .builtInTagBased:
                return
            }
        } else if route == .canonicalHTML {
            switch selection {
            case .prompt:
                config.htmlBackend = nil
                reference = nil
            case .reviewedDefuddle:
                config.htmlBackend = .defuddle
                reference = .installed(ProcessExtractionServices.reviewedHTMLLogical)
            case .installed(let logical), .unavailableInstalled(let logical):
                reference = .installed(logical)
            case .builtInTagBased:
                config.htmlBackend = .tagBased
                reference = .builtIn(.html(.tagBased))
            case .reviewedPdf2md, .connectedService:
                return
            }
        } else {
            switch selection {
            case .installed(let logical), .unavailableInstalled(let logical):
                reference = .installed(logical)
            default:
                return
            }
        }
        config.setExtractorSelection(reference, for: route)
    }
}

/// The ACP-provider draft mapping, retained from the former
/// `ExtractorSettingsSelectionMapping`: the provider picker keeps its String
/// draft, and the legacy direct-API provider defaults still resolve.
enum ExtractorSettingsSelectionMapping {
    static let claudeACPProviderID = ProviderID(rawValue: "claude-acp")
    static let geminiACPProviderID = ProviderID(rawValue: "gemini")

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

    private static func effectivePDFBackend(from config: ExtractionConfig) -> ExtractionBackend {
        if case .builtIn(.pdf(let backend)) = config.pdfExtractor {
            return backend
        }
        return config.backend
    }
}

// MARK: - Package lifecycle value types (Settings → Extraction)

/// Value snapshot of the installed-package lifecycle as presented by Settings:
/// the process registry's active exact registrations, catalog revisions whose
/// activation failed in this process (bounded, redacted reconciler
/// diagnostics), the generation the reconciler last applied, and the
/// route-presentation projection (registration snapshots + waiting revisions)
/// the route table builder consumes.
struct ExtractorPackageSettingsSnapshot: Sendable, Equatable {
    var rows: [ExtractorPackageSettingsRow] = []
    var failedPackages: [ExtractorPackageFailureSummary] = []
    var appliedGeneration: UInt64?
    var registrationSnapshots: [ExtractorRouteRegistrationSnapshot] = []
    var waitingRevisionIDs: Set<ExtractorPackageRevisionID> = []

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
