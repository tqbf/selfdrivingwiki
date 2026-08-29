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

    var reportedMetadata: ExtractorReportedMetadata { frame.metadata }
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
    let sharedRuntimeCacheRoot: URL?
    let sharedModelCacheRoot: URL?
    /// Host-owned per-operation credential resolution (#1159). Nil for hosts
    /// that never prepare credential-declaring packages (or in tests); a
    /// credential-declaring revision 2 package prepared WITHOUT a resolver
    /// fails closed (its required requirements block).
    let operationCredentials: (any ExtractorOperationCredentialResolving)?
    /// Host-owned non-secret operation configuration (e.g. the Docling
    /// endpoint + timeout). Called per execute; values ride the public
    /// operation-configuration file, never the credential file.
    let operationConfiguration:
        (@Sendable (ExtractorPackageRevisionID) -> ExtractorOperationConfiguration?)?

    /// The cache roots are host-owned. A package can use them only when its
    /// manifest declares the matching capability.
    public init(
        layout: ExtractorPackageStoreLayout,
        catalogReader: any ExtractorPackageCatalogReading,
        executor: any ManagedProcessExecuting,
        admission: any ProcessPackageAdmissionChecking,
        sourceLocator: (any ExtractorPackageSourceLocating)? = nil,
        sharedRuntimeCacheRoot: URL? = nil,
        sharedModelCacheRoot: URL? = nil,
        operationCredentials: (any ExtractorOperationCredentialResolving)? = nil,
        operationConfiguration: (@Sendable (ExtractorPackageRevisionID) -> ExtractorOperationConfiguration?)? = nil
    ) {
        self.layout = layout
        self.catalogReader = catalogReader
        self.executor = executor
        self.admission = admission
        self.sourceLocator = sourceLocator
            ?? InstalledExtractorPackageSourceLocator(layout: layout)
        self.sharedRuntimeCacheRoot = sharedRuntimeCacheRoot
        self.sharedModelCacheRoot = sharedModelCacheRoot
        self.operationCredentials = operationCredentials
        self.operationConfiguration = operationConfiguration
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
        // Backend tag (#1159, plan step 11): the reviewed Docling Serve
        // lineage pairs with `.doclingServe` — never the interim
        // `.localPdf2md` tag that predates typed package provenance.
        let backendTag: ExtractionBackend =
            revision.packageID == ReviewedExtractorPackages.doclingServe.packageID
            ? .doclingServe
            : .localPdf2md
        return ExtractionPreparation(
            extractor: ProcessPackagePDFExtractor(operation: operation),
            backend: backendTag,
            modelVersion: nil,
            technique: "package:\(revision.packageID.rawValue)",
            packageProvenance: Self.packageProvenance(
                revision: revision,
                manifest: manifest,
                registrationID: operation.registrationID))
    }

    public func prepareHTML(
        revision: ExtractorPackageRevisionID,
        manifest: ExtractorManifest
    ) async throws -> any HtmlMarkdownExtractor {
        let operation = try await prepareOperation(
            kind: .html, revision: revision, manifest: manifest)
        return ProcessPackageHTMLExtractor(operation: operation)
    }

    public static func packageProvenance(
        revision: ExtractorPackageRevisionID,
        manifest: ExtractorManifest,
        registrationID: ExtractorRegistrationID,
        reportedMetadata: ExtractorReportedMetadata = .empty
    ) -> ExtractionInstalledPackageProducer {
        ExtractionInstalledPackageProducer(
            revision: revision,
            registrationID: registrationID,
            protocolRevision: manifest.protocolRevision,
            reportedMetadata: reportedMetadata)
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

        let operationRoot = layout.operationURL(ExtractorOperationID())
        try FileManager.default.createDirectory(
            at: operationRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        for subdirectory in ["input", "output", "home", "tmp", "cache",
                             "credentials", "config"] {
            // `credentials` and `config` are pre-created owner-private so a
            // request-scoped subdirectory's parent never inherits umask
            // defaults (security review L-12).
            try FileManager.default.createDirectory(
                at: operationRoot.appendingPathComponent(subdirectory, isDirectory: true),
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        let runtimeCacheRoot = manifest.capabilities.contains(.sharedRuntimeCache)
            ? self.sharedRuntimeCacheRoot
            : nil
        let modelCacheRoot = manifest.capabilities.contains(.modelDownload)
            ? self.sharedModelCacheRoot
            : nil
        for sharedRoot in [runtimeCacheRoot, modelCacheRoot].compactMap({ $0 }) {
            try FileManager.default.createDirectory(
                at: sharedRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            guard try Self.isOwnerPrivateDirectory(sharedRoot) else {
                throw ExtractorDirectoryAdmissionError.preparationFailed
            }
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
            sharedRuntimeCacheRoot: runtimeCacheRoot,
            sharedModelCacheRoot: modelCacheRoot,
            revision: revision,
            manifest: manifest,
            registration: registration,
            registrationID: registration.id,
            protocolRevision: manifest.protocolRevision,
            mimeTypes: registration.mimeTypes.sorted().map(\.rawValue),
            executor: executor,
            operationCredentials: operationCredentials,
            operationConfiguration: operationConfiguration,
            runtimeSearchPolicy: .standard)
    }

    private static func isOwnerPrivateDirectory(_ url: URL) throws -> Bool {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw ExtractorDirectoryAdmissionError.preparationFailed
        }
        return status.st_mode & S_IFMT == S_IFDIR
            && status.st_uid == getuid()
            && status.st_mode & 0o7777 == 0o700
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
    /// The SELECTED registration for the prepared kind — its declared
    /// requirements drive per-execute credential resolution (#1159).
    public let registration: ExtractorRegistration
    public let registrationID: ExtractorRegistrationID
    public let protocolRevision: ExtractorProtocolRevision

    let directoryRoot: URL
    let packageRoot: URL
    let homeRoot: URL
    let temporaryRoot: URL
    let cacheRoot: URL
    let sharedRuntimeCacheRoot: URL?
    let sharedModelCacheRoot: URL?
    let mimeTypes: [String]
    let executor: any ManagedProcessExecuting
    let operationCredentials: (any ExtractorOperationCredentialResolving)?
    let operationConfiguration:
        (@Sendable (ExtractorPackageRevisionID) -> ExtractorOperationConfiguration?)?
    let runtimeSearchPolicy: ExtractorRuntimeSearchPolicy

    init(
        directoryRoot: URL,
        packageRoot: URL,
        homeRoot: URL,
        temporaryRoot: URL,
        cacheRoot: URL,
        sharedRuntimeCacheRoot: URL?,
        sharedModelCacheRoot: URL?,
        revision: ExtractorPackageRevisionID,
        manifest: ExtractorManifest,
        registration: ExtractorRegistration,
        registrationID: ExtractorRegistrationID,
        protocolRevision: ExtractorProtocolRevision,
        mimeTypes: [String],
        executor: any ManagedProcessExecuting,
        operationCredentials: (any ExtractorOperationCredentialResolving)?,
        operationConfiguration: (@Sendable (ExtractorPackageRevisionID) -> ExtractorOperationConfiguration?)?,
        runtimeSearchPolicy: ExtractorRuntimeSearchPolicy
    ) {
        self.directoryRoot = directoryRoot
        self.packageRoot = packageRoot
        self.homeRoot = homeRoot
        self.temporaryRoot = temporaryRoot
        self.cacheRoot = cacheRoot
        self.sharedRuntimeCacheRoot = sharedRuntimeCacheRoot
        self.sharedModelCacheRoot = sharedModelCacheRoot
        self.revision = revision
        self.manifest = manifest
        self.registration = registration
        self.registrationID = registrationID
        self.protocolRevision = protocolRevision
        self.mimeTypes = mimeTypes
        self.executor = executor
        self.operationCredentials = operationCredentials
        self.operationConfiguration = operationConfiguration
        self.runtimeSearchPolicy = runtimeSearchPolicy
    }

    deinit {
        do {
            if FileManager.default.fileExists(atPath: directoryRoot.path) {
                try FileManager.default.removeItem(at: directoryRoot)
            }
        } catch {
            DebugLog.extraction(
                "Extractor operation cleanup failed for digest \(revision.digest.hex.prefix(12))")
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
    ///
    /// # Operation credentials (#1159)
    /// For a revision 2 registration that DECLARES credential requirements
    /// with a host resolver wired, EVERY execute call re-resolves current
    /// state (admission, catalog membership, authorization, values) — so
    /// rotation, revocation, removal, and reinstall affect the next call
    /// without restart (AC.11). Resolved values are materialized into one
    /// request-scoped owner-read-only file inside the private operation root;
    /// the request carries only the RELATIVE path. The credential file and
    /// its request subdirectory are deleted on EVERY terminal path after
    /// materialization (AC.14), and every package-controlled string is
    /// redacted through the request's values before it can reach diagnostics
    /// or UI (AC.15).
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
        let runtimeCacheRoot = manifest.capabilities.contains(.sharedRuntimeCache)
            ? self.sharedRuntimeCacheRoot
            : nil
        let modelCacheRoot = manifest.capabilities.contains(.modelDownload)
            ? self.sharedModelCacheRoot
            : nil

        // ---- Operation input preparation (revision 2 + declared requirements)
        let declaresRequirements = manifest.protocolRevision == .v2
            && registration.credentialRequirements.isEmpty == false
        var resolvedValues: [ExtractorCredentialRequirementID: String] = [:]
        var configuration: ExtractorOperationConfiguration?
        var credentialFilePath: ExtractorRelativePath?
        var configurationFilePath: ExtractorRelativePath?
        var credentialSubdirectory: URL?
        var configurationSubdirectory: URL?
        if declaresRequirements {
            guard let resolver = operationCredentials else {
                // Fail closed: a required requirement cannot be satisfied
                // without the trusted host resolution service.
                throw ProcessPackageError(
                    message: ExtractorOperationCredentialError.resolutionUnavailable.description)
            }
            resolvedValues = try await resolver.resolveOperationCredentials(
                revision: revision, manifest: manifest, registration: registration)
            // AC.10 defense in depth: a REQUIRED requirement with no
            // resolved value blocks the launch with a bounded typed state,
            // regardless of resolver behavior.
            for requirement in registration.credentialRequirements
            where requirement.isOptional == false {
                if CredentialValue.normalized(resolvedValues[requirement.id]) == nil {
                    throw ProcessPackageError(
                        message: ExtractorOperationCredentialError
                            .requiredCredentialUnavailable(
                                requirementID: requirement.id.rawValue)
                            .description)
                }
            }
        }
        if manifest.protocolRevision == .v2 {
            configuration = operationConfiguration?(revision)
        }

        // The redactor covers every resolved value for THIS request; it is
        // constructed even when empty so call sites stay uniform.
        let redactor = ExtractorSecretRedactor(
            values: Array(resolvedValues.values))

        // Materialize the private credential file AFTER resolution. The
        // cleanup defer arms IMMEDIATELY after the file exists so every
        // terminal path — including a throw in the configuration block below
        // — deletes it (AC.14, security review MEDIUM-7). It fires when this
        // function exits, i.e. after the managed run has terminated and
        // reaped any child process group.
        if declaresRequirements {
            let envelope = try ExtractorCredentialInputEnvelope(
                requirements: registration.credentialRequirements,
                resolvedValues: resolvedValues)
            let subdirectory = directoryRoot
                .appendingPathComponent("credentials/\(name)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: subdirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            credentialSubdirectory = subdirectory
            let fileURL = subdirectory.appendingPathComponent("input.json")
            let data = try JSONEncoder().encode(envelope)
            try Self.writeOwnerReadOnlyFile(data, at: fileURL)
            credentialFilePath = try ExtractorRelativePath(
                validating: "credentials/\(name)/input.json")
        }
        // AC.14 structural guarantee: armed the moment the credential file
        // exists, so a throw anywhere later — including the configuration
        // block below — still deletes it. Fires on success, every error, and
        // cancellation.
        defer {
            for subdirectory in [credentialSubdirectory, configurationSubdirectory]
            .compactMap({ $0 }) {
                do {
                    try FileManager.default.removeItem(at: subdirectory)
                } catch {
                    // Value-free diagnostic; the operation-root deinitializer
                    // remains the final safety net.
                    DebugLog.extraction(
                        "Extractor request input cleanup failed (deferred to operation root cleanup).")
                }
            }
        }
        if let configuration {
            let subdirectory = directoryRoot
                .appendingPathComponent("config/\(name)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: subdirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            configurationSubdirectory = subdirectory
            let fileURL = subdirectory.appendingPathComponent("operation.json")
            try JSONEncoder().encode(configuration).write(to: fileURL, options: [.atomic])
            configurationFilePath = try ExtractorRelativePath(
                validating: "config/\(name)/operation.json")
        }

        // Immutable snapshots of the request paths for the @Sendable body.
        let requestCredentialPath = credentialFilePath
        let requestConfigurationPath = configurationFilePath
        return try await runManaged(
            redactor: redactor,
            onProgress: onProgress
        ) {
            let inputURL = self.directoryRoot.appendingPathComponent(inputPath)
            try FileManager.default.createDirectory(
                at: inputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try input.write(to: inputURL, options: [.atomic])

            let fallbackMIMEType = kind == .pdf ? "application/pdf" : "text/html"
            let request = try ExtractorProtocolRequest(
                requestID: ExtractorRequestID(),
                protocolRevision: self.manifest.protocolRevision,
                kind: kind,
                mimeType: ExtractorMIMEType(validating: self.mimeType(defaulting: fallbackMIMEType)),
                originalFilename: filename,
                inputPath: ExtractorRelativePath(validating: inputPath),
                outputPath: ExtractorRelativePath(validating: outputPath),
                deadlineMillisecondsSince1970: Int64(Date().timeIntervalSince1970 * 1_000)
                    + max(Int64(self.manifest.limits.maximumDurationMilliseconds), 1),
                credentialFilePath: requestCredentialPath,
                operationConfigurationPath: requestConfigurationPath)

            let managedRequest = ManagedExtractorProcessRequest(
                revision: self.revision,
                manifest: self.manifest,
                protocolRequest: request,
                paths: ManagedExtractorProcessPaths(
                    operationRoot: self.directoryRoot,
                    packageRoot: self.packageRoot,
                    homeRoot: self.homeRoot,
                    temporaryRoot: self.temporaryRoot,
                    privateCacheRoot: self.cacheRoot,
                    sharedRuntimeCacheRoot: runtimeCacheRoot,
                    sharedModelCacheRoot: modelCacheRoot))
            let outcome = try await self.executor.execute(managedRequest) { [redactor] (frame: ExtractorProtocolFrame) in
                if case .progress(let progress) = frame, let message = progress.message {
                    // Package-controlled progress text is redacted before it
                    // can reach host diagnostics or UI (AC.15).
                    onProgress?(redactor.redact(message) + "\n")
                }
            }

            switch outcome.terminalFrame {
            case .result(let frame):
                let outputURL = self.directoryRoot.appendingPathComponent(outputPath)
                let data = try Data(contentsOf: outputURL, options: [.mappedIfSafe])
                guard data.count == frame.markdownByteCount else {
                    throw ProcessPackageRunError.declaredSizeMismatch
                }
                guard let markdown = String(data: data, encoding: .utf8) else {
                    throw ProcessPackageRunError.invalidOutputEncoding
                }
                // Result-frame article metadata is package-controlled text
                // that becomes a persisted source filename and reaches the
                // wiki DB and File Provider — it passes through the redactor
                // like every other package-controlled string (MEDIUM-5).
                return ProcessPackageExecutionOutcome(
                    frame: try Self.redactedResultFrame(frame, redactor: redactor),
                    markdown: markdown)
            case .failure(let frame):
                // Terminal failure frames are package-controlled: redact the
                // message before mapping into a user error (warnings are not
                // consumed anywhere, but they are dropped here to keep the
                // contract explicit).
                throw ProcessPackageError(
                    message: redactor.redact(
                        ProcessPackageFailureMapper.terminalMessage(frame)))
            case .progress, .diagnostic:
                throw ProcessPackageRunError.missingTerminalFrame
            }
        }
    }

    /// Shared terminal-path wrapper: maps every thrown error through the
    /// request's redactor so a secret that reached stderr, a frame, or a
    /// launch error cannot escape. Cleanup of request-scoped files is owned
    /// by `execute`'s defer, which arms the moment the credential file exists
    /// and therefore covers this entire region.
    fileprivate func runManaged(
        redactor: ExtractorSecretRedactor,
        onProgress: (@Sendable (String) -> Void)?,
        _ body: @Sendable () async throws -> ProcessPackageExecutionOutcome
    ) async throws -> ProcessPackageExecutionOutcome {
        do {
            return try await body()
        } catch is CancellationError {
            throw CancellationError()
        } catch ManagedExtractorProcessError.cancellation {
            throw CancellationError()
        } catch {
            // Every other failure maps through the redactor so a secret that
            // reached stderr, a frame, or a launch error cannot escape.
            throw ProcessPackageError(message: redactor.redactedMessage(error))
        }
    }

    /// Result frames carry package-controlled article metadata (title,
    /// author, description, published) that downstream becomes persisted
    /// source filenames. Every text field passes through the request's
    /// redactor before the frame leaves the execution boundary.
    static func redactedResultFrame(
        _ frame: ExtractorResultFrame,
        redactor: ExtractorSecretRedactor
    ) throws -> ExtractorResultFrame {
        let metadata = frame.articleMetadata
        guard let metadata else { return frame }
        let redacted = try ExtractorArticleMetadata(
            title: metadata.title.map(redactor.redact),
            author: metadata.author.map(redactor.redact),
            description: metadata.description.map(redactor.redact),
            published: metadata.published.map(redactor.redact),
            wordCount: metadata.wordCount)
        return try ExtractorResultFrame(
            requestID: frame.requestID,
            outputPath: frame.outputPath,
            markdownByteCount: frame.markdownByteCount,
            warnings: frame.warnings.map(redactor.redact),
            metadata: frame.metadata,
            articleMetadata: redacted)
    }

    /// Creates a regular owner-read-only (0400) file at `url`. The file is
    /// created O_EXCL (never through an existing symlink), written fully,
    /// then verified: regular file, owner UID, link count 1, mode 0400, and
    /// containment within its own request subdirectory (plan steps 16-17).
    static func writeOwnerReadOnlyFile(_ data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // Refuse to overwrite anything that already exists (a planted symlink
        // at the target must never be written through).
        guard FileManager.default.fileExists(atPath: url.path) == false else {
            throw ExtractorDirectoryAdmissionError.preparationFailed
        }
        let fd = url.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL, 0o400)
        }
        guard fd >= 0 else {
            throw ExtractorDirectoryAdmissionError.preparationFailed
        }
        defer { close(fd) }
        let result: Int = data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return -1 }
            var remaining = raw.count
            var total = 0
            while remaining > 0 {
                let written = write(fd, pointer, remaining)
                if written <= 0 { return -1 }
                total += written
                pointer += written
                remaining -= written
            }
            return total
        }
        guard result == data.count else {
            throw ExtractorDirectoryAdmissionError.preparationFailed
        }
        try verifyOwnerReadOnlyFile(at: url)
    }

    /// Post-write verification: regular file, owner UID, link count 1, mode
    /// 0400, and containment within the operation directory layout.
    static func verifyOwnerReadOnlyFile(at url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw ExtractorDirectoryAdmissionError.preparationFailed
        }
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              status.st_nlink == 1,
              status.st_mode & 0o777 == 0o400 else {
            throw ExtractorDirectoryAdmissionError.preparationFailed
        }
    }
}

public struct ProcessPackagePDFExtractor: MarkdownExtractor, ProcessPackageProvenanceProviding {
    public var displayName: String { operation.manifest.displayName }
    public var packageProvenance: ExtractorPackageExecutionProvenance {
        ExtractorPackageExecutionProvenance(
            revision: operation.revision,
            registrationID: operation.registrationID,
            protocolRevision: operation.protocolRevision)
    }

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
        } catch is CancellationError {
            throw CancellationError()
        } catch ManagedExtractorProcessError.cancellation {
            throw CancellationError()
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

public struct ProcessPackageHTMLExtractor: HtmlMarkdownExtractor, ProcessPackageProvenanceProviding {
    public var displayName: String { operation.manifest.displayName }
    public var packageProvenance: ExtractorPackageExecutionProvenance {
        ExtractorPackageExecutionProvenance(
            revision: operation.revision,
            registrationID: operation.registrationID,
            protocolRevision: operation.protocolRevision)
    }

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
        } catch is CancellationError {
            DebugLog.extraction("Package HTML extraction was cancelled")
            return nil
        } catch {
            DebugLog.extraction(
                "Package HTML extraction fell back: \(ProcessPackageFailureMapper.message(error))")
            return nil
        }
    }
}
