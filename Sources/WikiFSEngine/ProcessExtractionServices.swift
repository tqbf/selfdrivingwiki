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
        let adapter = try await makeAdapter(for: key)
        guard case .pdf(let preparation) = adapter else {
            throw ExtractionServicesError.unavailable
        }
        return preparation
    }

    /// Resolves an HTML adapter through the same exact registry used by PDF
    /// extraction. The default remains the always-available tag-based adapter.
    public func prepareHTML(
        backendOverride: HtmlExtractionBackend?
    ) async throws -> any HtmlMarkdownExtractor {
        let configuration = try input.readConfiguration()
        var key: ExtractionAdapterKey
        if let backendOverride {
            key = .builtIn(ExtractionBackendKey(
                kind: .html,
                backendID: backendOverride.rawValue))
        } else if let logical = configuration.htmlExtractor {
            switch logical {
            case .builtIn(.html(let backend)):
                key = .builtIn(ExtractionBackendKey(kind: .html, backendID: backend.rawValue))
            case .builtIn(.pdf):
                key = .builtIn(ExtractionBackendKey(kind: .html, backendID: HtmlExtractionBackend.tagBased.rawValue))
            case .installed(let reference):
                if let match = await registry.resolveInstalled(reference, kind: .html) {
                    key = match.key
                } else {
                    DebugLog.extraction(
                        "Configured installed HTML extractor is unavailable; using tag-based fallback")
                    key = .builtIn(ExtractionBackendKey(
                        kind: .html,
                        backendID: HtmlExtractionBackend.tagBased.rawValue))
                }
            }
        } else if let legacy = configuration.htmlBackend {
            key = .builtIn(ExtractionBackendKey(kind: .html, backendID: legacy.rawValue))
        } else {
            key = .builtIn(ExtractionBackendKey(
                kind: .html,
                backendID: HtmlExtractionBackend.tagBased.rawValue))
        }

        // Map the legacy Defuddle selection to the reviewed package lineage.
        // The tag-based fallback is never mapped.
        if case .builtIn(let builtIn) = key,
           builtIn == ExtractionBackendKey(kind: .html, backendID: HtmlExtractionBackend.defuddle.rawValue) {
            do {
                key = try await reviewedKey(
                    logical: Self.reviewedHTMLLogical,
                    kind: .html)
            } catch {
                DebugLog.extraction(
                    "Reviewed Defuddle extractor is unavailable; using tag-based fallback")
                key = .builtIn(ExtractionBackendKey(
                    kind: .html,
                    backendID: HtmlExtractionBackend.tagBased.rawValue))
            }
        }

        do {
            let adapter = try await makeAdapter(for: key)
            guard case .html(let extractor) = adapter else {
                throw ExtractionServicesError.unavailable
            }
            return extractor
        } catch {
            DebugLog.extraction(
                "HTML extractor is unavailable; using tag-based fallback")
            let fallback = try await makeAdapter(for: .builtIn(ExtractionBackendKey(
                kind: .html,
                backendID: HtmlExtractionBackend.tagBased.rawValue)))
            guard case .html(let extractor) = fallback else {
                throw ExtractionServicesError.unavailable
            }
            return extractor
        }
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
            if let match = await registry.resolveInstalled(reference, kind: .pdf) {
                return match.key
            }
            DebugLog.extraction(
                "Configured installed PDF extractor is unavailable; using the reviewed pdf2md fallback")
            return try await reviewedKey(
                logical: Self.reviewedPDFLogical,
                kind: .pdf)
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
        let doclingKey = ExtractionBackendKey(kind: .pdf, backendID: ExtractionBackend.doclingServe.rawValue)
        let tagBasedKey = ExtractionBackendKey(kind: .html, backendID: HtmlExtractionBackend.tagBased.rawValue)

        return [
            ExtractionBatchEntry(
                key: .builtIn(acpKey),
                backend: RegisteredExtractionBackend(key: acpKey) {
                    let configuration = try input.readConfiguration()
                    guard let extractor = input.resolveACP(configuration) else {
                        DebugLog.config(
                            "ExtractionServices: .acp backend has no provider; using the reviewed pdf2md package fallback")
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
                key: .builtIn(doclingKey),
                backend: RegisteredExtractionBackend(key: doclingKey) {
                    let configuration = try input.readConfiguration()
                    return .pdf(ExtractionPreparation(
                        extractor: DoclingServeClient(
                            endpoint: configuration.doclingServeEndpoint ?? "",
                            apiToken: input.readCredential(.doclingServeToken),
                            fetcher: input.httpFetcher),
                        backend: .doclingServe,
                        modelVersion: nil))
                }),
            ExtractionBatchEntry(
                key: .builtIn(tagBasedKey),
                backend: RegisteredExtractionBackend(key: tagBasedKey) {
                    .html(TagBasedHtmlExtractor())
                }),
        ]
    }
}
