import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import WikiFSCore

/// Admission authority for one installed package revision. The Phase 5
/// generated plugin supplies this; tests supply a closure-backed checker. A
/// prepared operation captures the answer at preparation time and never
/// consults it again, so plugin stop cannot cancel an already prepared run.
public protocol ProcessPackageAdmissionChecking: Sendable {
    func isAdmitted(_ revision: ExtractorPackageRevisionID) async -> Bool
}

struct ClosureProcessPackageAdmission: ProcessPackageAdmissionChecking {
    let check: @Sendable (ExtractorPackageRevisionID) async -> Bool

    func isAdmitted(_ revision: ExtractorPackageRevisionID) async -> Bool {
        await check(revision)
    }
}

enum ProcessPackagePreparationError: LocalizedError, Equatable {
    case identityMismatch
    case notAdmitted
    case unknownRevision
    case noRegistrationForKind(ExtractorKind)

    var errorDescription: String? {
        switch self {
        case .identityMismatch:
            return "The package manifest does not match the requested revision."
        case .notAdmitted:
            return "The installed extractor package is no longer active."
        case .unknownRevision:
            return "The installed extractor package is not in the machine catalog."
        case .noRegistrationForKind(let kind):
            return "The package does not register a \(kind.rawValue.uppercased()) extractor."
        }
    }
}

enum ProcessPackageRunError: LocalizedError, Equatable {
    case declaredSizeMismatch
    case invalidOutputEncoding
    case missingTerminalFrame

    var errorDescription: String? {
        switch self {
        case .declaredSizeMismatch:
            return "The extractor reported a different result size than written."
        case .invalidOutputEncoding:
            return "The extractor result was not valid UTF-8."
        case .missingTerminalFrame:
            return "The extractor returned no terminal result."
        }
    }
}

/// Failure text for existing converter callers, which surface messages
/// directly. Terminal failure frames stay authoritative over process causes.
enum ProcessPackageFailureMapper {
    static func message(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return "The extractor process failed: \(String(describing: error))"
    }

    static func terminalMessage(_ frame: ExtractorFailureFrame) -> String {
        "Extractor failed (\(frame.cause.rawValue)): \(frame.message)"
    }
}

struct ProcessPackageError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

internal struct ProcessPackageExecutionOutcome: Sendable {
    let frame: ExtractorResultFrame
    let markdown: String
}

/// Builds process-backed extraction adapters for one exact validated package
/// revision. Every preparation rechecks admission and authoritative catalog
/// membership before pinning a private validated snapshot; the resulting
/// operation owns its snapshot independently of plugin lifecycle.
public struct ProcessExtractorProvider: Sendable {
    let layout: ExtractorPackageStoreLayout
    let catalogReader: any ExtractorPackageCatalogReading
    let executor: any ManagedProcessExecuting
    let admission: any ProcessPackageAdmissionChecking
    let sourceLocator: any ExtractorPackageSourceLocating

    public init(
        layout: ExtractorPackageStoreLayout,
        catalogReader: any ExtractorPackageCatalogReading,
        executor: any ManagedProcessExecuting,
        admission: any ProcessPackageAdmissionChecking,
        sourceLocator: (any ExtractorPackageSourceLocating)? = nil
    ) {
        self.layout = layout
        self.catalogReader = catalogReader
        self.executor = executor
        self.admission = admission
        self.sourceLocator = sourceLocator
            ?? InstalledExtractorPackageSourceLocator(layout: layout)
    }

    /// Convenience initializer for closure-backed admission checks.
    public init(
        layout: ExtractorPackageStoreLayout,
        catalogReader: any ExtractorPackageCatalogReading,
        executor: any ManagedProcessExecuting,
        admitted: @escaping @Sendable (ExtractorPackageRevisionID) async -> Bool
    ) {
        self.init(
            layout: layout,
            catalogReader: catalogReader,
            executor: executor,
            admission: ClosureProcessPackageAdmission(check: admitted))
    }

    public func preparePDF(
        revision: ExtractorPackageRevisionID,
        manifest: ExtractorManifest
    ) async throws -> ExtractionPreparation {
        let operation = try await prepareOperation(
            kind: .pdf, revision: revision, manifest: manifest)
        return ExtractionPreparation(
            extractor: ProcessPackagePDFExtractor(operation: operation),
            // Interim compatibility tag until Phase 5 installs typed package
            // provenance; the activity plan producer carries exact identity.
            backend: .localPdf2md,
            modelVersion: nil,
            technique: "package:\(revision.packageID.rawValue)")
    }

    public func prepareHTML(
        revision: ExtractorPackageRevisionID,
        manifest: ExtractorManifest
    ) async throws -> any HtmlMarkdownExtractor {
        let operation = try await prepareOperation(
            kind: .html, revision: revision, manifest: manifest)
        return ProcessPackageHTMLExtractor(operation: operation)
    }

    func prepareOperation(
        kind: ExtractorKind,
        revision: ExtractorPackageRevisionID,
        manifest: ExtractorManifest
    ) async throws -> PreparedProcessOperation {
        guard revision.packageID == manifest.packageID,
              revision.version == manifest.version else {
            throw ProcessPackagePreparationError.identityMismatch
        }
        do {
            guard try manifest.packageDigest() == revision.digest else {
                throw ProcessPackagePreparationError.identityMismatch
            }
        } catch let error as ProcessPackagePreparationError {
            throw error
        } catch {
            throw ProcessPackagePreparationError.identityMismatch
        }
        guard await admission.isAdmitted(revision) else {
            throw ProcessPackagePreparationError.notAdmitted
        }
        let catalog = try catalogReader.read()
        guard catalog.records.contains(where: { $0.revision == revision }) else {
            throw ProcessPackagePreparationError.unknownRevision
        }
        // Recheck after every await so removal cannot slip between checks.
        guard await admission.isAdmitted(revision) else {
            throw ProcessPackagePreparationError.notAdmitted
        }

        let registration = try Self.registration(manifest: manifest, kind: kind)
        let source = sourceLocator.location(for: revision)
        let snapshot = try ExtractorDirectoryValidator.snapshot(
            installedRoot: source.root,
            expectedRevision: revision,
            layout: layout,
            sourceContainingRoot: source.containingRoot)

        let operationRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("extractor-operation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: operationRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        for subdirectory in ["input", "output", "home", "tmp", "cache"] {
            try FileManager.default.createDirectory(
                at: operationRoot.appendingPathComponent(subdirectory, isDirectory: true),
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        let materializedRevision = try ExtractorDirectoryValidator.materializeOperationPackage(
            from: snapshot,
            into: operationRoot.appendingPathComponent("package", isDirectory: true))
        guard materializedRevision == revision else {
            throw ProcessPackagePreparationError.unknownRevision
        }

        return PreparedProcessOperation(
            directoryRoot: operationRoot.standardizedFileURL,
            packageRoot: operationRoot
                .appendingPathComponent("package", isDirectory: true)
                .standardizedFileURL,
            homeRoot: operationRoot.appendingPathComponent("home", isDirectory: true),
            temporaryRoot: operationRoot.appendingPathComponent("tmp", isDirectory: true),
            cacheRoot: operationRoot.appendingPathComponent("cache", isDirectory: true),
            revision: revision,
            manifest: manifest,
            registrationID: registration.id,
            mimeTypes: registration.mimeTypes.sorted().map(\.rawValue),
            executor: executor,
            runtimeSearchPolicy: .standard)
    }

    static func registration(
        manifest: ExtractorManifest,
        kind: ExtractorKind
    ) throws -> ExtractorRegistration {
        guard let registration = manifest.registrations
            .sorted()
            .first(where: { $0.kinds.contains(kind) }) else {
            throw ProcessPackagePreparationError.noRegistrationForKind(kind)
        }
        return registration
    }
}

/// One pinned operation directory. Concurrent conversions get disjoint
/// request-scoped subdirectories and share the immutable package snapshot.
/// The whole tree is removed when the operation object dies.
public final class PreparedProcessOperation: Sendable {
    public let revision: ExtractorPackageRevisionID
    public let manifest: ExtractorManifest
    public let registrationID: ExtractorRegistrationID

    let directoryRoot: URL
    let packageRoot: URL
    let homeRoot: URL
    let temporaryRoot: URL
    let cacheRoot: URL
    let mimeTypes: [String]
    let executor: any ManagedProcessExecuting
    let runtimeSearchPolicy: ExtractorRuntimeSearchPolicy

    init(
        directoryRoot: URL,
        packageRoot: URL,
        homeRoot: URL,
        temporaryRoot: URL,
        cacheRoot: URL,
        revision: ExtractorPackageRevisionID,
        manifest: ExtractorManifest,
        registrationID: ExtractorRegistrationID,
        mimeTypes: [String],
        executor: any ManagedProcessExecuting,
        runtimeSearchPolicy: ExtractorRuntimeSearchPolicy
    ) {
        self.directoryRoot = directoryRoot
        self.packageRoot = packageRoot
        self.homeRoot = homeRoot
        self.temporaryRoot = temporaryRoot
        self.cacheRoot = cacheRoot
        self.revision = revision
        self.manifest = manifest
        self.registrationID = registrationID
        self.mimeTypes = mimeTypes
        self.executor = executor
        self.runtimeSearchPolicy = runtimeSearchPolicy
    }

    deinit {
        do {
            if FileManager.default.fileExists(atPath: directoryRoot.path) {
                try FileManager.default.removeItem(at: directoryRoot)
            }
        } catch {
            DebugLog.extraction(
                "Extractor operation cleanup failed for \(revision.digest.hex.prefix(12)): \(error)")
        }
    }

    var entryPointURL: URL {
        packageRoot.appendingPathComponent(manifest.entryPoint.rawValue)
    }

    private func mimeType(defaulting fallback: String) -> String {
        mimeTypes.first ?? fallback
    }

    /// Runs exactly one one-shot conversion against the pinned snapshot and
    /// returns the terminal result frame plus its verified Markdown text.
    func execute(
        kind: ExtractorKind,
        input: Data,
        filename: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> ProcessPackageExecutionOutcome {
        let requestID = UUID()
        let name = requestID.uuidString.lowercased()
        let inputPath = "input/\(name)/source"
        let outputPath = "output/\(name)/result.md"

        let inputURL = directoryRoot.appendingPathComponent(inputPath)
        try FileManager.default.createDirectory(
            at: inputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try input.write(to: inputURL, options: [.atomic])

        let fallbackMIMEType = kind == .pdf ? "application/pdf" : "text/html"
        let request = try ExtractorProtocolRequest(
            requestID: ExtractorRequestID(),
            protocolRevision: manifest.protocolRevision,
            kind: kind,
            mimeType: ExtractorMIMEType(validating: mimeType(defaulting: fallbackMIMEType)),
            originalFilename: filename,
            inputPath: ExtractorRelativePath(validating: inputPath),
            outputPath: ExtractorRelativePath(validating: outputPath),
            deadlineMillisecondsSince1970: Int64(Date().timeIntervalSince1970 * 1_000)
                + max(Int64(manifest.limits.maximumDurationMilliseconds), 1))

        let managedRequest = ManagedExtractorProcessRequest(
            revision: revision,
            manifest: manifest,
            protocolRequest: request,
            paths: ManagedExtractorProcessPaths(
                operationRoot: directoryRoot,
                packageRoot: packageRoot,
                homeRoot: homeRoot,
                temporaryRoot: temporaryRoot,
                privateCacheRoot: cacheRoot))
        let outcome = try await executor.execute(managedRequest) { frame in
            if case .progress(let progress) = frame, let message = progress.message {
                onProgress?(message + "\n")
            }
        }

        switch outcome.terminalFrame {
        case .result(let frame):
            let outputURL = directoryRoot.appendingPathComponent(outputPath)
            let data = try Data(contentsOf: outputURL, options: [.mappedIfSafe])
            guard data.count == frame.markdownByteCount else {
                throw ProcessPackageRunError.declaredSizeMismatch
            }
            guard let markdown = String(data: data, encoding: .utf8) else {
                throw ProcessPackageRunError.invalidOutputEncoding
            }
            return ProcessPackageExecutionOutcome(frame: frame, markdown: markdown)
        case .failure(let frame):
            throw ProcessPackageError(
                message: ProcessPackageFailureMapper.terminalMessage(frame))
        case .progress, .diagnostic:
            throw ProcessPackageRunError.missingTerminalFrame
        }
    }
}

public struct ProcessPackagePDFExtractor: MarkdownExtractor {
    public var displayName: String { operation.manifest.displayName }

    let operation: PreparedProcessOperation

    init(operation: PreparedProcessOperation) {
        self.operation = operation
    }

    public func readiness() async -> ExtractionReadiness {
        guard Self.entryIsExecutable(operation.entryPointURL) else {
            return .notInstalled("The installed extractor entry point is missing.")
        }
        switch operation.manifest.launch {
        case .direct:
            return .ready
        case .runtime(let command, _):
            if Self.resolveRuntime(command, policy: operation.runtimeSearchPolicy) != nil {
                return .ready
            }
            return .needsSetup(
                "Runtime \(command.rawValue) is not installed. Install it to use this extractor.")
        }
    }

    public func convert(
        pdfData: Data,
        filename: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> String {
        do {
            let outcome = try await operation.execute(
                kind: .pdf,
                input: pdfData,
                filename: filename,
                onProgress: onProgress)
            return outcome.markdown
        } catch {
            throw ProcessPackageError(message: ProcessPackageFailureMapper.message(error))
        }
    }

    static func entryIsExecutable(_ url: URL) -> Bool {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_mode & S_IXUSR != 0 else { return false }
        return true
    }

    static func resolveRuntime(
        _ command: ExtractorRuntimeName,
        policy: ExtractorRuntimeSearchPolicy
    ) -> URL? {
        for directory in policy.searchDirectories {
            let candidate = directory.appendingPathComponent(command.rawValue)
            if entryIsExecutable(candidate) { return candidate }
        }
        return nil
    }
}

public struct ProcessPackageHTMLExtractor: HtmlMarkdownExtractor {
    public var displayName: String { operation.manifest.displayName }

    let operation: PreparedProcessOperation

    init(operation: PreparedProcessOperation) {
        self.operation = operation
    }

    public func extract(html: String) async -> HtmlExtractionResult? {
        do {
            let outcome = try await operation.execute(
                kind: .html,
                input: Data(html.utf8),
                filename: "source.html",
                onProgress: nil)
            return HtmlExtractionResult(
                markdown: outcome.markdown,
                title: outcome.frame.articleMetadata?.title,
                author: outcome.frame.articleMetadata?.author,
                description: outcome.frame.articleMetadata?.description,
                published: outcome.frame.articleMetadata?.published,
                wordCount: outcome.frame.articleMetadata?.wordCount)
        } catch {
            DebugLog.extraction(
                "Package HTML extraction fell back: \(ProcessPackageFailureMapper.message(error))")
            return nil
        }
    }
}
