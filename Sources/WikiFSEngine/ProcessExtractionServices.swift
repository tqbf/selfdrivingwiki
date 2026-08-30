import Foundation
import WikiFSCore

#if os(macOS)
/// Adapts the process extraction graph to the composition owner's lease shape,
/// so a consumer that owns an asynchronous startup facade resolves the same
/// single registry as every other consumer in its process.
public struct ProcessExtractionRuntimeHandle: ExtractionRuntimeOwning {
    public nonisolated let services: any ExtractionServices
    private let owned: ProcessExtractionServices

    public init(_ services: ProcessExtractionServices) {
        owned = services
        self.services = services
    }

    public func dispose() async throws {
        await owned.shutdown()
    }
}
#endif

/// The process extraction facade. It resolves every built-in and installed
/// adapter through the one process registry, while the package context keeps
/// generated package plugins alive for the process lifetime.
public struct ProcessExtractionServices: ExtractionServices, Sendable {
    public let context: ProcessExtractionContext

    private let registry: ExtractionBackendRegistry
    private let input: ExtractionProcessInput
    private let builtInBatch: ExtractionBackendBatchHandle

    private init(
        context: ProcessExtractionContext,
        input: ExtractionProcessInput,
        registry: ExtractionBackendRegistry,
        builtInBatch: ExtractionBackendBatchHandle
    ) {
        self.context = context
        self.input = input
        self.registry = registry
        self.builtInBatch = builtInBatch
    }

    /// Registers the host-owned built-in adapters before the facade becomes
    /// visible to child profiles. Package registrations use the same registry.
    public static func assemble(
        context: ProcessExtractionContext,
        input: ExtractionProcessInput
    ) async throws -> ProcessExtractionServices {
        let entries = builtInEntries(input: input)
        let batch = try await context.registry.registerBatch(entries)
        return ProcessExtractionServices(
            context: context,
            input: input,
            registry: context.registry,
            builtInBatch: batch)
    }

    /// The logical reference of the reviewed pdf2md package registration. The
    /// legacy `localPdf2md` selection maps to this lineage when it is active.
    public static let reviewedPDFLogical = reviewedLogical(
        package: ReviewedExtractorPackages.pdf2md, registration: "document")

    /// The logical reference of the reviewed Defuddle package registration. The
    /// legacy `defuddle` selection maps to this lineage when it is active.
    public static let reviewedHTMLLogical = reviewedLogical(
        package: ReviewedExtractorPackages.defuddle, registration: "article")

    /// The logical reference of the reviewed Docling Serve package
    /// registration. The legacy `.doclingServe` selection maps to this
    /// lineage when it is active (#1159).
    public static let reviewedDoclingLogical = reviewedLogical(
        package: ReviewedExtractorPackages.doclingServe, registration: "document")

    /// The logical reference of the reviewed docx2md package registration.
    /// DOCX has no built-in backend, so this lineage is also the DEFAULT
    /// selection when no `docxExtractor` reference is configured.
    public static let reviewedDOCXLogical = reviewedLogical(
        package: ReviewedExtractorPackages.docx2md, registration: "document")

    private static func reviewedLogical(
        package: ReviewedExtractorPackage,
        registration: String
    ) -> LogicalExtractorReference {
        guard let registrationID = ExtractorRegistrationID(rawValue: registration) else {
            preconditionFailure("Invalid reviewed registration ID: \(registration)")
        }
        return LogicalExtractorReference(
            packageID: package.packageID,
            registrationID: registrationID)
    }

    public func prepare(backendOverride: ExtractionBackend?) async throws -> ExtractionPreparation {
        let configuration = try input.readConfiguration()
        var key = try await pdfKey(configuration: configuration, override: backendOverride)
        if case .builtIn(let builtIn) = key,
           builtIn == ExtractionBackendKey(kind: .pdf, backendID: ExtractionBackend.localPdf2md.rawValue) {
            key = try await reviewedKey(
                logical: Self.reviewedPDFLogical,
                kind: .pdf)
        }
        // Legacy `.doclingServe` selections run through the reviewed Docling
        // Serve package. There is deliberately NO silent fallback to another
        // third-party package: an unauthorized or unconfigured selection
        // surfaces its needs-authorization state instead (plan step 12).
        if case .builtIn(let builtIn) = key,
           builtIn == ExtractionBackendKey(kind: .pdf, backendID: ExtractionBackend.doclingServe.rawValue) {
            key = try await reviewedKey(
                logical: Self.reviewedDoclingLogical,
                kind: .pdf)
        }
        let adapter = try await makeAdapter(for: key)
        guard case .pdf(let preparation) = adapter else {
            throw ExtractionServicesError.unavailable
        }
        return preparation
    }

    /// Resolves one configured or explicitly overridden HTML adapter. An
    /// unavailable installed selection blocks the route without substitution.
    public func prepareHTML(
        backendOverride: HtmlExtractionBackend?
    ) async throws -> any HtmlMarkdownExtractor {
        let configuration = try input.readConfiguration()
        var key = try await htmlKey(
            configuration: configuration,
            override: backendOverride)

        // The legacy Defuddle choice maps to its reviewed package lineage.
        if case .builtIn(let builtIn) = key,
           builtIn == ExtractionBackendKey(
               kind: .html,
               backendID: HtmlExtractionBackend.defuddle.rawValue)
        {
            key = try await reviewedKey(
                logical: Self.reviewedHTMLLogical,
                kind: .html)
        }

        let adapter = try await makeAdapter(for: key)
        guard case .html(let extractor) = adapter else {
            throw ExtractionServicesError.unavailable
        }
        return extractor
    }

    /// Resolves one configured DOCX adapter. DOCX is package-only: there are
    /// no built-in DOCX backends and no legacy selection to remap, so a nil
    /// configured reference resolves directly to the reviewed docx2md
    /// lineage. An inactive package (removed, not yet activated, or bun
    /// missing) fails closed — no substitution, one redacted diagnostic via
    /// `selectedExtractorUnavailable`.
    public func prepareDOCX() async throws -> any DocxMarkdownExtractor {
        let configuration = try input.readConfiguration()
        let key = try await docxKey(configuration: configuration)
        let adapter = try await makeAdapter(for: key)
        guard case .docx(let extractor) = adapter else {
            throw ExtractionServicesError.unavailable
        }
        return extractor
    }

    public func registeredExtractionInputs() async -> RegisteredExtractionInputs {
        await registry.registeredExtractionInputs()
    }

    /// Stops host-owned built-in registrations, then disposes the package
    /// context. Prepared operations retain their own snapshots.
    public func shutdown() async {
        await builtInBatch.dispose()
        await context.shutdown()
    }

    private func pdfKey(
        configuration: ExtractionConfig,
        override: ExtractionBackend?
    ) async throws -> ExtractionAdapterKey {
        if let override {
            return .builtIn(ExtractionBackendKey(kind: .pdf, backendID: override.rawValue))
        }
        guard let logical = configuration.pdfExtractor else {
            return .builtIn(ExtractionBackendKey(
                kind: .pdf,
                backendID: configuration.backend.rawValue))
        }
        switch logical {
        case .builtIn(.pdf(let backend)):
            return .builtIn(ExtractionBackendKey(kind: .pdf, backendID: backend.rawValue))
        case .builtIn(.html):
            return .builtIn(ExtractionBackendKey(
                kind: .pdf,
                backendID: configuration.backend.rawValue))
        case .installed(let reference):
            guard let match = await registry.resolveInstalled(reference, kind: .pdf) else {
                throw ExtractionServicesError.selectedExtractorUnavailable(
                    route: .canonicalPDF,
                    reference: reference)
            }
            return match.key
        }
    }

    private func htmlKey(
        configuration: ExtractionConfig,
        override: HtmlExtractionBackend?
    ) async throws -> ExtractionAdapterKey {
        if let override {
            return .builtIn(ExtractionBackendKey(kind: .html, backendID: override.rawValue))
        }
        guard let logical = configuration.htmlExtractor else {
            return .builtIn(ExtractionBackendKey(
                kind: .html,
                backendID: (configuration.htmlBackend ?? .tagBased).rawValue))
        }
        switch logical {
        case .builtIn(.html(let backend)):
            return .builtIn(ExtractionBackendKey(kind: .html, backendID: backend.rawValue))
        case .builtIn(.pdf):
            return .builtIn(ExtractionBackendKey(
                kind: .html,
                backendID: (configuration.htmlBackend ?? .tagBased).rawValue))
        case .installed(let reference):
            guard let match = await registry.resolveInstalled(reference, kind: .html) else {
                throw ExtractionServicesError.selectedExtractorUnavailable(
                    route: .canonicalHTML,
                    reference: reference)
            }
            return match.key
        }
    }

    /// Resolves a reviewed package lineage by identity. A missing reviewed
    /// registration is a configuration error, not permission to restore a
    /// retired in-process extractor.
    private func reviewedKey(
        logical: LogicalExtractorReference,
        kind: ExtractionBackendKind
    ) async throws -> ExtractionAdapterKey {
        guard let match = await registry.resolveInstalled(logical, kind: kind) else {
            throw ExtractionServicesError.unavailable
        }
        return match.key
    }

    /// DOCX key resolution. DOCX is package-only, so an installed logical
    /// reference must have an active registration in the DOCX namespace; no
    /// selection (or a cross-kind builtIn stray) resolves to the reviewed
    /// docx2md lineage, mirroring `pdfKey` / `htmlKey` fail-closed behavior.
    private func docxKey(
        configuration: ExtractionConfig
    ) async throws -> ExtractionAdapterKey {
        let logical: LogicalExtractorReference
        switch configuration.docxExtractor {
        case .installed(let reference):
            logical = reference
        case .builtIn, nil:
            // There is no built-in DOCX backend; the default selection is
            // the reviewed docx2md lineage.
            logical = Self.reviewedDOCXLogical
        }
        guard let match = await registry.resolveInstalled(logical, kind: .docx) else {
            throw ExtractionServicesError.selectedExtractorUnavailable(
                route: .canonicalDOCX,
                reference: logical)
        }
        return match.key
    }

    private func makeAdapter(
        for key: ExtractionAdapterKey
    ) async throws -> ExtractionBackendAdapter {
        guard let registered = await registry.resolve(key) else {
            throw ExtractionServicesError.unavailable
        }
        return try await registered.make()
    }

    private static func builtInEntries(
        input: ExtractionProcessInput
    ) -> [ExtractionBatchEntry] {
        let acpKey = ExtractionBackendKey(kind: .pdf, backendID: ExtractionBackend.acp.rawValue)
        let anthropicKey = ExtractionBackendKey(kind: .pdf, backendID: ExtractionBackend.anthropic.rawValue)
        let geminiKey = ExtractionBackendKey(kind: .pdf, backendID: ExtractionBackend.gemini.rawValue)
        let tagBasedKey = ExtractionBackendKey(kind: .html, backendID: HtmlExtractionBackend.tagBased.rawValue)

        // The in-process Docling Serve adapter was REMOVED (#1159, plan step
        // 15): Docling runs through the reviewed revision 2 package, whose
        // lineage receives the stored token only after explicit
        // authorization. Legacy `.doclingServe` selections map to that
        // lineage in `prepare`; `DoclingServeClient` remains only as the
        // shared request implementation behind the Settings connection test.

        return [
            ExtractionBatchEntry(
                key: .builtIn(acpKey),
                backend: RegisteredExtractionBackend(key: acpKey) {
                    let configuration = try input.readConfiguration()
                    guard let extractor = input.resolveACP(configuration) else {
                        DebugLog.config(
                            "ExtractionServices: .acp backend has no configured provider")
                        throw ExtractionServicesError.unavailable
                    }
                    return .pdf(ExtractionPreparation(
                        extractor: extractor,
                        backend: .acp,
                        modelVersion: nil))
                }),
            ExtractionBatchEntry(
                key: .builtIn(anthropicKey),
                backend: RegisteredExtractionBackend(key: anthropicKey) {
                    let configuration = try input.readConfiguration()
                    let baseURL = configuration.anthropicBaseURLOverride
                        .flatMap(URL.init(string:))
                        ?? ExtractionDefaultURL.anthropic
                    return .pdf(ExtractionPreparation(
                        extractor: AnthropicExtractionClient(
                            model: configuration.anthropicModel,
                            apiKey: input.readCredential(.anthropicAPIKey) ?? "",
                            baseURL: baseURL,
                            fetcher: input.httpFetcher),
                        backend: .anthropic,
                        modelVersion: configuration.anthropicModel))
                }),
            ExtractionBatchEntry(
                key: .builtIn(geminiKey),
                backend: RegisteredExtractionBackend(key: geminiKey) {
                    let configuration = try input.readConfiguration()
                    let baseURL = configuration.geminiBaseURLOverride
                        .flatMap(URL.init(string:))
                        ?? ExtractionDefaultURL.gemini
                    return .pdf(ExtractionPreparation(
                        extractor: GeminiExtractionClient(
                            model: configuration.geminiModel,
                            apiKey: input.readCredential(.geminiAPIKey) ?? "",
                            baseURL: baseURL,
                            fetcher: input.httpFetcher),
                        backend: .gemini,
                        modelVersion: configuration.geminiModel))
                }),
            ExtractionBatchEntry(
                key: .builtIn(tagBasedKey),
                backend: RegisteredExtractionBackend(key: tagBasedKey) {
                    .html(TagBasedHtmlExtractor())
                }),
        ]
    }
}
