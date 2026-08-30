#if os(macOS)
import Foundation
import Testing
import WikiFSCore
import WikiFSEngine
@testable import WikiFS

/// Phase 6/7 seams: the installed-package lifecycle snapshot behind
/// Settings → Extraction, the settings model that presents it (including
/// app-only import/removal), and the accessibility + decoupling source
/// contract for the section.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct ExtractorPackageSettingsTests {
    // MARK: - Registry snapshot

    @Test("installedPackageRows lists only installed PDF/HTML admissions with exact identity")
    func snapshotListsInstalledRegistrationsOnly() async throws {
        let registry = ExtractionBackendRegistry()
        let pdfReference = try reference(
            packageID: "org.example.pdfpkg",
            version: "1.2.0",
            digestHex: String(repeating: "a", count: 64))
        let htmlReference = ExtractorReference(
            revision: pdfReference.revision,
            registrationID: try ExtractorRegistrationID(validating: "html"))

        _ = try await registry.registerBatch([
            ExtractionBatchEntry(
                key: .installed(kind: .pdf, reference: pdfReference),
                backend: stubPDFBackend()),
            ExtractionBatchEntry(
                key: .installed(kind: .html, reference: htmlReference),
                backend: stubHTMLBackend()),
            // Built-in adapters are picker territory, never package rows.
            ExtractionBatchEntry(
                key: .builtIn(ExtractionBackendKey(kind: .pdf, backendID: "localPdf2md")),
                backend: stubPDFBackend()),
        ])

        let rows = await registry.installedPackageRows()

        #expect(rows.count == 2)
        #expect(rows.contains(ExtractorPackageSettingsRow(
            kind: .pdf,
            packageID: "org.example.pdfpkg",
            version: "1.2.0",
            digestPrefix: String(repeating: "a", count: 12),
            registrationID: "pdf",
            revision: pdfReference.revision)))
        #expect(rows.contains(ExtractorPackageSettingsRow(
            kind: .html,
            packageID: "org.example.pdfpkg",
            version: "1.2.0",
            digestPrefix: String(repeating: "a", count: 12),
            registrationID: "html",
            revision: pdfReference.revision)))
        // Deterministic order across kinds.
        #expect(rows.map(\.id) == rows.map(\.id).sorted())
    }

    @Test("installedPackageRows is empty for a registry with no installed revisions")
    func snapshotEmptyWithoutInstalledRevisions() async {
        let registry = ExtractionBackendRegistry()

        let rows = await registry.installedPackageRows()

        #expect(rows.isEmpty)
    }

    // MARK: - Route-scoped extractor selection mapping

    /// Derives the view selection for one canonical route from a config,
    /// using the real builder output for the row context.
    private func routeSelection(
        _ route: ExtractorRouteID,
        from config: ExtractionConfig
    ) -> ExtractorRouteSettingsSelection {
        let row = ExtractorRouteTableBuilder.build(.init(
            configuration: config,
            registrations: []))
            .first { $0.route == route }!
        return ExtractorRouteSettingsMapping.selection(route: route, config: config, row: row)
    }

    @Test("legacy reviewed selections appear as reviewed packages")
    func legacyReviewedSelectionsMapToPackages() {
        var config = ExtractionConfig()
        config.backend = .localPdf2md
        config.htmlBackend = .defuddle

        #expect(routeSelection(.canonicalPDF, from: config) == .reviewedPdf2md)
        #expect(routeSelection(.canonicalHTML, from: config) == .reviewedDefuddle)
    }

    @Test("host service selections keep legacy fields truthful")
    func hostSelectionsWriteBothCompatibilityDomains() {
        var config = ExtractionConfig()

        ExtractorRouteSettingsMapping.write(.connectedService(.acp), route: .canonicalPDF, into: &config)
        ExtractorRouteSettingsMapping.write(.builtInTagBased, route: .canonicalHTML, into: &config)

        #expect(config.backend == .acp)
        #expect(config.pdfExtractor == .builtIn(.pdf(.acp)))
        #expect(config.htmlBackend == .tagBased)
        #expect(config.htmlExtractor == .builtIn(.html(.tagBased)))
    }

    @Test("new UI surfaces exclude direct API backends")
    func userSelectableBackendsUseACP() {
        #expect(ExtractionBackend.userSelectableCases == [.localPdf2md, .acp, .doclingServe])
        #expect(ExtractionBackend.allCases.contains(.anthropic))
        #expect(ExtractionBackend.allCases.contains(.gemini))
    }

    @Test("legacy direct API selections migrate to their ACP providers")
    func directAPISelectionsMapToACP() throws {
        var anthropic = ExtractionConfig()
        anthropic.backend = .anthropic
        var gemini = ExtractionConfig()
        gemini.pdfExtractor = .builtIn(.pdf(.gemini))

        #expect(routeSelection(.canonicalPDF, from: anthropic) == .connectedService(.acp))
        #expect(ExtractorSettingsSelectionMapping.acpProviderSelection(from: anthropic) == "claude-acp")
        #expect(routeSelection(.canonicalPDF, from: gemini) == .connectedService(.acp))
        #expect(ExtractorSettingsSelectionMapping.acpProviderSelection(from: gemini) == "gemini")
    }

    @Test("reviewed package selections write reviewed logical identities")
    func reviewedSelectionsWriteLogicalPackageReferences() {
        var config = ExtractionConfig()

        ExtractorRouteSettingsMapping.write(.reviewedPdf2md, route: .canonicalPDF, into: &config)
        ExtractorRouteSettingsMapping.write(.reviewedDefuddle, route: .canonicalHTML, into: &config)

        #expect(config.backend == .localPdf2md)
        #expect(config.pdfExtractor == .installed(ProcessExtractionServices.reviewedPDFLogical))
        #expect(config.htmlBackend == .defuddle)
        #expect(config.htmlExtractor == .installed(ProcessExtractionServices.reviewedHTMLLogical))
        // The canonical route records dual-write with the legacy fields.
        #expect(config.extractorSelection(for: .canonicalPDF) == .installed(ProcessExtractionServices.reviewedPDFLogical))
        #expect(config.extractorSelection(for: .canonicalHTML) == .installed(ProcessExtractionServices.reviewedHTMLLogical))
    }

    @Test("installed selections preserve legacy fallback fields")
    func installedSelectionsPreserveFallbacks() throws {
        let pdf = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.example.pdf"),
            registrationID: try ExtractorRegistrationID(validating: "document"))
        let html = LogicalExtractorReference(
            packageID: try ExtractorPackageID(validating: "org.example.html"),
            registrationID: try ExtractorRegistrationID(validating: "article"))
        var config = ExtractionConfig()
        config.backend = .anthropic
        config.htmlBackend = .tagBased

        ExtractorRouteSettingsMapping.write(.installed(pdf), route: .canonicalPDF, into: &config)
        ExtractorRouteSettingsMapping.write(.installed(html), route: .canonicalHTML, into: &config)

        #expect(config.backend == .anthropic)
        #expect(config.pdfExtractor == .installed(pdf))
        #expect(config.htmlBackend == .tagBased)
        #expect(config.htmlExtractor == .installed(html))
    }

    @Test("HTML prompt clears both compatibility fields")
    func htmlPromptClearsSelection() {
        var config = ExtractionConfig()
        config.htmlBackend = .defuddle
        config.htmlExtractor = .installed(ProcessExtractionServices.reviewedHTMLLogical)

        ExtractorRouteSettingsMapping.write(.prompt, route: .canonicalHTML, into: &config)

        #expect(config.htmlBackend == nil)
        #expect(config.htmlExtractor == nil)
        #expect(config.extractorSelection(for: .canonicalHTML) == nil)
    }

    @Test("wrong-kind persisted references defer to legacy fields")
    func wrongKindReferencesUseCompatibilityFields() {
        var config = ExtractionConfig()
        config.backend = .doclingServe
        config.pdfExtractor = .builtIn(.html(.tagBased))
        config.htmlBackend = .tagBased
        config.htmlExtractor = .builtIn(.pdf(.anthropic))

        #expect(routeSelection(.canonicalPDF, from: config) == .reviewedDocling)
        #expect(routeSelection(.canonicalHTML, from: config) == .builtInTagBased)
    }

    // MARK: - Settings model

    @Test("settings model refresh loads rows and flips hasLoaded")
    func modelRefreshLoadsRows() async {
        let row = try! settingsRow()
        let model = ExtractorPackageSettingsModel(loadSnapshot: { ExtractorPackageSettingsSnapshot(rows: [row]) })

        await model.refresh()

        #expect(model.snapshot.rows == [row])
        #expect(model.hasLoaded)
        #expect(model.isBusy == false)
    }

    @Test("settings model without a loader stays empty and unloaded")
    func modelWithoutLoaderIsNoOp() async {
        let model = ExtractorPackageSettingsModel(loadSnapshot: nil)

        await model.refresh()

        #expect(model.snapshot.rows.isEmpty)
        #expect(model.hasLoaded == false)
    }

    @Test("settings model reports failed activations and the applied generation")
    func modelExposesFailuresAndGeneration() async {
        let failure = ExtractorPackageFailureSummary(
            packageID: "org.example.pdfpkg",
            version: "2.0.0",
            digestPrefix: String(repeating: "c", count: 12),
            message: "package activation failed")
        let model = ExtractorPackageSettingsModel(loadSnapshot: {
            ExtractorPackageSettingsSnapshot(
                failedPackages: [failure],
                appliedGeneration: 7)
        })

        await model.refresh()

        #expect(model.snapshot.failedPackages == [failure])
        #expect(model.snapshot.appliedGeneration == 7)
        #expect(model.snapshot.rows.isEmpty)
    }

    @Test("import runs the action, reports the diagnostic, and refreshes")
    func importSucceedsAndRefreshes() async {
        let loads = Counter()
        let row = try! settingsRow()
        let model = ExtractorPackageSettingsModel(
            loadSnapshot: {
                await loads.increment()
                return ExtractorPackageSettingsSnapshot(rows: [row])
            },
            importPackage: { _ in .succeeded(nil) })

        await model.refresh()
        await model.importPackage(from: URL(fileURLWithPath: "/tmp/import-source"))

        let loadCount = await loads.value
        #expect(loadCount == 2) // initial refresh + post-import refresh
        #expect(model.lastDiagnostic == "Extractor package installed.")
        #expect(model.lastError == nil)
        #expect(model.isBusy == false)
        #expect(model.busyMessage == nil)
    }

    @Test("import failure surfaces a fixed error and clears the diagnostic")
    func importFailureSurfacesError() async {
        let model = ExtractorPackageSettingsModel(
            loadSnapshot: { .empty },
            importPackage: { _ in .failed("The package failed validation and was not installed.") })

        await model.refresh()
        await model.importPackage(from: URL(fileURLWithPath: "/tmp/import-source"))

        #expect(model.lastError == "The package failed validation and was not installed.")
        #expect(model.lastDiagnostic == nil)
        #expect(model.isBusy == false)
    }

    @Test("removal passes the row's exact revision to the action and refreshes")
    func removalTargetsExactRevision() async throws {
        let row = try settingsRow()
        let revisionBox = RevisionBox()
        let loads = Counter()
        let model = ExtractorPackageSettingsModel(
            loadSnapshot: {
                await loads.increment()
                return ExtractorPackageSettingsSnapshot(rows: [row])
            },
            removePackage: { revision in
                await revisionBox.set(revision)
                return .succeeded(nil)
            })

        await model.refresh()
        await model.remove(row)

        let capturedRevision = await revisionBox.value
        let loadCount = await loads.value
        #expect(capturedRevision == row.revision)
        #expect(loadCount == 2)
        #expect(model.lastDiagnostic == "Removed \(row.packageID) \(row.version).")
        #expect(model.isBusy == false)
    }

    @Test("a model without mutation closures is read-only and mutates nothing")
    func readOnlyModelIgnoresMutations() async {
        let loads = Counter()
        let model = ExtractorPackageSettingsModel(loadSnapshot: {
            await loads.increment()
            return .empty
        })

        #expect(model.canImport == false)
        #expect(model.canRemove == false)

        await model.refresh()
        await model.importPackage(from: URL(fileURLWithPath: "/tmp/import-source"))

        let loadCount = await loads.value
        #expect(loadCount == 1) // import no-oped: no extra refresh
        #expect(model.lastError == nil)
        #expect(model.lastDiagnostic == nil)
    }

    // MARK: - Mutation diagnostics

    @Test("mutation messages are fixed and path-free")
    func mutationMessagesStayPathFree() {
        let messages = [
            ExtractorPackageMutationMessage.describe(ExtractorPackageStoreError.lockTimedOut),
            ExtractorPackageMutationMessage.describe(ExtractorPackageStoreError.staleGeneration),
            ExtractorPackageMutationMessage.describe(ExtractorPackageStoreError.mutationForbidden),
            ExtractorPackageMutationMessage.describe(ExtractorDirectoryAdmissionError.sourceNotDirectory),
            ExtractorPackageMutationMessage.describe(ExtractorDirectoryAdmissionError.symlink("a/b")),
            ExtractorPackageMutationMessage.describe(URLError(.badURL)),
        ]
        for message in messages {
            #expect(message.contains("/") == false, "diagnostics must stay path-free: \(message)")
            #expect(message.isEmpty == false)
        }
        #expect(ExtractorPackageMutationMessage.describe(ExtractorPackageStoreError.lockTimedOut)
            == "The extractor store was busy. Try again in a moment.")
        #expect(ExtractorPackageMutationMessage.describe(ExtractorDirectoryAdmissionError.sourceNotDirectory)
            == "Select one local extractor package folder.")
        #expect(ExtractorPackageMutationMessage.describe(URLError(.badURL))
            == "The extractor package operation failed. See Console for details.")
    }

    // MARK: - Picker and accessibility contracts

    @Test("the extractor picker accepts one directory and rejects files, archives, and multiple selections")
    func pickerAcceptsOnlyOneDirectory() throws {
        let panel = ExtractorSettingsPackagePicker.makePanel()
        #expect(panel.canChooseDirectories)
        #expect(panel.canChooseFiles == false)
        #expect(panel.allowsMultipleSelection == false)
        #expect(panel.prompt == ExtractorSettingsPackagePicker.importButtonTitle)
        #expect(panel.message == ExtractorSettingsPackagePicker.selectionErrorMessage)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("extractor-picker-\(UUID().uuidString)", isDirectory: true)
        let packageDirectory = root.appendingPathComponent("example.extractor", isDirectory: true)
        let sourceFile = root.appendingPathComponent("extractor.js")
        let archive = root.appendingPathComponent("extractor.zip")
        defer {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                Issue.record("Temporary extractor picker fixture cleanup failed.")
            }
        }
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        try Data().write(to: sourceFile)
        try Data().write(to: archive)

        #expect(throws: ExtractorSettingsPackagePicker.PickerSelectionError.expectedOneDirectory) {
            _ = try ExtractorSettingsPackagePicker.validatedDirectory(from: [])
        }
        #expect(try ExtractorSettingsPackagePicker.validatedDirectory(from: [packageDirectory]) == packageDirectory)
        #expect(throws: ExtractorSettingsPackagePicker.PickerSelectionError.fileOrArchiveNotSupported) {
            _ = try ExtractorSettingsPackagePicker.validatedDirectory(from: [sourceFile])
        }
        #expect(throws: ExtractorSettingsPackagePicker.PickerSelectionError.fileOrArchiveNotSupported) {
            _ = try ExtractorSettingsPackagePicker.validatedDirectory(from: [archive])
        }
        #expect(throws: ExtractorSettingsPackagePicker.PickerSelectionError.expectedOneDirectory) {
            _ = try ExtractorSettingsPackagePicker.validatedDirectory(from: [packageDirectory, root])
        }
    }

    @Test("package section exposes the accessibility contract and no production PdfExtractionService wiring remains")
    func accessibilityContractAndDecouplingHold() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/WikiFS/Sources/ExtractionSettingsView.swift"),
            encoding: .utf8)

        // Phase 7.10: the lifecycle controls carry stable accessibility
        // identifiers, accessible names, and a state value.
        #expect(viewSource.contains("Installed Extractor Packages"))
        #expect(viewSource.contains("No extractor packages are installed on this Mac."))
        #expect(viewSource.contains("extraction.packages.refresh"))
        #expect(viewSource.contains("Refresh installed extractor packages"))
        #expect(viewSource.contains("extraction.packages.empty"))
        #expect(viewSource.contains("extraction.packages.row"))
        #expect(viewSource.contains("extraction.packages.digest"))
        #expect(viewSource.contains("extraction.packages.registration"))
        #expect(viewSource.contains(".accessibilityValue(\"Active\")"))
        #expect(viewSource.contains(".accessibilityLabel(\"\\(row.packageID), version \\(row.version)"))
        #expect(viewSource.contains(".accessibilityAddTraits(.updatesFrequently)"))

        // Phase 7 import/removal/readiness controls keep derivable identifiers.
        #expect(viewSource.contains("extraction.packages.import.disclosure"))
        #expect(viewSource.contains("extraction.packages.import.button"))
        #expect(viewSource.contains("extraction.packages.import.trust"))
        #expect(viewSource.contains("extraction.packages.remove"))
        #expect(viewSource.contains("extraction.packages.failure"))
        #expect(viewSource.contains("extraction.packages.failure.message"))
        #expect(viewSource.contains("extraction.routes.table"))
        #expect(viewSource.contains("extraction.routes.picker"))
        #expect(viewSource.contains("progress"))
        #expect(viewSource.contains("extraction.packages.diagnostic"))
        #expect(viewSource.contains("extraction.packages.error"))
        #expect(viewSource.contains(".accessibilityValue(\"Not ready\")"))

        // Local-directory-only import contract + executable-code trust warning.
        #expect(viewSource.contains("Advanced Local Package Import"))
        // Keep import controls in a separate top-level Form section from the
        // installed package rows.
        #expect(viewSource.contains("installedPackagesSection\n                if packageModel.canImport {\n                    packageImportSection"))
        #expect(viewSource.contains("@ViewBuilder private var packageImportSection: some View {\n        Section {"))
        #expect(viewSource.contains("Import Extractor Package…"))
        #expect(viewSource.contains("Select one local extractor package folder as an import source."))
        #expect(viewSource.contains("Files and archives are not supported."))
        #expect(viewSource.contains("Extractor packages contain executable code"))
        #expect(viewSource.contains("Remove Package…"))

        // One package-first picker per kind maps into both compatibility domains.
        #expect(viewSource.contains("Default Extractors"))
        #expect(viewSource.contains("Built-in default") == false)
        #expect(viewSource.contains("ExtractorRouteSettingsMapping.write"))
        #expect(viewSource.contains("Table(routeRows)"))
        #expect(viewSource.contains("extractorOption(\"Claude\"") == false)
        #expect(viewSource.contains("extractorOption(\"Gemini\"") == false)
        #expect(viewSource.contains("Claude (Anthropic API)") == false)
        #expect(viewSource.contains("Gemini (Google AI)") == false)
        let sourceDetailSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/WikiFS/Sources/SourceDetailView.swift"),
            encoding: .utf8)
        #expect(sourceDetailSource.contains("ForEach(ExtractionBackend.userSelectableCases"))
        #expect(sourceDetailSource.contains("ForEach(ExtractionBackend.allCases") == false)

        // Part 1 regression guard: no production target wires
        // `PdfExtractionService` anymore. The type itself remains for tests.
        for path in [
            "Sources/WikiFS/Window/WikiFSApp.swift",
            "Sources/WikiFS/Renderer/RendererCompositionOwner.swift",
            "Sources/WikiFSEngine/SessionsPlugin.swift",
        ] {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(path),
                encoding: .utf8)
            #expect(
                source.contains("PdfExtractionService") == false,
                "\(path) must not reference PdfExtractionService")
            #expect(
                source.contains("pdf2mdScriptPathResolver: {") == false,
                "\(path) must not inject a pdf2md resolver literal")
        }
    }

    @Test("package mutation stays app-only: only the app process wiring constructs the catalog writer")
    func mutationIsAppWiringOnly() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSourcesRoot = repositoryRoot.appendingPathComponent("Sources/WikiFS")
        var referencingFiles: [String] = []
        for source in try Self.swiftFiles(under: appSourcesRoot) {
            let contents = try String(contentsOf: source, encoding: .utf8)
            if contents.contains("ExtractorPackageCatalogWriter") {
                referencingFiles.append(source.lastPathComponent)
            }
        }
        // The reviewed-package bootstrap publishes the bundled reviewed
        // revisions (app-process-only by the same writer role gate); the
        // Settings wiring owns user-initiated import/removal. Nothing else in
        // the app target mutates the store, and neither surface is reachable
        // from the daemon or wiki state.
        #expect(referencingFiles.sorted() == ["ReviewedExtractorBootstrap.swift", "WikiFSApp.swift"])
    }

    // MARK: - Helpers

    private func reference(
        packageID: String,
        version: String,
        digestHex: String
    ) throws -> ExtractorReference {
        ExtractorReference(
            revision: ExtractorPackageRevisionID(
                packageID: try ExtractorPackageID(validating: packageID),
                version: try ExtractorPackageVersion(validating: version),
                digest: try ExtractorPackageDigest(hex: digestHex)),
            registrationID: try ExtractorRegistrationID(validating: "pdf"))
    }

    private func settingsRow() throws -> ExtractorPackageSettingsRow {
        let reference = try reference(
            packageID: "org.example.pdfpkg",
            version: "1.0.0",
            digestHex: String(repeating: "b", count: 64))
        return ExtractorPackageSettingsRow(
            kind: .pdf,
            packageID: "org.example.pdfpkg",
            version: "1.0.0",
            digestPrefix: String(repeating: "b", count: 12),
            registrationID: "pdf",
            revision: reference.revision)
    }

    private static func swiftFiles(under root: URL) throws -> [URL] {
        var result: [URL] = []
        var pending = [root]
        while let directory = pending.popLast() {
            let entries = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey])
            for entry in entries {
                let isDirectory = try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                if isDirectory {
                    pending.append(entry)
                } else if entry.pathExtension == "swift" {
                    result.append(entry)
                }
            }
        }
        return result
    }

    private func stubPDFBackend() -> RegisteredExtractionBackend {
        RegisteredExtractionBackend(key: ExtractionBackendKey(kind: .pdf, backendID: "stub")) {
            .pdf(ExtractionPreparation(
                extractor: SettingsStubMarkdownExtractor(),
                backend: .localPdf2md,
                modelVersion: nil))
        }
    }

    private func stubHTMLBackend() -> RegisteredExtractionBackend {
        RegisteredExtractionBackend(key: ExtractionBackendKey(kind: .html, backendID: "stub")) {
            .html(SettingsStubHTMLExtractor())
        }
    }
}

/// Sendable mutation counter for observing refresh behavior across the
/// `@Sendable` closure seams.
private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// Sendable box capturing the revision a removal action received.
private actor RevisionBox {
    private var stored: ExtractorPackageRevisionID?
    func set(_ revision: ExtractorPackageRevisionID) { stored = revision }
    var value: ExtractorPackageRevisionID? { stored }
}

private struct SettingsStubMarkdownExtractor: MarkdownExtractor {
    var displayName: String { "settings-stub" }
    func readiness() async -> ExtractionReadiness { .ready }
    func convert(
        pdfData: Data,
        filename: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> String { "" }
}

private struct SettingsStubHTMLExtractor: HtmlMarkdownExtractor {
    func extract(html: String) async -> HtmlExtractionResult? { nil }
}
#endif
