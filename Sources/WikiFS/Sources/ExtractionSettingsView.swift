import AppKit
import SwiftUI
import WikiFSEngine
import WikiFSCore
import WikiFSTypes

// pattern: Functional Core

/// Recovery actions supported by the Extractor Status sheet.
enum ExtractorRouteRecoveryAction: String, CaseIterable, Hashable, Sendable {
    case configure
    case authorizeCredential
    case testConnection
    case retryActivation
    case refreshStatus
    case chooseAnotherExtractor
    case copyDiagnostics

    var title: String {
        switch self {
        case .configure: "Configure…"
        case .authorizeCredential: "Authorize Credential…"
        case .testConnection: "Test Connection"
        case .retryActivation: "Retry Activation"
        case .refreshStatus: "Refresh Status"
        case .chooseAnotherExtractor: "Choose Another Extractor…"
        case .copyDiagnostics: "Copy Diagnostics"
        }
    }
}

enum ExtractorRouteDiagnosticCategory: String, Hashable, Sendable {
    case ready
    case needsSetup = "needs-setup"
    case packageNotInstalled = "package-not-installed"
    case waitingForActivation = "waiting-for-activation"
    case activationFailed = "activation-failed"
    case unavailableSelection = "unavailable-selection"
}

enum ExtractorConnectionTestCategory: String, Hashable, Sendable {
    case notRun = "not-run"
    case running
    case succeeded
    case failed
}

/// UI-safe facts that can refine engine-owned route lifecycle state.
struct ExtractorRouteRecoveryFacts: Hashable, Sendable {
    var acpProviderID: String?
    var acpProviderAvailable = false
    var doclingEndpoint: String?
    var doclingTimeoutMilliseconds: Int?
    var doclingCredentialConfigured = false
    var connectionTest: ExtractorConnectionTestCategory = .notRun
    var connectionFailureMessage: String?
    var credentialRequirements: [ExtractorCredentialRequirementSummary] = []
    var retainedFailures: [ExtractorPackageFailureSummary] = []
    var appVersion = "unknown"
    var appBuild = "unknown"
    var macOSVersion = "unknown"
}

/// The complete value presentation for one route status and recovery sheet.
struct ExtractorRouteRecoveryPresentation: Identifiable, Hashable, Sendable {
    let route: ExtractorRouteID
    let extractorName: String
    let status: ExtractorRouteStatus
    let shortStatusLabel: String
    let systemImage: String
    let title: String
    let summary: String
    let impact: String
    let primaryAction: ExtractorRouteRecoveryAction?
    let secondaryActions: [ExtractorRouteRecoveryAction]
    let accessibilityText: String
    let diagnosticCategory: ExtractorRouteDiagnosticCategory
    let diagnosticReport: String
    let authorizationRequirement: ExtractorCredentialRequirementSummary?

    var id: String { route.description }
    var actions: [ExtractorRouteRecoveryAction] {
        primaryAction.map { [$0] + secondaryActions } ?? secondaryActions
    }
    var isReady: Bool { status == .ready }
}

/// A deterministic, bounded, value-only diagnostic report.
struct ExtractorRouteDiagnosticReport: Hashable, Sendable {
    static let maximumFieldLength = 300
    static let maximumReportLength = 4_000

    let extractorName: String
    let packageID: String?
    let registrationID: String?
    let version: String?
    let digestPrefix: String?
    let routeKind: String
    let mimeType: String
    let category: ExtractorRouteDiagnosticCategory
    let failureMessage: String?
    let acpProviderID: String?
    let doclingEndpointOrigin: String?
    let doclingTimeoutMilliseconds: Int?
    let credentialConfigured: Bool?
    let credentialAuthorized: Bool?
    let connectionTest: ExtractorConnectionTestCategory?
    let appVersion: String
    let appBuild: String
    let macOSVersion: String

    var formatted: String {
        var lines = [
            "Extractor Status Diagnostic",
            "Extractor: \(Self.field(extractorName))",
            "Route kind: \(Self.field(routeKind))",
            "MIME type: \(Self.field(mimeType))",
            "Status: \(category.rawValue)",
        ]
        Self.append("Package ID", packageID, to: &lines)
        Self.append("Registration ID", registrationID, to: &lines)
        Self.append("Version", version, to: &lines)
        Self.append("Digest prefix", digestPrefix, to: &lines)
        Self.append("Failure", failureMessage, to: &lines)
        Self.append("ACP provider ID", acpProviderID, to: &lines)
        Self.append("Docling endpoint origin", doclingEndpointOrigin, to: &lines)
        if let doclingTimeoutMilliseconds {
            lines.append("Docling timeout: \(doclingTimeoutMilliseconds) ms")
        }
        if let credentialConfigured {
            lines.append("Credential configured: \(credentialConfigured ? "yes" : "no")")
        }
        if let credentialAuthorized {
            lines.append("Credential authorized: \(credentialAuthorized ? "yes" : "no")")
        }
        if let connectionTest {
            lines.append("Connection test: \(connectionTest.rawValue)")
        }
        lines.append("App version: \(Self.field(appVersion))")
        lines.append("App build: \(Self.field(appBuild))")
        lines.append("macOS: \(Self.field(macOSVersion))")
        return Self.bounded(lines.joined(separator: "\n"), limit: Self.maximumReportLength)
    }

    static func endpointOrigin(_ raw: String?) -> String? {
        guard let raw,
              raw.utf8.count <= maximumFieldLength,
              let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, host.isEmpty == false
        else { return nil }
        var origin = "\(scheme)://\(host.lowercased())"
        if let port = components.port { origin += ":\(port)" }
        return field(origin)
    }

    private static func append(_ name: String, _ value: String?, to lines: inout [String]) {
        if let value { lines.append("\(name): \(field(value))") }
    }

    private static func field(_ value: String) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return bounded(singleLine, limit: maximumFieldLength)
    }

    private static func bounded(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(max(0, limit - 14))) + "… [truncated]"
    }
}

enum ExtractorRouteRecoveryPresenter {
    static let blockedImpact = "This route is blocked. No other extractor will run automatically."

    static func present(
        row: ExtractorRouteSettingsRow,
        extractorName: String,
        facts: ExtractorRouteRecoveryFacts
    ) -> ExtractorRouteRecoveryPresentation {
        let logical = logicalReference(row.savedSelection)
        let requirement = matchingRequiredRequirement(logical: logical, facts: facts)
        let failure = newestFailure(logical: logical, facts: facts)
        let savedRole = ExtractorRouteHostCatalog.role(for: row.savedSelection)
        let isACP = savedRole == .connectedServiceACP
        let isDocling = savedRole == .doclingLineage

        let status: ExtractorRouteStatus
        if let failure {
            status = .activationFailed(message: failure.message)
        } else if isACP, facts.acpProviderID?.isEmpty != false {
            status = .needsSetup(.missingACPProvider)
        } else if isACP, facts.acpProviderAvailable == false {
            status = .needsSetup(.unavailableACPProvider)
        } else if isDocling, ExtractorRouteDiagnosticReport.endpointOrigin(facts.doclingEndpoint) == nil {
            status = .needsSetup(.invalidDoclingEndpoint)
        } else if isDocling, facts.doclingCredentialConfigured == false {
            status = .needsSetup(.missingDoclingCredential)
        } else if let requirement,
                  requirement.authorizationState != .authorized || requirement.isConfigured == false {
            status = .needsSetup(.unauthorizedDoclingCredential)
        } else if isDocling, facts.connectionTest == .failed {
            status = .needsSetup(.doclingConnectionFailed)
        } else {
            status = row.status
        }

        let content = content(
            status: status,
            extractorName: extractorName,
            isACP: isACP,
            isDocling: isDocling,
            canAuthorize: requirement != nil)
        let category = category(status)
        let report = report(
            row: row,
            extractorName: extractorName,
            status: status,
            category: category,
            facts: facts,
            requirement: requirement,
            failure: failure).formatted
        return ExtractorRouteRecoveryPresentation(
            route: row.route,
            extractorName: extractorName,
            status: status,
            shortStatusLabel: content.label,
            systemImage: content.icon,
            title: content.title,
            summary: content.summary,
            impact: blockedImpact,
            primaryAction: content.actions.first,
            secondaryActions: Array(content.actions.dropFirst()),
            accessibilityText: "\(row.descriptor.displayName), \(extractorName), \(content.label). \(content.summary)",
            diagnosticCategory: category,
            diagnosticReport: report,
            authorizationRequirement: requirement)
    }

    private static func logicalReference(_ selection: ExtractionBackendReference?) -> LogicalExtractorReference? {
        guard case .installed(let logical)? = selection else { return nil }
        return logical
    }

    private static func matchingRequiredRequirement(
        logical: LogicalExtractorReference?,
        facts: ExtractorRouteRecoveryFacts
    ) -> ExtractorCredentialRequirementSummary? {
        guard let logical else { return nil }
        return facts.credentialRequirements.first {
            $0.packageID == logical.packageID.rawValue
                && $0.registrationID == logical.registrationID.rawValue
                && $0.isOptional == false
                && ($0.authorizationState != .authorized || $0.isConfigured == false)
        }
    }

    private static func newestFailure(
        logical: LogicalExtractorReference?,
        facts: ExtractorRouteRecoveryFacts
    ) -> ExtractorPackageFailureSummary? {
        guard let logical else { return nil }
        return facts.retainedFailures.reversed().first {
            $0.packageID == logical.packageID.rawValue
        }
    }

    private static func category(_ status: ExtractorRouteStatus) -> ExtractorRouteDiagnosticCategory {
        switch status {
        case .ready: .ready
        case .needsSetup: .needsSetup
        case .packageNotInstalled: .packageNotInstalled
        case .waitingForHostActivation: .waitingForActivation
        case .activationFailed: .activationFailed
        case .unavailableSelection: .unavailableSelection
        }
    }

    private static func content(
        status: ExtractorRouteStatus,
        extractorName: String,
        isACP: Bool,
        isDocling: Bool,
        canAuthorize: Bool
    ) -> (label: String, icon: String, title: String, summary: String, actions: [ExtractorRouteRecoveryAction]) {
        let common: [ExtractorRouteRecoveryAction] = [.chooseAnotherExtractor, .copyDiagnostics]
        switch status {
        case .ready:
            return ("Ready", "checkmark.circle.fill", "\(extractorName) is ready", "The selected extractor can run for this route.", [])
        case .needsSetup(let reason):
            let reasonText: String
            var recovery: [ExtractorRouteRecoveryAction] = []
            switch reason {
            case .missingACPProvider:
                reasonText = "Select an ACP provider before this extractor can run."
                recovery = [.configure]
            case .unavailableACPProvider:
                reasonText = "The selected ACP provider is not enabled."
                recovery = [.configure, .refreshStatus]
            case .invalidDoclingEndpoint:
                reasonText = "Set a valid HTTP or HTTPS Docling endpoint."
                recovery = [.configure]
            case .missingDoclingCredential:
                reasonText = "Add the Docling credential before this extractor can run."
                recovery = [.configure]
            case .unauthorizedDoclingCredential:
                reasonText = "Authorize the package to use the configured Docling credential."
                recovery = canAuthorize ? [.authorizeCredential] : [.refreshStatus]
            case .doclingConnectionFailed:
                reasonText = "The most recent Docling connection test failed."
                recovery = [.testConnection, .configure]
            }
            if isACP == false && isDocling == false && recovery.isEmpty { recovery = [.refreshStatus] }
            return ("Needs setup", "wrench.and.screwdriver", "\(extractorName) needs setup", reasonText, recovery + common)
        case .packageNotInstalled:
            return ("Not installed", "shippingbox", "\(extractorName) is not installed", "The saved package selection is not present on this Mac.", [.refreshStatus] + common)
        case .waitingForHostActivation:
            return ("Starting", "clock.arrow.circlepath", "\(extractorName) is starting", "The package is installed, but its host has not activated it.", [.retryActivation, .refreshStatus] + common)
        case .activationFailed(let message):
            return ("Failed", "exclamationmark.octagon", "\(extractorName) failed to start", message ?? "The package host could not activate this extractor.", [.retryActivation, .refreshStatus] + common)
        case .unavailableSelection:
            return ("Failed", "slash.circle", "\(extractorName) is unavailable", "The installed package does not provide an active extractor for this route.", [.retryActivation, .refreshStatus] + common)
        }
    }

    private static func report(
        row: ExtractorRouteSettingsRow,
        extractorName: String,
        status: ExtractorRouteStatus,
        category: ExtractorRouteDiagnosticCategory,
        facts: ExtractorRouteRecoveryFacts,
        requirement: ExtractorCredentialRequirementSummary?,
        failure: ExtractorPackageFailureSummary?
    ) -> ExtractorRouteDiagnosticReport {
        let logical = logicalReference(row.savedSelection)
        let exact = exactIdentity(logical: logical, row: row, failure: failure)
        let isDocling = logical == ProcessExtractionServices.reviewedDoclingLogical
        return ExtractorRouteDiagnosticReport(
            extractorName: extractorName,
            packageID: logical?.packageID.rawValue,
            registrationID: logical?.registrationID.rawValue,
            version: exact.version,
            digestPrefix: exact.digestPrefix,
            routeKind: row.route.kind.rawValue,
            mimeType: row.route.mimeType.rawValue,
            category: category,
            failureMessage: safeFailureMessage(
                failure?.message
                    ?? facts.connectionFailureMessage
                    ?? status.setupFailureMessage),
            acpProviderID: row.savedSelection == ExtractorRouteHostCatalog.acpReference ? facts.acpProviderID : nil,
            doclingEndpointOrigin: isDocling ? ExtractorRouteDiagnosticReport.endpointOrigin(facts.doclingEndpoint) : nil,
            doclingTimeoutMilliseconds: isDocling ? facts.doclingTimeoutMilliseconds : nil,
            credentialConfigured: requirement.map { $0.isConfigured },
            credentialAuthorized: requirement.map { $0.authorizationState == .authorized },
            connectionTest: isDocling ? facts.connectionTest : nil,
            appVersion: facts.appVersion,
            appBuild: facts.appBuild,
            macOSVersion: facts.macOSVersion)
    }

    /// Retained package failures have passed the host redaction boundary, but
    /// diagnostics still reject path-, header-, credential-, and userinfo-URL-
    /// shaped text.
    private static func safeFailureMessage(_ value: String?) -> String? {
        guard let value else { return nil }
        let lowered = value.lowercased()
        let forbidden = [
            "authorization:", "x-api-key", "api_key", "bearer ", "keychain",
            "file://", "/users/", "/private/", "document content",
            "/tmp/", "/var/", "~/", "://", "@",
        ]
        guard forbidden.contains(where: lowered.contains) == false else {
            return "A redacted host failure is available in Console."
        }
        return value
    }

    private static func exactIdentity(
        logical: LogicalExtractorReference?,
        row: ExtractorRouteSettingsRow,
        failure: ExtractorPackageFailureSummary?
    ) -> (version: String?, digestPrefix: String?) {
        if let failure { return (failure.version, failure.digestPrefix) }
        guard logical != nil,
              let summary = row.choices.first(where: { $0.reference == row.savedSelection })?.exactSummary
        else { return (nil, nil) }
        let parts = summary.components(separatedBy: " · ")
        return (parts.first, parts.count > 1 ? parts[1] : nil)
    }
}

private extension ExtractorRouteStatus {
    var setupFailureMessage: String? {
        guard case .needsSetup(let reason) = self else { return nil }
        return switch reason {
        case .missingACPProvider: "No ACP provider is selected."
        case .unavailableACPProvider: "The selected ACP provider is unavailable."
        case .invalidDoclingEndpoint: "The Docling endpoint is missing or invalid."
        case .missingDoclingCredential: "The Docling credential is not configured."
        case .unauthorizedDoclingCredential: "The package is not authorized to use the credential."
        case .doclingConnectionFailed: "The Docling connection test failed."
        }
    }
}

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
    /// UI-safe credential authority (#1159): describe (configured state) +
    /// write for the Docling token. NOT a `CredentialResolving` — the view
    /// cannot read a secret value, only store or remove one.
    let credentials: any CredentialDescribing & CredentialWriting
    /// Host-owned privileged action for Test Connection: resolves the stored
    /// Docling token OUTSIDE the view and verifies the endpoint. Returns
    /// `nil` on success or a redacted failure message.
    let verifyDoclingConnection: @Sendable (_ endpoint: String) async -> String?
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
    /// Grants (or re-grants) one requirement's credential binding. App-only:
    /// nil hides the Authorize/Change controls (headless + daemon views are
    /// read-only). Returns a redacted outcome; the confirmation copy states
    /// the inheritance rule (plan step 22).
    let authorizeRequirement: (@Sendable (ExtractorCredentialRequirementSummary) async -> ExtractorPackageMutationOutcome)?
    /// Revokes one requirement's grant. The record stays attached to its
    /// lineage; a reinstall shows (and may revoke) the stale grant. Nil hides
    /// the Revoke control.
    let revokeRequirement: (@Sendable (ExtractorCredentialRequirementSummary) async -> ExtractorPackageMutationOutcome)?
    /// Retries package host activation through the process-owned context.
    let retryActivation: (@Sendable () async -> Void)?
    /// Injectable clipboard boundary for hosted tests.
    let copyDiagnostics: @MainActor (String) -> Bool

    // Route table rows built from the PR 2 projection: host descriptors, the
    // package model's registration snapshots, and saved selections. Rebuilt
    // after config writes and package-snapshot refreshes.
    @State private var routeRows: [ExtractorRouteSettingsRow] = []
    /// One route-scoped, typed selection per table row (`row.id`). The picker
    /// binding writes through `ExtractorRouteSettingsMapping`, which persists
    /// the generic route record.
    @State private var routeSelections: [String: ExtractorRouteSettingsSelection] = [:]
    @State private var acpProviderSelection: String
    @State private var doclingEndpointText: String
    /// Typed Docling timeout in SECONDS (#1159); blank = the 600s default.
    @State private var doclingTimeoutText: String
    /// Write-only token draft (#1159): starts blank, never preloads the
    /// stored token. `doclingTokenConfigured` drives the status + Remove.
    @State private var doclingTokenText = ""
    @State private var doclingTokenConfigured = false
    @State private var doclingTest = TestPhase.idle
    // Issue #799 PR1: Podcast backend draft (optional — nil = no default yet,
    // user is prompted to pick on first transcription). Seeded from
    // `ExtractionConfig` in `init`, written back in `writeConfig`.
    @State private var draftPodcastBackend: PodcastTranscriptionBackend?
    // Installed-package lifecycle (dynamic-extractor-packages Phase 7).
    @State private var packageModel: ExtractorPackageSettingsModel
    @State private var showingImportPicker = false
    @State private var showingPackageHelp = false
    @State private var removalCandidate: ExtractorPackageSettingsRow?
    @State private var selectedPackageID: ExtractorPackageTableRow.ID?
    /// Deliberately not persisted: Settings opens on the defaults every time,
    /// because that is the question this pane exists to answer.
    @State private var selectedPane: ExtractionSettingsPane
    /// Pending authorization confirmation (#1159). Non-nil shows the
    /// explicit confirmation with the inheritance rule.
    @State private var authorizationCandidate: ExtractorCredentialRequirementSummary?
    /// Pending revocation confirmation.
    @State private var revocationCandidate: ExtractorCredentialRequirementSummary?
    @State private var routeStatusDialog: ExtractorRouteRecoveryPresentation?
    @State private var routeStatusAction: ExtractorRouteRecoveryAction?
    /// Route whose picker receives focus after the status sheet finishes
    /// dismissing ("Choose Another Extractor…").
    @State private var pendingFocusRoute: ExtractorRouteID?
    /// Event-driven snapshot of the enabled agent providers. Computed once per
    /// rebuild instead of per render: reading provider config hits disk (and
    /// can trigger discovery), which must not run on every keystroke.
    @State private var enabledProvidersCache: [AgentProvider]?
    @FocusState private var focusedRoutePicker: ExtractorRouteID?

    enum TestPhase: Equatable {
        case idle
        case testing
        case succeeded
        case failed(String)
    }

    init(
        containerDirectory: URL,
        launcher: AgentLauncher,
        credentials: (any CredentialDescribing & CredentialWriting)? = nil,
        verifyDoclingConnection: (@Sendable (_ endpoint: String) async -> String?)? = nil,
        fetcher: any HTTPRequestFetcher = URLSessionRequestFetcher(),
        packageSnapshot: (@Sendable () async -> ExtractorPackageSettingsSnapshot)? = nil,
        authorizeRequirement: (@Sendable (ExtractorCredentialRequirementSummary) async -> ExtractorPackageMutationOutcome)? = nil,
        revokeRequirement: (@Sendable (ExtractorCredentialRequirementSummary) async -> ExtractorPackageMutationOutcome)? = nil,
        retryActivation: (@Sendable () async -> Void)? = nil,
        copyDiagnostics: @escaping @MainActor (String) -> Bool = { value in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            return pasteboard.setString(value, forType: .string)
        },
        importPackage: (@Sendable (URL) async -> ExtractorPackageMutationOutcome)? = nil,
        removePackage: (@Sendable (ExtractorPackageRevisionID) async -> ExtractorPackageMutationOutcome)? = nil,
        /// The pane Settings opens on. Defaults to the document-type defaults,
        /// which is the question this pane exists to answer; hosted tests pass
        /// the other pane to mount it directly.
        initialPane: ExtractionSettingsPane = .defaults
    ) {
        _selectedPane = State(initialValue: initialPane)
        self.containerDirectory = containerDirectory
        self.launcher = launcher
        self.credentials = credentials ?? KeychainCredentialService()
        // Default action: host-owned privileged resolution (see
        // HostCredentialActions) — the view itself never resolves a value.
        self.verifyDoclingConnection = verifyDoclingConnection
            ?? HostCredentialActions.verifyDocling(fetcher: fetcher)
        self.fetcher = fetcher
        self.packageSnapshot = packageSnapshot
        self.importPackage = importPackage
        self.removePackage = removePackage
        self.authorizeRequirement = authorizeRequirement
        self.revokeRequirement = revokeRequirement
        self.retryActivation = retryActivation
        self.copyDiagnostics = copyDiagnostics

        // Seed the drafts once, at construction — so there's no onAppear race
        // where an `.onChange` fires before the loaded values are in place.
        // The token draft is deliberately NOT seeded (#1159): write-only.
        let config = ExtractionConfig.load(from: containerDirectory)
        _acpProviderSelection = State(initialValue: ExtractorSettingsSelectionMapping.acpProviderSelection(from: config))
        _doclingEndpointText = State(initialValue: config.doclingServeEndpoint ?? "")
        _doclingTimeoutText = State(initialValue: config.doclingServeTimeoutMilliseconds.map { String($0 / 1_000) } ?? "")
        _draftPodcastBackend = State(initialValue: config.podcastBackend)
        _packageModel = State(initialValue: ExtractorPackageSettingsModel(
            loadSnapshot: packageSnapshot,
            importPackage: importPackage,
            removePackage: removePackage))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Two jobs, two panes: choosing what opens a document type, and
            // managing the packages those choices draw from. Only one is
            // needed at a time, and the defaults are what a user comes here
            // for, so they open first.
            if packageSnapshot != nil {
                Picker("Extraction settings section", selection: $selectedPane) {
                    ForEach(ExtractionSettingsPane.allCases) { pane in
                        Text(pane.title).tag(pane)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: Metrics.paneSwitcherWidth)
                .padding(.top, Metrics.paneSwitcherTopPadding)
                .accessibilityIdentifier(PaneAccessibility.switcher)
                .accessibilityLabel("Extraction settings section")
            }

            switch selectedPane {
            case .defaults: defaultsPane
            case .packages: packagesPane
            }
        }
        .frame(minWidth: Metrics.width, minHeight: Metrics.height)
        // Both panes can raise the service configuration sheet — a route's
        // Configure… and a package's Configure… — so it is presented above
        // the switcher rather than inside either pane.
        .sheet(item: $serviceConfigurationDialog) { dialog in
            serviceConfigurationSheet(dialog)
        }
        // Async model mutations stay on the main actor; the load closure hops
        // to the process registry off-main and returns a value snapshot.
        .task {
            doclingTokenConfigured = refreshDoclingTokenState()
            await packageModel.refresh()
            rebuildRouteRows()
            selectFirstPackageIfNeeded()
        }
        .onChange(of: packageModel.snapshot) { _, _ in
            rebuildRouteRows()
            selectFirstPackageIfNeeded()
        }
        // An outcome that belongs to one package selects it, so its inline
        // diagnostic is the one on screen when the message appears.
        .onChange(of: packageModel.notice) { _, notice in
            if case .package(let id) = notice?.scope {
                selectedPackageID = id
            }
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
                Text("Remove \(row.packageID) \(row.version) from this Mac? If this package is selected, that route stays blocked until you choose another extractor.")
            }
        // Authorization confirmation (#1159): states the inheritance rule
        // BEFORE approval — a future revision of the same package keeps the
        // grant only while the requirement contract stays unchanged.
        .modifier(AuthorizationConfirmationModifier(
            candidate: $authorizationCandidate,
            authorize: authorizeRequirement) { outcome in
                await handleMutationOutcome(outcome)
            })
        // Revocation confirmation: explicit, destructive; the grant record
        // stays attached to the lineage (never transferred).
        .modifier(RevocationConfirmationModifier(
            candidate: $revocationCandidate,
            revoke: revokeRequirement) { outcome in
                await handleMutationOutcome(outcome)
            })
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
        .sheet(item: $routeStatusDialog) { presentation in
            ExtractorStatusDialog(
                presentation: presentation,
                inProgressAction: routeStatusAction,
                onAction: { action in
                    handleRecoveryAction(action, presentation: presentation)
                })
        }
        // Focus lands after the sheet's dismissal completes, so sheet teardown
        // cannot reset first responder before the picker receives focus.
        .onChange(of: routeStatusDialog) { oldValue, newValue in
            guard oldValue != nil, newValue == nil, let route = pendingFocusRoute else { return }
            pendingFocusRoute = nil
            focusedRoutePicker = route
        }
    }

    // MARK: - Panes

    /// What opens each document type. The pane a user comes here for, so it
    /// opens first.
    private var defaultsPane: some View {
        Form {
            Section {
                extractorRouteTable
            } header: {
                Text("Default Extractors")
            } footer: {
                Text("Reviewed packages run outside the app through the extractor protocol. Installed packages are local additions. Connected services use host-managed providers. Podcast transcripts are not package-backed in protocol revision 1.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Installed extractor-package lifecycle (Phase 7): the exact registry
    /// admissions, their inline diagnostics, and app-only import and removal.
    private var packagesPane: some View {
        Form {
            installedPackagesSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Extractor route table

    /// The native, registration-driven route table: one row per extraction
    /// route (Format), a pop-up of compatible choices (Default extractor), and
    /// the live status. The fixed height keeps the Settings window bounded —
    /// the table scrolls internally when registrations add routes.
    private var extractorRouteTable: some View {
        Table(defaultsRows) {
            TableColumn("Format") { (row: ExtractionDefaultsTableRow) in
                switch row {
                case .route(let routeRow):
                    Label(routeRow.descriptor.displayName, systemImage: routeRow.descriptor.systemImage ?? "doc")
                        // Technical MIME identity lives in help text, not a column.
                        .help("MIME type: \(routeRow.route.mimeType.rawValue)")
                case .podcastTranscript:
                    Label(Self.podcastTranscriptRowTitle, systemImage: "waveform")
                        .help(Self.podcastTranscriptHelp)
                }
            }
            // Wide enough for the longest format name in the table, which is
            // the transcript row rather than one of the three-letter routes.
            .width(min: 110, ideal: 160)
            TableColumn("Default extractor") { (row: ExtractionDefaultsTableRow) in
                switch row {
                case .route(let routeRow): routePicker(routeRow)
                case .podcastTranscript: podcastTranscriptPicker
                }
            }
            .width(min: 220, ideal: 280)
            TableColumn("Status") { (row: ExtractionDefaultsTableRow) in
                switch row {
                case .route(let routeRow):
                    statusLabel(routeRow)
                case .podcastTranscript:
                    // A host adapter has no package to install, activate, or
                    // authorize, so the table builder's non-package answer
                    // (ready) is the honest one here too.
                    podcastTranscriptStatusBadge
                }
            }
            // Status is a semantic-colored icon + short label — compact by
            // design (PR 4 review follow-up: the long phrase truncated, so
            // the icon carries the state and the short text never wraps).
            .width(min: 110, ideal: 120)
            TableColumn("Configuration") { (row: ExtractionDefaultsTableRow) in
                if case .route(let routeRow) = row, let dialog = configurationDialog(for: routeRow) {
                    Button("Configure…") {
                        serviceConfigurationDialog = dialog
                    }
                    .accessibilityIdentifier("extraction.service.configure.\(dialog.id)")
                    .accessibilityLabel(
                        "Configure \(dialog == .acp ? "ACP Provider" : "Docling Serve")")
                }
            }
            .width(min: 110, ideal: 130)
        }
        // Every cell in this table holds a pop-up, so its rows are taller
        // than the package table's text rows.
        .frame(height: SettingsTableMetrics.height(
            forRowCount: defaultsRows.count,
            rowHeight: SettingsTableMetrics.controlRowHeight))
        .accessibilityIdentifier(RouteAccessibility.table)
        .accessibilityLabel("Default extractor routes")
    }

    /// The connected-service and package credential sheets. Both panes can
    /// raise these, so the presenter lives above the pane switcher.
    @ViewBuilder
    private func serviceConfigurationSheet(_ dialog: ServiceConfigurationDialog) -> some View {
        Group {
            switch dialog {
            case .acp:
                ACPConfigurationDialog(
                    providerSelection: $acpProviderSelection,
                    enabledProviders: launcher.providersConfig().enabledProviders,
                    onPersist: { persistAll() })
            case .docling:
                DoclingConfigurationDialog(
                    endpoint: $doclingEndpointText,
                    timeoutSeconds: $doclingTimeoutText,
                    tokenDraft: $doclingTokenText,
                    tokenConfigured: doclingTokenConfigured,
                    testPhase: $doclingTest,
                    requirements: doclingCredentialRequirements,
                    authorizeRequirement: authorizeRequirement,
                    revokeRequirement: revokeRequirement,
                    onCredentialMutation: { outcome in await handleMutationOutcome(outcome) },
                    onPersist: { persistAll() },
                    onSaveToken: { saveDoclingToken() },
                    onRemoveToken: { removeDoclingToken() },
                    onTestConnection: { testDocling() })
            case .package(let package):
                PackageConfigurationDialog(
                    title: packageConfigurationTitle(package),
                    requirements: credentialRequirements(for: package),
                    authorizeRequirement: authorizeRequirement,
                    revokeRequirement: revokeRequirement,
                    onCredentialMutation: { outcome in await handleMutationOutcome(outcome) })
            }
        }
    }

    static let podcastTranscriptRowTitle = "Podcast transcript"
    static let podcastTranscriptHelp = "Podcast transcripts are not package-backed in protocol revision 1. They resolve through a host adapter."

    /// Every default the table shows: the registration-driven extraction
    /// routes, then the podcast transcript default.
    private var defaultsRows: [ExtractionDefaultsTableRow] {
        routeRows.map(ExtractionDefaultsTableRow.route)
            + [.podcastTranscript(draftPodcastBackend)]
    }

    /// The transcript row's pop-up. It writes a `PodcastTranscriptionBackend`,
    /// not an `ExtractorRouteSettingsSelection`, which is exactly why the row
    /// is its own case rather than a synthesized route.
    private var podcastTranscriptPicker: some View {
        Picker("Podcast Transcript", selection: podcastBackendBinding) {
            Text("Prompt me when transcribing").tag(nil as PodcastTranscriptionBackend?)
            ForEach(PodcastTranscriptionBackend.allCases, id: \.self) { backend in
                Text(backend.displayName).tag(backend as PodcastTranscriptionBackend?)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 260)
        .onChange(of: draftPodcastBackend) { persistAll() }
        .accessibilityIdentifier(RouteAccessibility.podcastPicker)
        .accessibilityLabel("Default podcast transcript extractor")
        .accessibilityValue(draftPodcastBackend?.displayName ?? "Prompt me when transcribing")
    }

    private var podcastTranscriptStatusBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Ready")
        }
        .fixedSize(horizontal: false, vertical: true)
        .lineLimit(1)
        .help(Self.podcastTranscriptHelp)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Podcast transcript, ready")
    }

    /// One row's pop-up. Tags are the typed `ExtractorRouteSettingsSelection`
    /// values — no sentinel strings; the binding writes through the mapping
    /// that persists the generic route record.
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
        .focused($focusedRoutePicker, equals: row.route)
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

    /// Maps one table choice to its typed selection value — the picker tag.
    static func selection(for choice: ExtractorRouteChoice) -> ExtractorRouteSettingsSelection {
        switch choice.category {
        case .prompt:
            return .prompt
        case .reviewedPackage:
            if choice.reference == .installed(ProcessExtractionServices.reviewedPDFLogical) {
                return .reviewedPdf2md
            }
            if choice.reference == .installed(ProcessExtractionServices.reviewedDoclingLogical) {
                return .reviewedDocling
            }
            if choice.reference == .installed(ProcessExtractionServices.reviewedDOCXLogical) {
                return .reviewedDocx2md
            }
            return .reviewedDefuddle
        case .installedPackage:
            if case .installed(let logical) = choice.reference { return .installed(logical) }
            return .prompt
        case .unavailable:
            if case .installed(let logical) = choice.reference { return .unavailableInstalled(logical) }
            return .prompt
        case .connectedService:
            if ExtractorRouteHostCatalog.role(for: choice.reference) == .connectedServiceACP {
                return .connectedService(.acp)
            }
            return .prompt
        case .builtIn:
            return .builtInTagBased
        }
    }

    /// Status renders as a semantic icon and a short label. Each state uses a
    /// distinct shape so it remains clear without color.
    @ViewBuilder
    private func statusLabel(_ row: ExtractorRouteSettingsRow) -> some View {
        let presentation = recoveryPresentation(for: row)
        if presentation.isReady {
            statusBadge(presentation)
        } else {
            Button {
                routeStatusDialog = presentation
            } label: {
                statusBadge(presentation)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(
                "\(RouteAccessibility.statusPrefix).\(Self.accessibilityKey(row.route))")
            .accessibilityLabel(presentation.accessibilityText)
            .accessibilityHint("Show status details")
        }
    }

    private func statusBadge(_ presentation: ExtractorRouteRecoveryPresentation) -> some View {
        HStack(spacing: 5) {
            Image(systemName: presentation.systemImage)
                .foregroundStyle(statusColor(presentation.status))
            Text(presentation.shortStatusLabel)
        }
        .fixedSize(horizontal: false, vertical: true)
        .lineLimit(1)
        .truncationMode(.tail)
        .minimumScaleFactor(0.8)
        .help("\(presentation.summary) \(presentation.impact)")
    }

    private func statusColor(_ status: ExtractorRouteStatus) -> Color {
        switch status {
        case .ready: .green
        case .needsSetup, .packageNotInstalled: .orange
        case .waitingForHostActivation: .yellow
        case .activationFailed, .unavailableSelection: .red
        }
    }

    private func recoveryPresentation(
        for row: ExtractorRouteSettingsRow
    ) -> ExtractorRouteRecoveryPresentation {
        let providers = enabledProvidersCache ?? launcher.providersConfig().enabledProviders
        let selectedName = row.choices.first { choice in
            Self.selection(for: choice) == routeSelections[row.id]
        }?.displayName ?? "No default extractor"
        let connectionCategory: ExtractorConnectionTestCategory = switch doclingTest {
        case .idle: .notRun
        case .testing: .running
        case .succeeded: .succeeded
        case .failed: .failed
        }
        let connectionMessage: String? = if case .failed(let message) = doclingTest {
            message
        } else {
            nil
        }
        let timeout = Int(doclingTimeoutText).map { $0 * 1_000 }
        let facts = ExtractorRouteRecoveryFacts(
            acpProviderID: acpProviderSelection.isEmpty ? nil : acpProviderSelection,
            acpProviderAvailable: acpProviderSelection.isEmpty
                ? providers.contains(where: \.isDefault)
                : providers.contains { $0.id.rawValue == acpProviderSelection },
            doclingEndpoint: doclingEndpointText,
            doclingTimeoutMilliseconds: timeout,
            doclingCredentialConfigured: doclingTokenConfigured,
            connectionTest: connectionCategory,
            connectionFailureMessage: connectionMessage,
            credentialRequirements: packageModel.snapshot.credentialRequirements,
            retainedFailures: packageModel.snapshot.failedPackages,
            appVersion: GeneratedVersion.appVersion,
            appBuild: GeneratedVersion.buildVersion,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString)
        return ExtractorRouteRecoveryPresenter.present(
            row: recoveryRow(row),
            extractorName: selectedName,
            facts: facts)
    }

    private func recoveryRow(_ row: ExtractorRouteSettingsRow) -> ExtractorRouteSettingsRow {
        let reference: ExtractionBackendReference?
        switch routeSelections[row.id] {
        case .reviewedPdf2md:
            reference = .installed(ProcessExtractionServices.reviewedPDFLogical)
        case .reviewedDefuddle:
            reference = .installed(ProcessExtractionServices.reviewedHTMLLogical)
        case .reviewedDocling:
            reference = .installed(ProcessExtractionServices.reviewedDoclingLogical)
        case .reviewedDocx2md:
            reference = .installed(ProcessExtractionServices.reviewedDOCXLogical)
        case .installed(let logical), .unavailableInstalled(let logical):
            reference = .installed(logical)
        case .connectedService:
            reference = ExtractorRouteHostCatalog.acpReference
        case .builtInTagBased:
            reference = ExtractorRouteHostCatalog.tagBasedReference
        case .prompt, .none:
            reference = .some(.none)
        }
        return ExtractorRouteSettingsRow(
            descriptor: row.descriptor,
            savedSelection: reference,
            resolvedSelection: row.resolvedSelection,
            choices: row.choices,
            status: row.status)
    }

    private func accessibilityValue(_ row: ExtractorRouteSettingsRow) -> String {
        let selectedName: String
        if let selection = routeSelections[row.id],
           let choice = row.choices.first(where: { Self.selection(for: $0) == selection }) {
            selectedName = choice.displayName
        } else {
            selectedName = "No default"
        }
        return "\(selectedName), \(recoveryPresentation(for: row).shortStatusLabel)"
    }

    /// The picker shows the extractor name. Status and recovery surfaces
    /// explain setup and availability without exposing implementation types.
    static func optionLabel(_ choice: ExtractorRouteChoice) -> String {
        choice.displayName
    }

    /// Rebuilds the rows and the derived per-route selections from the current
    /// config plus the package model's projection snapshot.
    private func rebuildRouteRows() {
        enabledProvidersCache = launcher.providersConfig().enabledProviders
        let config = ExtractionConfig.load(from: containerDirectory)
        routeRows = ExtractorRouteTableBuilder.build(.init(
            configuration: config,
            registrations: packageModel.snapshot.registrationSnapshots,
            availableRegistrations: packageModel.snapshot.routeChoiceRegistrationSnapshots,
            installedRevisionIDs: Set(packageModel.snapshot.rows.map(\.revision)),
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

    private enum PaneAccessibility {
        static let switcher = "extraction.pane.switcher"
    }

    private enum RouteAccessibility {
        static let table = "extraction.routes.table"
        static let pickerPrefix = "extraction.routes.picker"
        static let statusPrefix = "extraction.routes.status"
        /// The transcript row is not route-scoped, so its picker takes a fixed
        /// identifier rather than a route-derived one.
        static let podcastPicker = "extraction.routes.picker.podcast"
    }

    // MARK: - Extractor status recovery

    private func handleRecoveryAction(
        _ action: ExtractorRouteRecoveryAction,
        presentation: ExtractorRouteRecoveryPresentation
    ) {
        guard routeStatusAction == nil else { return }
        switch action {
        case .configure:
            routeStatusDialog = nil
            guard let row = routeRows.first(where: { $0.route == presentation.route }),
                  let dialog = configurationDialog(for: row)
            else { return }
            Task { @MainActor in serviceConfigurationDialog = dialog }
        case .authorizeCredential:
            routeStatusDialog = nil
            guard let requirement = presentation.authorizationRequirement else { return }
            Task { @MainActor in authorizationCandidate = requirement }
        case .testConnection:
            // testDocling single-flights on doclingTest and returns without
            // running its completion when a test is already in flight; check
            // the precondition BEFORE latching the in-progress action, or the
            // sheet wedges with every control disabled.
            guard doclingTest != .testing else {
                announceAccessibility("A connection test is already running.")
                return
            }
            routeStatusAction = action
            testDocling {
                routeStatusAction = nil
                refreshPresentedStatus(for: presentation.route)
                announceAccessibility("Docling connection test completed.")
            }
        case .retryActivation:
            runRecoveryAction(action, completion: "Extractor activation retry completed.") {
                await retryActivation?()
            }
        case .refreshStatus:
            runRecoveryAction(action, completion: "Extractor status refreshed.") {}
        case .chooseAnotherExtractor:
            pendingFocusRoute = presentation.route
            routeStatusDialog = nil
        case .copyDiagnostics:
            if copyDiagnostics(presentation.diagnosticReport) {
                announceAccessibility("Extractor diagnostics copied.")
            } else {
                announceAccessibility("Extractor diagnostics could not be copied.")
            }
        }
    }

    private func runRecoveryAction(
        _ action: ExtractorRouteRecoveryAction,
        completion: String,
        operation: @escaping @MainActor () async -> Void
    ) {
        routeStatusAction = action
        Task { @MainActor in
            await operation()
            await packageModel.refresh()
            rebuildRouteRows()
            routeStatusAction = nil
            if let route = routeStatusDialog?.route { refreshPresentedStatus(for: route) }
            announceAccessibility(completion)
        }
    }

    private func refreshPresentedStatus(for route: ExtractorRouteID) {
        rebuildRouteRows()
        guard let row = routeRows.first(where: { $0.route == route }) else {
            routeStatusDialog = nil
            return
        }
        let refreshed = recoveryPresentation(for: row)
        routeStatusDialog = refreshed.isReady ? nil : refreshed
    }

    struct ExtractorStatusDialog: View {
        let presentation: ExtractorRouteRecoveryPresentation
        let inProgressAction: ExtractorRouteRecoveryAction?
        let onAction: (ExtractorRouteRecoveryAction) -> Void
        @State private var showsTechnicalDetails = false
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: presentation.systemImage)
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(presentation.title)
                            .font(.title2.weight(.semibold))
                        Text(presentation.summary)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(presentation.impact)
                    .font(.callout.weight(.medium))
                recoveryActions
                DisclosureGroup("Technical Details", isExpanded: $showsTechnicalDetails) {
                    ScrollView {
                        Text(presentation.diagnosticReport)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                    .frame(maxHeight: 150)
                }
                .accessibilityIdentifier("extraction.status.technical-details")
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("extraction.status.done")
                }
            }
            .padding(22)
            .frame(width: Metrics.statusDialogWidth)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Extractor Status. \(presentation.accessibilityText)")
        }

        private var recoveryActions: some View {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 190), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(presentation.actions, id: \.self) { action in
                    Button {
                        onAction(action)
                    } label: {
                        if inProgressAction == action {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("\(action.title) in progress")
                        } else {
                            Text(action.title)
                        }
                    }
                    .disabled(inProgressAction != nil)
                    .accessibilityIdentifier("extraction.status.action.\(action.rawValue)")
                }
            }
        }
    }

    // MARK: - Selected service configuration

    /// Which connected service has a configuration dialog open (macOS
    /// Settings idiom: the Configure… button lives in the route table row;
    /// the options open in a dialog, per the macos-design skill).
    enum ServiceConfigurationDialog: Identifiable, Hashable {
        case acp
        case docling
        case package(ExtractorPackageConfigurationID)

        var id: String {
            switch self {
            case .acp: "acp"
            case .docling: "docling"
            case .package(let package): "package/\(package.id)"
            }
        }
    }

    struct ExtractorPackageConfigurationID: Hashable, Sendable {
        let packageID: String
        let version: String
        let registrationID: String

        var id: String { "\(packageID)/\(version)/\(registrationID)" }
    }

    @State private var serviceConfigurationDialog: ServiceConfigurationDialog?

    /// The configuration dialog a row needs, based on its current selection:
    /// ACP and Docling Serve (including the reviewed-Docling selection) open
    /// dialogs; other choices have no connected-service configuration.
    private func configurationDialog(
        for row: ExtractorRouteSettingsRow
    ) -> ServiceConfigurationDialog? {
        switch routeSelections[row.id] {
        case .connectedService(.acp):
            return .acp
        case .connectedService(.doclingServe), .reviewedDocling:
            return .docling
        default:
            return nil
        }
    }

    private var doclingCredentialRequirements: [ExtractorCredentialRequirementSummary] {
        let reviewed = ReviewedExtractorPackages.doclingServe
        return packageModel.snapshot.credentialRequirements.filter {
            $0.packageID == reviewed.packageID.rawValue
                && $0.packageVersion == reviewed.version.rawValue
                && $0.registrationID == ProcessExtractionServices.reviewedDoclingLogical.registrationID.rawValue
        }
    }

    private func packageConfigurationID(
        for row: ExtractorPackageSettingsRow
    ) -> ExtractorPackageConfigurationID? {
        Self.packageConfigurationID(
            for: row,
            requirements: packageModel.snapshot.credentialRequirements)
    }

    static func packageConfigurationID(
        for row: ExtractorPackageSettingsRow,
        requirements: [ExtractorCredentialRequirementSummary]
    ) -> ExtractorPackageConfigurationID? {
        guard row.packageID != ReviewedExtractorPackages.doclingServe.packageID.rawValue else {
            return nil
        }
        let candidate = ExtractorPackageConfigurationID(
            packageID: row.packageID,
            version: row.version,
            registrationID: row.registrationID)
        return credentialRequirements(for: candidate, in: requirements).isEmpty ? nil : candidate
    }

    private func credentialRequirements(
        for package: ExtractorPackageConfigurationID
    ) -> [ExtractorCredentialRequirementSummary] {
        Self.credentialRequirements(
            for: package,
            in: packageModel.snapshot.credentialRequirements)
    }

    static func credentialRequirements(
        for package: ExtractorPackageConfigurationID,
        in requirements: [ExtractorCredentialRequirementSummary]
    ) -> [ExtractorCredentialRequirementSummary] {
        requirements.filter {
            $0.packageID == package.packageID
                && $0.packageVersion == package.version
                && $0.registrationID == package.registrationID
        }
    }

    private func packageConfigurationTitle(
        _ package: ExtractorPackageConfigurationID
    ) -> String {
        credentialRequirements(for: package).first?.packageName ?? package.packageID
    }

    // MARK: - Installed extractor packages (Phase 7)

    /// Lifecycle list of the process registry's installed exact registrations,
    /// packages that failed to activate, and app-only removal.
    /// Each control carries a stable accessibility identifier, an accessible
    /// name, and a state value (Phase 7.10); the contract test asserts these
    /// strings exist.
    @ViewBuilder private var installedPackagesSection: some View {
        Section {
            packageTable
        } header: {
            HStack {
                Text("Installed Extractor Packages")
                Spacer()
                ExtractorPackageHelpControl(isPresented: $showingPackageHelp)
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Manage exact validated package revisions and their credential access. Choose defaults in the Default Extractors section above.")
                Text("\(ExtractorSettingsPackagePicker.localImportSourceMessage) \(ExtractorSettingsPackagePicker.localImportStorageMessage) \(ExtractorSettingsPackagePicker.localImportAfterMessage) \(ExtractorSettingsPackagePicker.filesUnsupportedMessage)")
                Label(Self.trustWarningMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier(PackageAccessibility.trustWarning)
                    .accessibilityLabel("Executable code warning. \(Self.trustWarningMessage)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// The package table, its add/remove bar, and the inline detail for the
    /// selected package. The table takes a computed height and scrolls
    /// internally, so the installed package count cannot stretch the Settings
    /// window.
    @ViewBuilder private var packageTable: some View {
        VStack(alignment: .leading, spacing: Metrics.packageSectionSpacing) {
            Table(packageModel.tableRows, selection: $selectedPackageID) {
                TableColumn("Package") { (row: ExtractorPackageTableRow) in
                    Text(row.packageID)
                        .help(row.packageID)
                }
                .width(min: 170, ideal: 240)
                TableColumn("Version") { (row: ExtractorPackageTableRow) in
                    Text(row.version)
                        .monospacedDigit()
                }
                .width(min: 70, ideal: 90)
                TableColumn("Handles") { (row: ExtractorPackageTableRow) in
                    Text(row.kind.map(kindDisplayName) ?? "—")
                        .foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 100)
                // The status is the row's own diagnostic in short form. The
                // full sentence renders in the detail below the table.
                TableColumn("Status") { (row: ExtractorPackageTableRow) in
                    Label(row.status.label, systemImage: row.status.systemImage)
                        .foregroundStyle(row.status.tint)
                        .help(row.status.explanation)
                }
                .width(min: 150, ideal: 170)
            }
            .frame(height: SettingsTableMetrics.height(
                forRowCount: packageModel.tableRows.count))
            .accessibilityIdentifier(PackageAccessibility.table)
            .accessibilityLabel("Installed extractor packages")
            .overlay {
                if packageModel.tableRows.isEmpty {
                    ContentUnavailableView(
                        packageModel.hasLoaded
                            ? "No extractor packages are installed on this Mac."
                            : ExtractorPackageSettingsModel.checkingMessage,
                        systemImage: "shippingbox",
                        description: packageModel.canImport
                            ? Text("Use Add to import a local extractor package folder.")
                            : nil)
                        .accessibilityIdentifier(PackageAccessibility.emptyState)
                }
            }

            packageActionBar

            if packageModel.isBusy {
                ProgressView(packageModel.busyMessage ?? ExtractorPackageSettingsModel.checkingMessage)
                    .controlSize(.small)
                    .accessibilityIdentifier(PackageAccessibility.progress)
                    .accessibilityLabel(packageModel.busyMessage ?? "Working on extractor packages")
                    .accessibilityAddTraits(.updatesFrequently)
            }

            if let row = selectedPackageRow {
                packageDetail(row)
            }

            // Outcomes no row owns: a rejected import, or a removal whose row
            // has already left the table.
            if let notice = packageModel.paneNotice {
                packageNoticeLabel(notice)
            }
        }
    }

    /// The add/remove bar beneath the table, in the macOS table idiom: Add
    /// creates a package, the destructive action applies to the selected row,
    /// and registry refresh sits opposite them.
    private var packageActionBar: some View {
        HStack(spacing: Metrics.packageActionBarSpacing) {
            if packageModel.canImport {
                Button("Add Package…", systemImage: "plus") {
                    showingImportPicker = true
                }
                .disabled(packageModel.isBusy)
                .accessibilityIdentifier(PackageAccessibility.importButton)
                .accessibilityLabel("Add a local extractor package folder")
                .help("\(ExtractorSettingsPackagePicker.filesUnsupportedMessage) \(Self.trustWarningMessage)")
            }

            if packageModel.canRemove {
                Button("Remove Package…", systemImage: "minus", role: .destructive) {
                    removalCandidate = selectedPackageRow?.installedRow
                }
                .disabled(packageModel.isBusy || selectedPackageRow?.installedRow == nil)
                .accessibilityIdentifier(PackageAccessibility.removeButton)
                .accessibilityLabel("Remove the selected extractor package")
            }

            Spacer()

            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await packageModel.refresh() }
            }
            .disabled(packageModel.isBusy)
            .accessibilityIdentifier(PackageAccessibility.refreshButton)
            .accessibilityLabel("Refresh installed extractor packages")
        }
        .controlSize(.small)
    }

    /// The selected package's diagnostics, kept with the package they describe:
    /// its status sentence first, then the exact bytes and registration that
    /// identify the revision, then the latest outcome scoped to this package,
    /// then the actions that apply to it.
    @ViewBuilder private func packageDetail(_ row: ExtractorPackageTableRow) -> some View {
        VStack(alignment: .leading, spacing: Metrics.packageDetailSpacing) {
            Label(row.status.explanation, systemImage: row.status.systemImage)
                .foregroundStyle(row.status.tint)
                .textSelection(.enabled)
                .accessibilityIdentifier("\(PackageAccessibility.statusPrefix).\(row.id)")
                .accessibilityLabel("\(row.packageID), version \(row.version). \(row.status.label). \(row.status.explanation)")

            if let kind = row.kind {
                LabeledContent("Kind", value: kindDisplayName(kind))
                    .font(.caption)
            }
            LabeledContent("Digest", value: row.digestPrefix)
                .font(.caption)
                .accessibilityIdentifier("\(PackageAccessibility.digestPrefix).\(row.id)")
            if let registrationID = row.registrationID {
                LabeledContent("Registration", value: registrationID)
                    .font(.caption)
                    .accessibilityIdentifier("\(PackageAccessibility.registrationPrefix).\(row.id)")
            }

            if let notice = packageModel.notice(for: row) {
                packageNoticeLabel(notice)
            }

            if let installed = row.installedRow,
               let package = packageConfigurationID(for: installed) {
                Button("Configure…") {
                    serviceConfigurationDialog = .package(package)
                }
                .controlSize(.small)
                .disabled(packageModel.isBusy)
                .accessibilityIdentifier("\(PackageAccessibility.configurePrefix).\(row.id)")
                .accessibilityLabel("Configure credentials for \(row.packageID), version \(row.version)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(PackageAccessibility.rowPrefix).\(row.id)")
        .accessibilityLabel("Diagnostics for \(row.packageID), version \(row.version)")
        .accessibilityValue(row.status.label)
    }

    @ViewBuilder private func packageNoticeLabel(_ notice: ExtractorPackageNotice) -> some View {
        Label(
            notice.message,
            systemImage: notice.severity == .failure ? "exclamationmark.triangle" : "checkmark.circle")
            .font(.caption)
            .foregroundStyle(notice.severity == .failure
                ? AnyShapeStyle(Color.red)
                : AnyShapeStyle(HierarchicalShapeStyle.secondary))
            .textSelection(.enabled)
            .accessibilityIdentifier(notice.severity == .failure
                ? PackageAccessibility.error
                : PackageAccessibility.diagnostic)
    }

    private var selectedPackageRow: ExtractorPackageTableRow? {
        packageModel.tableRows.first { $0.id == selectedPackageID }
    }

    private func selectFirstPackageIfNeeded() {
        guard packageModel.tableRows.contains(where: { $0.id == selectedPackageID }) == false else {
            return
        }
        selectedPackageID = packageModel.tableRows.first?.id
    }

    private func kindDisplayName(_ kind: ExtractionBackendKind) -> String {
        switch kind {
        case .pdf: "PDF"
        case .html: "HTML"
        default: kind.rawValue
        }
    }

    // MARK: - Credential requirements (#1159)

    /// The inheritance rule, stated BEFORE approval (plan step 22 / AC.16).
    /// Package-authored strings are quoted so they cannot impersonate the
    /// host's own text, and the host names the exact stored credential being
    /// bound (security review MEDIUM-8).
    static func authorizationConfirmationMessage(
        _ summary: ExtractorCredentialRequirementSummary
    ) -> String {
        let boundReference = ExtractorCredentialSettingsSupport.boundReferenceName(for: summary)
        let binding = boundReference.map { " This grants access to your stored credential \"\($0)\"." } ?? ""
        return "Allow \"\(summary.packageName)\" to use \"\(summary.label)\" (\(summary.purpose)).\(binding) Authorization follows future revisions of this package only while this requirement's label, purpose, optionality, and registration stay unchanged; a changed requirement asks you to authorize again."
    }

    @ViewBuilder
    static func requirementRow(
        _ summary: ExtractorCredentialRequirementSummary,
        authorizeRequirement: (@Sendable (ExtractorCredentialRequirementSummary) async -> ExtractorPackageMutationOutcome)?,
        revokeRequirement: (@Sendable (ExtractorCredentialRequirementSummary) async -> ExtractorPackageMutationOutcome)?,
        authorizationCandidate: Binding<ExtractorCredentialRequirementSummary?>,
        revocationCandidate: Binding<ExtractorCredentialRequirementSummary?>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(summary.label)
                    .fontWeight(.medium)
                Spacer()
                authorizationStateLabel(summary)
            }
            Text(summary.purpose)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(summary.isOptional ? "Optional" : "Required")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if authorizeRequirement != nil, summary.authorizationState != .authorized {
                    Button(summary.authorizationState == .changedContract
                           ? "Re-authorize…"
                           : "Authorize…") {
                        authorizationCandidate.wrappedValue = summary
                    }
                    .accessibilityIdentifier("\(RequirementAccessibility.authorizePrefix).\(summary.id)")
                    .accessibilityLabel("Authorize \(summary.label) for \(summary.packageName)")
                }
                if authorizeRequirement != nil, summary.authorizationState == .authorized {
                    Button("Review Authorization…") {
                        authorizationCandidate.wrappedValue = summary
                    }
                    .accessibilityIdentifier("\(RequirementAccessibility.changePrefix).\(summary.id)")
                    .accessibilityLabel("Review authorization for \(summary.label)")
                }
                if revokeRequirement != nil, summary.authorizationState == .authorized {
                    Button("Revoke…", role: .destructive) {
                        revocationCandidate.wrappedValue = summary
                    }
                    .accessibilityIdentifier("\(RequirementAccessibility.revokePrefix).\(summary.id)")
                    .accessibilityLabel("Revoke \(summary.label) authorization for \(summary.packageName)")
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(RequirementAccessibility.rowPrefix).\(summary.id)")
    }

    @ViewBuilder
    private static func authorizationStateLabel(
        _ summary: ExtractorCredentialRequirementSummary
    ) -> some View {
        switch summary.authorizationState {
        case .authorized:
            Label("Authorized", systemImage: "checkmark.seal")
                .foregroundStyle(.green)
                .font(.caption)
        case .needsAuthorization:
            Text("Needs authorization")
                .foregroundStyle(.orange)
                .font(.caption)
        case .changedContract:
            Text("Changed — re-authorization needed")
                .foregroundStyle(.orange)
                .font(.caption)
        }
        if summary.isConfigured == false {
            Text(summary.sourceName == "" ? "Missing credential" : "\(summary.sourceName): not set")
                .foregroundStyle(.orange)
                .font(.caption)
                .accessibilityIdentifier("\(RequirementAccessibility.missingPrefix).\(summary.id)")
        }
    }

    /// Stable accessibility identifiers for requirement rows and controls,
    /// derived from package + registration + requirement identities.
    private enum RequirementAccessibility {
        static let rowPrefix = "extraction.credentials.row"
        static let authorizePrefix = "extraction.credentials.authorize"
        static let changePrefix = "extraction.credentials.change"
        static let revokePrefix = "extraction.credentials.revoke"
        static let missingPrefix = "extraction.credentials.missing"
    }

    /// Shared post-mutation handling for the authorization dialogs: surface a
    /// redacted failure, then refresh the snapshot so authorization states
    /// update immediately.
    private func handleMutationOutcome(_ outcome: ExtractorPackageMutationOutcome?) async {
        if let outcome, case .failed(let message) = outcome {
            packageModel.reportFailure(message)
        }
        await packageModel.refresh()
    }

    /// The executable-code disclosure shown before any local import.
    static let trustWarningMessage = "Extractor packages contain executable code that runs with this app's permissions on your user account. Import only packages you trust. The app's lifecycle and capability controls do not create a security sandbox."

    /// Stable accessibility identifiers for the package lifecycle controls.
    /// Row/digest/registration/remove/failure identifiers append the row's
    /// `id` so each exact revision has a unique, derivable identifier.
    private enum PackageAccessibility {
        static let table = "extraction.packages.table"
        static let refreshButton = "extraction.packages.refresh"
        static let emptyState = "extraction.packages.empty"
        static let rowPrefix = "extraction.packages.row"
        static let statusPrefix = "extraction.packages.status"
        static let digestPrefix = "extraction.packages.digest"
        static let registrationPrefix = "extraction.packages.registration"
        static let importButton = "extraction.packages.import.button"
        static let trustWarning = "extraction.packages.import.trust"
        static let configurePrefix = "extraction.packages.configure"
        /// Removal targets the table's selection, so it is one control rather
        /// than one per row.
        static let removeButton = "extraction.packages.remove"
        static let progress = "extraction.packages.progress"
        static let diagnostic = "extraction.packages.diagnostic"
        static let error = "extraction.packages.error"
    }

    // MARK: - ACP configuration dialog

    /// The ACP provider picker, presented in a dialog (macos-design:
    /// progressive disclosure). Edits persist through the parent's auto-save
    /// exactly as the inline section did.
    struct ACPConfigurationDialog: View {
        @Binding var providerSelection: String
        let enabledProviders: [AgentProvider]
        let onPersist: () -> Void
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            VStack(spacing: 0) {
                Form {
                    Section {
                        Picker("Provider", selection: $providerSelection) {
                            Text("Default (use app's default provider)").tag("")
                            ForEach(enabledProviders, id: \.id) { provider in
                                Text(provider.label).tag(provider.id.rawValue)
                            }
                        }
                        .onChange(of: providerSelection) { onPersist() }
                    } header: {
                        Text("ACP Provider")
                    } footer: {
                        Text("Delegates PDF extraction to your configured ACP provider. Reuses the API key from Settings → Providers — no separate credentials needed. The provider reads the PDF from disk and returns markdown. Choose \"Default\" to use the same provider as chat and ingest.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                dialogFooter
            }
            .frame(width: ExtractionSettingsView.Metrics.dialogWidth,
                   height: ExtractionSettingsView.Metrics.dialogHeight)
        }

        private var dialogFooter: some View {
            HStack {
                Spacer()
                Button("Done") {
                    onPersist()
                    dismiss()
                }
            }
            .padding(12)
        }
    }

    struct CredentialAuthorizationConfiguration: View {
        let requirements: [ExtractorCredentialRequirementSummary]
        let authorizeRequirement: (@Sendable (ExtractorCredentialRequirementSummary) async -> ExtractorPackageMutationOutcome)?
        let revokeRequirement: (@Sendable (ExtractorCredentialRequirementSummary) async -> ExtractorPackageMutationOutcome)?
        let onCredentialMutation: (ExtractorPackageMutationOutcome?) async -> Void
        @State private var authorizationCandidate: ExtractorCredentialRequirementSummary?
        @State private var revocationCandidate: ExtractorCredentialRequirementSummary?

        var body: some View {
            Section {
                ForEach(requirements) { summary in
                    ExtractionSettingsView.requirementRow(
                        summary,
                        authorizeRequirement: authorizeRequirement,
                        revokeRequirement: revokeRequirement,
                        authorizationCandidate: $authorizationCandidate,
                        revocationCandidate: $revocationCandidate)
                }
            } header: {
                Text("Credential Access")
            } footer: {
                Text("The package receives only credentials that you authorize. Credential values stay in your Keychain and are never shown here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .modifier(AuthorizationConfirmationModifier(
                candidate: $authorizationCandidate,
                authorize: authorizeRequirement,
                onOutcome: onCredentialMutation))
            .modifier(RevocationConfirmationModifier(
                candidate: $revocationCandidate,
                revoke: revokeRequirement,
                onOutcome: onCredentialMutation))
        }
    }

    struct PackageConfigurationDialog: View {
        let title: String
        let requirements: [ExtractorCredentialRequirementSummary]
        let authorizeRequirement: (@Sendable (ExtractorCredentialRequirementSummary) async -> ExtractorPackageMutationOutcome)?
        let revokeRequirement: (@Sendable (ExtractorCredentialRequirementSummary) async -> ExtractorPackageMutationOutcome)?
        let onCredentialMutation: (ExtractorPackageMutationOutcome?) async -> Void
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            VStack(spacing: 0) {
                Form {
                    Section {
                        Text(title)
                            .font(.headline)
                    }
                    CredentialAuthorizationConfiguration(
                        requirements: requirements,
                        authorizeRequirement: authorizeRequirement,
                        revokeRequirement: revokeRequirement,
                        onCredentialMutation: onCredentialMutation)
                }
                .formStyle(.grouped)
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                }
                .padding(12)
            }
            .frame(width: ExtractionSettingsView.Metrics.dialogWidth,
                   height: ExtractionSettingsView.Metrics.dialogHeight)
        }
    }

    // MARK: - Docling configuration dialog

    /// Endpoint, timeout, write-only token, authorization, and Test Connection.
    /// in a dialog (macos-design: progressive disclosure).
    struct DoclingConfigurationDialog: View {
        @Binding var endpoint: String
        @Binding var timeoutSeconds: String
        @Binding var tokenDraft: String
        let tokenConfigured: Bool
        @Binding var testPhase: ExtractionSettingsView.TestPhase
        let requirements: [ExtractorCredentialRequirementSummary]
        let authorizeRequirement: (@Sendable (ExtractorCredentialRequirementSummary) async -> ExtractorPackageMutationOutcome)?
        let revokeRequirement: (@Sendable (ExtractorCredentialRequirementSummary) async -> ExtractorPackageMutationOutcome)?
        let onCredentialMutation: (ExtractorPackageMutationOutcome?) async -> Void
        let onPersist: () -> Void
        let onSaveToken: () -> Void
        let onRemoveToken: () -> Void
        let onTestConnection: () -> Void
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            VStack(spacing: 0) {
                Form {
                    doclingDialogFields
                    if requirements.isEmpty == false {
                        CredentialAuthorizationConfiguration(
                            requirements: requirements,
                            authorizeRequirement: authorizeRequirement,
                            revokeRequirement: revokeRequirement,
                            onCredentialMutation: onCredentialMutation)
                    }
                    testRow
                }
                .formStyle(.grouped)
                dialogFooter
            }
            .frame(width: ExtractionSettingsView.Metrics.dialogWidth,
                   height: ExtractionSettingsView.Metrics.dialogHeight)
        }

        @ViewBuilder private var testRow: some View {
            HStack(spacing: 10) {
                Button("Test Connection", action: onTestConnection)
                    .disabled(testPhase == .testing)
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

        @ViewBuilder private var doclingDialogFields: some View {
            Section {
                TextField("Endpoint", text: $endpoint, prompt: Text(ExtractionConfig.defaultDoclingServeEndpoint))
                    .onChange(of: endpoint) { onPersist() }
                TextField("Timeout (seconds)", text: $timeoutSeconds, prompt: Text("600"))
                    .onChange(of: timeoutSeconds) { onPersist() }
                // Write-only token entry (#1159): the field starts blank and
                // never shows the stored token; Save/Remove are explicit.
                SecureField("API Token (optional)", text: $tokenDraft, prompt: Text(tokenConfigured ? "Configured — enter a new token to replace" : "Enter token"))
                    .accessibilityIdentifier("extraction.docling.token.field")
                HStack {
                    Group {
                        if tokenConfigured {
                            Label("Token configured", systemImage: "checkmark.seal")
                        } else {
                            Text("No token stored")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("extraction.docling.token.status")
                    Spacer()
                    Button("Save Token") { onSaveToken() }
                        .disabled(CredentialValue.normalized(tokenDraft) == nil)
                        .accessibilityIdentifier("extraction.docling.token.save")
                    Button("Remove Token", role: .destructive) { onRemoveToken() }
                        .disabled(!tokenConfigured)
                        .accessibilityIdentifier("extraction.docling.token.remove")
                }
            } header: {
                Text("Docling Serve")
            } footer: {
                Text("Run `docling-serve run` locally, then point this at its base URL. Saving stores the token in your Keychain. Authorizing below separately lets the package use that stored token.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        private var dialogFooter: some View {
            HStack {
                Spacer()
                Button("Done") {
                    onPersist()
                    dismiss()
                }
            }
            .padding(12)
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

    /// Persist every non-secret draft into `ExtractionConfig`. Called from
    /// each field's `.onChange`, so the panel is always up to date — no Save
    /// button, no lost-on-close window. The Docling token is NOT here: it is
    /// write-only (#1159) with explicit Save/Remove buttons.
    private func persistAll() {
        var config = ExtractionConfig.load(from: containerDirectory)
        writeConfig(into: &config)
        DebugLog.trying("save extraction config", operation: { try config.save(to: containerDirectory) })
    }

    /// Explicit token save (write-only authority): normalized write, then
    /// clear the draft and refresh the configured state.
    private func saveDoclingToken() {
        guard let value = CredentialValue.normalized(doclingTokenText),
              let reference = CredentialReference.extraction(.doclingServeToken)
        else { return }
        DebugLog.trying("set Docling token", operation: {
            try credentials.set(value, for: reference)
        })
        doclingTokenText = ""
        doclingTokenConfigured = refreshDoclingTokenState()
    }

    /// Explicit removal — an untouched blank field never deletes the token.
    private func removeDoclingToken() {
        guard let reference = CredentialReference.extraction(.doclingServeToken) else { return }
        DebugLog.trying("remove Docling token", operation: {
            try credentials.unset(reference)
        })
        doclingTokenText = ""
        doclingTokenConfigured = refreshDoclingTokenState()
    }

    private func refreshDoclingTokenState() -> Bool {
        guard let reference = CredentialReference.extraction(.doclingServeToken) else {
            return false
        }
        return credentials.describe(reference).isConfigured
    }

    /// Write every non-secret draft into `config`. The route selections are
    /// not here — each table picker writes through
    /// `ExtractorRouteSettingsMapping.write` the moment it changes.
    private func writeConfig(into config: inout ExtractionConfig) {
        config.acpProviderId = acpProviderSelection.isEmpty ? nil : acpProviderSelection
        let endpoint = doclingEndpointText.trimmingCharacters(in: .whitespacesAndNewlines)
        config.doclingServeEndpoint = endpoint.isEmpty ? nil : endpoint
        let timeoutText = doclingTimeoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Int(timeoutText), seconds > 0 {
            config.doclingServeTimeoutMilliseconds = seconds * 1_000
        } else {
            config.doclingServeTimeoutMilliseconds = nil
        }
        config.podcastBackend = draftPodcastBackend
    }

    // MARK: - Test Connection

    /// Host-owned action: the view passes only the endpoint; the stored token
    /// resolves OUTSIDE the view and the outcome is redacted.
    private func testDocling(completion: (@MainActor () -> Void)? = nil) {
        guard doclingTest != .testing else { return }
        doclingTest = .testing
        let endpoint = doclingEndpointText.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = verifyDoclingConnection
        Task { @MainActor in
            if let failureMessage = await action(endpoint) {
                doclingTest = .failed(failureMessage)
            } else {
                doclingTest = .succeeded
            }
            completion?()
        }
    }

    private func announceAccessibility(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: message])
    }

    private enum Metrics {
        /// Four route-table columns (Format 90+, Default extractor 220+,
        /// Status 110+, Configuration 110+) need this minimum to display
        /// without truncating the Status column.
        static let width: CGFloat = 700
        /// Connected-service configuration dialogs (macos-design: a compact
        /// modal form with a Done button).
        static let dialogWidth: CGFloat = 460
        static let dialogHeight: CGFloat = 380
        static let statusDialogWidth: CGFloat = 520
        /// A fixed height tall enough for the multi-line footers and so that
        /// switching backends (sections of different heights) doesn't resize
        /// the window. A short section just leaves space below it.
        static let height: CGFloat = 420
        static let paneSwitcherWidth: CGFloat = 320
        static let paneSwitcherTopPadding: CGFloat = 12
        static let packageSectionSpacing: CGFloat = 10
        static let packageActionBarSpacing: CGFloat = 6
        static let packageDetailSpacing: CGFloat = 6
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
    /// PDF only: Docling Serve via the reviewed revision 2 package (#1159).
    case reviewedDocling
    /// DOCX only: the reviewed docx2md package (the only DOCX execution path).
    case reviewedDocx2md
    case installed(LogicalExtractorReference)
    /// A saved installed selection whose package is no longer active.
    case unavailableInstalled(LogicalExtractorReference)
    /// PDF only: ACP or Docling Serve.
    case connectedService(ExtractionBackend)
    /// HTML only: the built-in tag-based extractor.
    case builtInTagBased
}

/// Maps between `ExtractionConfig` (the generic route-record table) and the
/// route-scoped view selection, and writes a table pick back through
/// `setExtractorSelection`. The retired `backend` / `htmlBackend` fields are
/// decode-only migration inputs — nothing here reads or writes them. Legacy
/// host identities (a migrated `localPdf2md` / `doclingServe` / `defuddle`
/// value) display as their reviewed-package choice.
enum ExtractorRouteSettingsMapping {
    /// The view selection for one route, applying the same display semantics
    /// the fixed pickers used (a legacy `localPdf2md` selection displays as
    /// the reviewed package; retired direct-API selections display as ACP).
    static func selection(
        route: ExtractorRouteID,
        config: ExtractionConfig,
        row: ExtractorRouteSettingsRow
    ) -> ExtractorRouteSettingsSelection {
        let saved = config.extractorSelection(for: route)
        if route == .canonicalPDF {
            switch saved {
            case .installed(let logical):
                if logical == ProcessExtractionServices.reviewedPDFLogical {
                    return .reviewedPdf2md
                }
                if logical == ProcessExtractionServices.reviewedDoclingLogical {
                    return .reviewedDocling
                }
                return installedSelection(logical, row: row)
            case .host(let host):
                switch ExtractorRouteHostCatalog.role(forHostAdapterID: host.adapterID) {
                case .connectedServiceACP, .retiredDirectAnthropicAPI, .retiredDirectGeminiAPI:
                    // Retired direct-API selections display as their ACP
                    // successor; execution no longer consults them.
                    return .connectedService(.acp)
                case .doclingLineage:
                    return .reviewedDocling
                case .pdf2mdLineage:
                    return .reviewedPdf2md
                default:
                    return .prompt
                }
            case .some(ExtractionBackendReference.none):
                // An explicit disable is a real state: display no-selection
                // instead of the healthy default.
                return .prompt
            case nil:
                // No record: the bundled default record supplies the
                // reviewed pdf2md lineage, so the display matches it.
                return .reviewedPdf2md
            }
        }
        if route == .canonicalHTML {
            switch saved {
            case .installed(let logical):
                return logical == ProcessExtractionServices.reviewedHTMLLogical
                    ? .reviewedDefuddle
                    : installedSelection(logical, row: row)
            case .host(let host):
                switch ExtractorRouteHostCatalog.role(forHostAdapterID: host.adapterID) {
                case .defuddleLineage:
                    return .reviewedDefuddle
                case .builtInTagBased:
                    return .builtInTagBased
                default:
                    return .prompt
                }
            default:
                return .prompt
            }
        }
        if route == .canonicalDOCX {
            switch saved {
            case .installed(let logical):
                return logical == ProcessExtractionServices.reviewedDOCXLogical
                    ? .reviewedDocx2md
                    : installedSelection(logical, row: row)
            default:
                // No built-in DOCX backend exists: "no default" displays as
                // "use the reviewed package" (execution resolves to it).
                return .prompt
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

    /// Persists one table pick. The reference is generic: a reviewed pick
    /// writes the package lineage, a connected-service or tag-based pick
    /// writes a host reference, and the prompt choice writes the explicit
    /// `.none` record so the bundled default policy does not refill it.
    static func write(
        _ selection: ExtractorRouteSettingsSelection,
        route: ExtractorRouteID,
        into config: inout ExtractionConfig
    ) {
        let reference: ExtractionBackendReference?
        if route == .canonicalPDF {
            switch selection {
            case .reviewedPdf2md:
                reference = .installed(ProcessExtractionServices.reviewedPDFLogical)
            case .reviewedDocling:
                reference = .installed(ProcessExtractionServices.reviewedDoclingLogical)
            case .installed(let logical), .unavailableInstalled(let logical):
                reference = .installed(logical)
            case .connectedService:
                reference = ExtractorRouteHostCatalog.acpReference
            case .prompt, .reviewedDefuddle, .reviewedDocx2md, .builtInTagBased:
                return
            }
        } else if route == .canonicalHTML {
            switch selection {
            case .prompt:
                reference = .some(.none)
            case .reviewedDefuddle:
                reference = .installed(ProcessExtractionServices.reviewedHTMLLogical)
            case .installed(let logical), .unavailableInstalled(let logical):
                reference = .installed(logical)
            case .builtInTagBased:
                reference = ExtractorRouteHostCatalog.tagBasedReference
            case .reviewedPdf2md, .reviewedDocling, .reviewedDocx2md, .connectedService:
                return
            }
        } else if route == .canonicalDOCX {
            switch selection {
            case .reviewedDocx2md:
                reference = .installed(ProcessExtractionServices.reviewedDOCXLogical)
            case .installed(let logical), .unavailableInstalled(let logical):
                reference = .installed(logical)
            case .prompt:
                // "No default (use the reviewed package)": the explicit
                // record states the reviewed-lineage default instead of
                // relying on the bundled policy to refill it.
                reference = .some(.none)
            default:
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
        // A legacy migrated direct-API selection (anthropic / gemini) prefills
        // its ACP successor's provider; every other selection keeps the
        // stored provider draft.
        if case .host(let host)? = config.selectionOrDefault(for: .canonicalPDF) {
            switch ExtractorRouteHostCatalog.role(forHostAdapterID: host.adapterID) {
            case .retiredDirectAnthropicAPI:
                return claudeACPProviderID.rawValue
            case .retiredDirectGeminiAPI:
                return geminiACPProviderID.rawValue
            default:
                break
            }
        }
        return config.acpProviderId ?? ""
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
    var availableRegistrationSnapshots: [ExtractorRouteRegistrationSnapshot] = []
    var waitingRevisionIDs: Set<ExtractorPackageRevisionID> = []
    /// Credential requirement summaries (#1159): presentation values only —
    /// label, purpose, optionality, configured/missing state, source, and
    /// authorization state. No secret values, no Keychain locations, no
    /// package paths, no resolver.
    var credentialRequirements: [ExtractorCredentialRequirementSummary] = []

    static let empty = ExtractorPackageSettingsSnapshot()

    /// Catalog entries own picker presentation. Active entries fill gaps if a
    /// catalog read fails or changes during a refresh.
    var routeChoiceRegistrationSnapshots: [ExtractorRouteRegistrationSnapshot] {
        var byReference = Dictionary(
            uniqueKeysWithValues: registrationSnapshots.map { ($0.reference, $0) })
        for snapshot in availableRegistrationSnapshots {
            byReference[snapshot.reference] = snapshot
        }
        return byReference.values.sorted { $0.reference < $1.reference }
    }
}

/// One declared credential requirement as presented in Installed Extractor
/// Packages (#1159, plan steps 20-24). Identity fields are package- and
/// requirement-derived so rows and controls have stable accessibility
/// identifiers.
struct ExtractorCredentialRequirementSummary: Identifiable, Hashable, Sendable {
    enum AuthorizationState: Hashable, Sendable {
        /// A grant exists and matches the declared contract fingerprint.
        case authorized
        /// No grant for this lineage + requirement.
        case needsAuthorization
        /// A grant exists but the contract fingerprint changed — the user
        /// must re-authorize (AC.16).
        case changedContract
    }

    let packageID: String
    let packageName: String
    let packageVersion: String
    let registrationID: String
    let requirementID: String
    let label: String
    let purpose: String
    let isOptional: Bool
    let isConfigured: Bool
    let sourceName: String
    let authorizationState: AuthorizationState
    /// The declared registration scope (sorted, non-secret) — the same parts
    /// the authorization writer pins into the contract fingerprint.
    let kinds: [String]
    let mimeTypes: [String]

    var id: String { "\(packageID)/\(registrationID)/\(requirementID)" }

    var authorizationStateText: String {
        switch authorizationState {
        case .authorized: return "Authorized"
        case .needsAuthorization: return "Needs authorization"
        case .changedContract: return "Changed — re-authorization needed"
        }
    }
}

/// The two jobs Settings → Extraction does. They are separate panes because
/// only one is needed at a time: choosing what opens a document type, and
/// managing the packages those choices draw from.
enum ExtractionSettingsPane: String, CaseIterable, Identifiable, Hashable, Sendable {
    case defaults
    case packages

    var id: String { rawValue }

    var title: String {
        switch self {
        case .defaults: "Defaults"
        case .packages: "Packages"
        }
    }
}

/// One row of the Default Extractors table. A packaged extraction route and the
/// podcast transcript default are different operation domains: a route resolves
/// through the package protocol's registrations and writes an
/// `ExtractorRouteSettingsSelection`, while a transcript resolves through a host
/// adapter and writes a `PodcastTranscriptionBackend`. They share a table but
/// not a selection type and not an id space, so the case tag is what lets one
/// table show both without either pretending to be the other.
enum ExtractionDefaultsTableRow: Identifiable, Hashable, Sendable {
    case route(ExtractorRouteSettingsRow)
    /// Carries the current choice so the table diffs when the user changes it.
    case podcastTranscript(PodcastTranscriptionBackend?)

    var id: String {
        switch self {
        case .route(let row): "route/\(row.id)"
        case .podcastTranscript: "transcript/podcast"
        }
    }
}

/// What one installed extractor package revision can do right now. The snapshot
/// keeps the facts apart — active registrations, revisions whose activation
/// failed, revisions still waiting, and per-requirement authorization state —
/// but the table has to present one answer, so this resolves them in precedence
/// order once and every column and explanation reads from it.
enum ExtractorPackageStatus: Hashable, Sendable {
    case active
    /// The revision is installed but its plugin has not activated yet.
    case waitingForActivation
    /// Activation failed in this process. The payload is the reconciler's
    /// already-redacted message.
    case notReady(String)
    /// Active, but a required credential has no grant, so the package cannot
    /// run until the user authorizes it.
    case needsAuthorization

    /// The short Status column label. The icon carries the state, so the
    /// sentence lives in ``explanation``.
    var label: String {
        switch self {
        case .active: "Active"
        case .waitingForActivation: "Waiting"
        case .notReady: "Not ready"
        case .needsAuthorization: "Needs authorization"
        }
    }

    var systemImage: String {
        switch self {
        case .active: "checkmark.circle.fill"
        case .waitingForActivation: "clock"
        case .notReady: "xmark.octagon.fill"
        case .needsAuthorization: "key.fill"
        }
    }

    var tint: Color {
        switch self {
        case .active: .green
        case .waitingForActivation: .secondary
        case .notReady: .red
        case .needsAuthorization: .orange
        }
    }

    /// The inline diagnostic shown with the package it belongs to. A failed
    /// activation carries the reconciler's own text, which is why this is a
    /// value and not a fixed table.
    var explanation: String {
        switch self {
        case .active:
            "This revision is active. Routes can select it."
        case .waitingForActivation:
            "This revision is installed and waiting to activate."
        case .notReady(let message):
            message
        case .needsAuthorization:
            "A required credential is not authorized yet. Configure the package to authorize it."
        }
    }
}

/// One row of the installed extractor package table. It folds the snapshot's
/// two lists into one presentation identity: an active registration and a
/// revision whose activation failed do not share an id space, so the case tag
/// is what stops a failure id from colliding with a registration id.
struct ExtractorPackageTableRow: Identifiable, Hashable, Sendable {
    enum Subject: Hashable, Sendable {
        case installed(ExtractorPackageSettingsRow)
        case failed(ExtractorPackageFailureSummary)
    }

    let subject: Subject
    let status: ExtractorPackageStatus

    var id: String {
        switch subject {
        case .installed(let row): "installed/\(row.id)"
        case .failed(let failure): "failed/\(failure.id)"
        }
    }

    var packageID: String {
        switch subject {
        case .installed(let row): row.packageID
        case .failed(let failure): failure.packageID
        }
    }

    var version: String {
        switch subject {
        case .installed(let row): row.version
        case .failed(let failure): failure.version
        }
    }

    var digestPrefix: String {
        switch subject {
        case .installed(let row): row.digestPrefix
        case .failed(let failure): failure.digestPrefix
        }
    }

    /// Only an active registration has one. A failed revision resolved to no
    /// backend, so it registered nothing.
    var registrationID: String? {
        guard case .installed(let row) = subject else { return nil }
        return row.registrationID
    }

    /// The exact installed row, when this is one. Removal and credential
    /// configuration both need it, and neither applies to a failed revision.
    var installedRow: ExtractorPackageSettingsRow? {
        guard case .installed(let row) = subject else { return nil }
        return row
    }

    var kind: ExtractionBackendKind? {
        installedRow?.kind
    }
}

/// Where a package settings outcome belongs. A package-scoped outcome renders
/// with the row it describes; the pane scope is for outcomes no row owns — an
/// import that produced nothing, or a removal whose row has already gone.
enum ExtractorPackageNoticeScope: Hashable, Sendable {
    case pane
    case package(ExtractorPackageTableRow.ID)
}

/// One package settings outcome, kept scoped so the message renders next to the
/// package it is about rather than in a shared diagnostics area.
struct ExtractorPackageNotice: Hashable, Sendable {
    enum Severity: Hashable, Sendable {
        case success
        case failure
    }

    let severity: Severity
    let message: String
    let scope: ExtractorPackageNoticeScope
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

/// The Authorize / Re-authorize / Change Credential confirmation (#1159).
/// Its message states the inheritance rule BEFORE approval: a future
/// revision of the same package keeps the grant only while the requirement
/// contract stays unchanged.
struct AuthorizationConfirmationModifier: ViewModifier {
    @Binding var candidate: ExtractorCredentialRequirementSummary?
    let authorize: (@Sendable (ExtractorCredentialRequirementSummary) async -> ExtractorPackageMutationOutcome)?
    let onOutcome: (ExtractorPackageMutationOutcome?) async -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Authorize credential use?",
            isPresented: Binding(
                get: { candidate != nil },
                set: { if !$0 { candidate = nil } }),
            titleVisibility: .visible,
            presenting: candidate) { summary in
                Button("Authorize") {
                    candidate = nil
                    Task {
                        let outcome = await authorize?(summary)
                        await onOutcome(outcome)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { summary in
                Text(ExtractionSettingsView.authorizationConfirmationMessage(summary))
            }
    }
}

/// The Revoke confirmation (#1159): explicit and destructive for the GRANT —
/// the stored credential itself is never deleted, and the record stays
/// attached to its package lineage.
struct RevocationConfirmationModifier: ViewModifier {
    @Binding var candidate: ExtractorCredentialRequirementSummary?
    let revoke: (@Sendable (ExtractorCredentialRequirementSummary) async -> ExtractorPackageMutationOutcome)?
    let onOutcome: (ExtractorPackageMutationOutcome?) async -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Revoke credential authorization?",
            isPresented: Binding(
                get: { candidate != nil },
                set: { if !$0 { candidate = nil } }),
            titleVisibility: .visible,
            presenting: candidate) { summary in
                Button("Revoke", role: .destructive) {
                    candidate = nil
                    Task {
                        let outcome = await revoke?(summary)
                        await onOutcome(outcome)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { summary in
                Text("Revoke \(summary.packageName)'s use of \(summary.label)? The package will not receive this credential until you authorize it again. The stored credential itself is not deleted.")
            }
    }
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
        case .reviewedLineageReserved:
            return "This package claims a reserved built-in package identity with different contents and cannot be installed."
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
    /// The single latest outcome. Severity and scope are derived from it rather
    /// than tracked as parallel fields, so an error cannot outlive the success
    /// that replaced it.
    private(set) var notice: ExtractorPackageNotice?

    var lastError: String? {
        guard let notice, notice.severity == .failure else { return nil }
        return notice.message
    }

    var lastDiagnostic: String? {
        guard let notice, notice.severity == .success else { return nil }
        return notice.message
    }

    /// Every installed revision the snapshot holds, active and failed alike,
    /// each carrying the status that explains it.
    var tableRows: [ExtractorPackageTableRow] { Self.tableRows(from: snapshot) }

    func notice(for row: ExtractorPackageTableRow) -> ExtractorPackageNotice? {
        guard let notice, notice.scope == .package(row.id) else { return nil }
        return notice
    }

    var paneNotice: ExtractorPackageNotice? {
        guard let notice, notice.scope == .pane else { return nil }
        return notice
    }

    /// Surfaces a redacted failure from an app-owned authorization mutation
    /// (#1159) through the same diagnostics path as import/remove.
    func reportFailure(_ message: String) {
        notice = ExtractorPackageNotice(severity: .failure, message: message, scope: .pane)
    }

    /// Folds the snapshot's active registrations and failed revisions into one
    /// ordered list. Failed revisions sort first: they are the rows a user
    /// opened this pane to understand.
    static func tableRows(
        from snapshot: ExtractorPackageSettingsSnapshot
    ) -> [ExtractorPackageTableRow] {
        let failed = snapshot.failedPackages.map { failure in
            ExtractorPackageTableRow(subject: .failed(failure), status: .notReady(failure.message))
        }
        let installed = snapshot.rows.map { row in
            ExtractorPackageTableRow(
                subject: .installed(row),
                status: status(for: row, in: snapshot))
        }
        return failed + installed
    }

    /// Precedence: a revision that has not activated cannot be judged on its
    /// credentials, so waiting outranks authorization state.
    private static func status(
        for row: ExtractorPackageSettingsRow,
        in snapshot: ExtractorPackageSettingsSnapshot
    ) -> ExtractorPackageStatus {
        if snapshot.waitingRevisionIDs.contains(row.revision) { return .waitingForActivation }
        let unauthorized = snapshot.credentialRequirements.contains { requirement in
            requirement.packageID == row.packageID
                && requirement.packageVersion == row.version
                && requirement.registrationID == row.registrationID
                && requirement.isOptional == false
                && requirement.authorizationState != .authorized
        }
        return unauthorized ? .needsAuthorization : .active
    }

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
        notice = nil
        let known = Set(tableRows.map(\.id))
        let outcome = await importAction(directory)
        isBusy = false
        busyMessage = nil
        await refresh()
        // Scope the outcome to the row the import produced, so the
        // confirmation lands on the new package. An import that added no
        // visible row falls back to the pane.
        let added = tableRows.map(\.id).filter { known.contains($0) == false }
        apply(
            outcome,
            successDiagnostic: "Extractor package installed.",
            scope: added.count == 1 ? .package(added[0]) : .pane)
    }

    func remove(_ row: ExtractorPackageSettingsRow) async {
        guard let removeAction, !isBusy else { return }
        isBusy = true
        busyMessage = Self.removingMessage
        notice = nil
        let outcome = await removeAction(row.revision)
        isBusy = false
        busyMessage = nil
        await refresh()
        // A successful removal leaves no row to carry the message. A failure
        // does, so it reports on the package it could not remove.
        let scope: ExtractorPackageNoticeScope = {
            guard case .failed = outcome else { return .pane }
            let id = ExtractorPackageTableRow(subject: .installed(row), status: .active).id
            return tableRows.contains { $0.id == id } ? .package(id) : .pane
        }()
        apply(
            outcome,
            successDiagnostic: "Removed \(row.packageID) \(row.version).",
            scope: scope)
    }

    func reportImportSelectionError() {
        notice = ExtractorPackageNotice(
            severity: .failure,
            message: ExtractorSettingsPackagePicker.selectionErrorMessage,
            scope: .pane)
    }

    private func apply(
        _ outcome: ExtractorPackageMutationOutcome,
        successDiagnostic: String,
        scope: ExtractorPackageNoticeScope
    ) {
        switch outcome {
        case .succeeded(let diagnostic):
            notice = ExtractorPackageNotice(
                severity: .success,
                message: diagnostic ?? successDiagnostic,
                scope: scope)
        case .failed(let message):
            notice = ExtractorPackageNotice(severity: .failure, message: message, scope: scope)
        }
    }
}
