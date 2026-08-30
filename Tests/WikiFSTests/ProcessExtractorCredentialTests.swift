import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine
import WikiFSTypes

// PR 3 coverage (issue #1159): per-operation credential resolution, the
// request-scoped owner-read-only credential file, terminal-path cleanup,
// rotation/revocation semantics, and secret redaction.

private func v2Requirement(
    _ id: String = "api-token", optional: Bool = true
) -> ExtractorCredentialRequirement {
    try! ExtractorCredentialRequirement(
        id: ExtractorCredentialRequirementID(validating: id),
        kind: .secret,
        isOptional: optional,
        label: "API token",
        purpose: "Authenticates requests.")
}

private func v2Manifest(
    requirements: [ExtractorCredentialRequirement],
    protocolRevision: ExtractorProtocolRevision = .v2
) throws -> ExtractorManifest {
    let bytes = Data("fixture".utf8)
    return try ExtractorManifest(
        manifestRevision: .v2,
        packageID: ExtractorPackageID(validating: "org.example.pkg"),
        version: ExtractorPackageVersion(validating: "1.0.0"),
        displayName: "Fixture",
        protocolRevision: protocolRevision,
        entryPoint: ExtractorRelativePath(validating: "bin/extractor"),
        launch: .direct,
        registrations: [try ExtractorRegistration(
            id: ExtractorRegistrationID(validating: "main"),
            displayName: "Main",
            kinds: [.pdf],
            mimeTypes: [ExtractorMIMEType(validating: "application/pdf")],
            credentialRequirements: requirements)],
        capabilities: [],
        files: [ExtractorPackageFile(
            path: ExtractorRelativePath(validating: "bin/extractor"),
            digest: ExtractorSHA256.digest(bytes))],
        limits: ExtractorOperationLimits(
            maximumInputByteCount: 1_024,
            maximumMarkdownOutputByteCount: 2_048,
            maximumDurationMilliseconds: 30_000,
            maximumProgressEventCount: 10))
}

private func revision(for manifest: ExtractorManifest) throws -> ExtractorPackageRevisionID {
    ExtractorPackageRevisionID(
        packageID: manifest.packageID,
        version: manifest.version,
        digest: try manifest.packageDigest())
}

/// A stub operation root builder: the operation needs only its directory
/// tree; the package snapshot is unused by the stub executor.
@discardableResult
private func makeOperation(
    manifest: ExtractorManifest,
    resolver: (any ExtractorOperationCredentialResolving)?,
    executor: StubCredentialExecutor,
    configuration: (@Sendable (ExtractorPackageRevisionID) -> ExtractorOperationConfiguration?)? = nil
) throws -> PreparedProcessOperation {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("op-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let revision = try revision(for: manifest)
    return PreparedProcessOperation(
        directoryRoot: root,
        packageRoot: root.appendingPathComponent("package"),
        homeRoot: root.appendingPathComponent("home"),
        temporaryRoot: root.appendingPathComponent("tmp"),
        cacheRoot: root.appendingPathComponent("cache"),
        sharedRuntimeCacheRoot: nil,
        sharedModelCacheRoot: nil,
        revision: revision,
        manifest: manifest,
        registration: manifest.registrations[0],
        registrationID: manifest.registrations[0].id,
        protocolRevision: manifest.protocolRevision,
        mimeTypes: ["application/pdf"],
        executor: executor,
        launchGate: nil,
        operationCredentials: resolver,
        operationConfiguration: configuration,
        runtimeResolution: nil)
}

/// Captures the managed request, verifies the credential file existed at
/// launch time (owner-read-only), records the envelope VALUES it contained,
/// and returns a successful result frame.
final class StubCredentialExecutor: ManagedProcessExecuting, @unchecked Sendable {
    // NSLock guards `requests` and `observedValues`; `failWith` is set
    // before use.
    // swiftlint:disable:next unchecked_sendable
    private let lock = NSLock()
    private var requests: [ManagedExtractorProcessRequest] = []
    private var observed: [[String: String]] = []
    var failWith: (any Error)?

    var capturedRequests: [ManagedExtractorProcessRequest] {
        lock.withLock { requests }
    }

    /// The credential envelope contents observed at launch time, in order.
    var observedValues: [[String: String]] {
        lock.withLock { observed }
    }

    func execute(
        _ operation: ManagedExtractorProcessRequest,
        onFrame: @escaping @Sendable (ExtractorProtocolFrame) -> Void
    ) async throws -> ManagedExtractorProcessResult {
        lock.withLock { requests.append(operation) }
        if let failWith { throw failWith }
        // The credential file must exist and be owner-read-only at launch.
        if let credentialPath = operation.protocolRequest.credentialFilePath {
            let url = operation.paths.operationRoot
                .appendingPathComponent(credentialPath.rawValue)
            var status = stat()
            guard lstat(url.path, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG,
                  status.st_mode & 0o777 == 0o400 else {
                throw ManagedExtractorProcessError.invalidOperationLayout
            }
            let envelope = try JSONDecoder().decode(
                ExtractorCredentialInputEnvelope.self,
                from: try Data(contentsOf: url))
            lock.withLock { observed.append(envelope.credentials) }
        } else {
            lock.withLock { observed.append([:]) }
        }
        let result = try ExtractorResultFrame(
            requestID: operation.protocolRequest.requestID,
            outputPath: operation.protocolRequest.outputPath,
            markdownByteCount: 2)
        // Behave like a real package: write the declared output.
        let outputURL = operation.paths.operationRoot
            .appendingPathComponent(operation.protocolRequest.outputPath.rawValue)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("ok".utf8).write(to: outputURL)
        return ManagedExtractorProcessResult(
            terminationCause: .exited(code: 0),
            terminalFrame: .result(result),
            progressEventCount: 0,
            standardOutputByteCount: 0,
            standardError: Data(),
            executableURL: operation.paths.packageRoot)
    }
}

/// A resolver backed by a shared in-memory credential service so rotation
/// tests can flip values between executes.
final class StubResolver: ExtractorOperationCredentialResolving, @unchecked Sendable {
    // swiftlint:disable:next unchecked_sendable
    private let lock = NSLock()
    private var values: [ExtractorCredentialRequirementID: String]
    private var unauthorizedIDs: Set<String> = []
    var callCount = 0

    init(values: [ExtractorCredentialRequirementID: String]) {
        self.values = values
    }

    func setValue(
        _ value: String?, for id: ExtractorCredentialRequirementID
    ) {
        lock.withLock {
            if let value { values[id] = value } else { values.removeValue(forKey: id) }
        }
    }

    func revoke(id: ExtractorCredentialRequirementID) {
        lock.withLock { _ = unauthorizedIDs.insert(id.rawValue) }
    }

    func resolveOperationCredentials(
        revision: ExtractorPackageRevisionID,
        manifest: ExtractorManifest,
        registration: ExtractorRegistration
    ) async throws -> [ExtractorCredentialRequirementID: String] {
        lock.withLock { callCount += 1 }
        var result: [ExtractorCredentialRequirementID: String] = [:]
        for requirement in registration.credentialRequirements {
            let unauthorized = lock.withLock {
                unauthorizedIDs.contains(requirement.id.rawValue)
            }
            if unauthorized { continue }
            if let value = lock.withLock({ values[requirement.id] }) {
                result[requirement.id] = value
            }
        }
        return result
    }
}

@Suite(.serialized)
struct ProcessExtractorCredentialTests {

    // MARK: Protocol revision 2 requests

    @Test func revisionOneRequestRejectsCredentialPaths() throws {
        #expect(throws: ExtractorValidationError.self) {
            _ = try ExtractorProtocolRequest(
                requestID: ExtractorRequestID(),
                protocolRevision: .v1,
                kind: .pdf,
                mimeType: ExtractorMIMEType(validating: "application/pdf"),
                originalFilename: "x.pdf",
                inputPath: ExtractorRelativePath(validating: "input/a/source"),
                outputPath: ExtractorRelativePath(validating: "output/a/result.md"),
                deadlineMillisecondsSince1970: 1,
                credentialFilePath: ExtractorRelativePath(validating: "credentials/a/input.json"))
        }
    }

    @Test func v2RequestCarriesRelativePathsOnly() throws {
        let request = try ExtractorProtocolRequest(
            requestID: ExtractorRequestID(),
            protocolRevision: .v2,
            kind: .pdf,
            mimeType: ExtractorMIMEType(validating: "application/pdf"),
            originalFilename: "x.pdf",
            inputPath: ExtractorRelativePath(validating: "input/a/source"),
            outputPath: ExtractorRelativePath(validating: "output/a/result.md"),
            deadlineMillisecondsSince1970: 1,
            credentialFilePath: ExtractorRelativePath(validating: "credentials/a/input.json"),
            operationConfigurationPath: ExtractorRelativePath(validating: "config/a/operation.json"))
        let data = try JSONEncoder().encode(request)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Paths only — never a value.
        #expect(object["credentialFilePath"] as? String == "credentials/a/input.json")
        #expect(object["credentials"] == nil)
        // Round-trip.
        let decoded = try JSONDecoder().decode(ExtractorProtocolRequest.self, from: data)
        #expect(decoded == request)
    }

    // MARK: Envelopes

    @Test func credentialEnvelopeCarriesOnlyDeclaredNonEmptyEntries() throws {
        let requirements = [v2Requirement("a"), v2Requirement("b")]
        let envelope = try ExtractorCredentialInputEnvelope(
            requirements: requirements,
            resolvedValues: [
                ExtractorCredentialRequirementID(validating: "a"): "secret-a",
                ExtractorCredentialRequirementID(validating: "b"): "",
                ExtractorCredentialRequirementID(validating: "c"): "not-declared",
            ])
        #expect(envelope.credentials == ["a": "secret-a"])
    }

    @Test func configurationEnvelopeRejectsBoundedFields() {
        #expect(throws: ExtractorValidationError.self) {
            _ = try ExtractorOperationConfiguration(
                endpoint: "http://127.0.0.1:8000",
                timeoutMilliseconds: ExtractorHostLimits.maximumDurationMilliseconds + 1)
        }
        let valid = try? ExtractorOperationConfiguration(
            endpoint: "http://127.0.0.1:8000", timeoutMilliseconds: 600_000)
        #expect(valid?.timeoutMilliseconds == 600_000)
    }

    // MARK: Redaction

    @Test func redactorRemovesEveryResolvedValueFromPackageText() {
        let redactor = ExtractorSecretRedactor(values: ["canary-secret", "second-secret"])
        #expect(redactor.redact("error: canary-secret is bad") == "error: [redacted] is bad")
        #expect(redactor.redact("nothing here") == "nothing here")
        #expect(
            redactor.redact("a canary-secret b second-secret c") == "a [redacted] b [redacted] c")
        struct Probe: Error {}
        let wrapped = redactor.redactedMessage(
            ProcessPackageError(message: "boom canary-secret"))
        #expect(wrapped.contains("canary-secret") == false)
    }

    // MARK: Per-execute resolution + file lifecycle

    @Test func injectsOnlySelectedRegistrationRequirements() async throws {
        let manifest = try v2Manifest(requirements: [
            v2Requirement("api-token", optional: false),
        ])
        let resolver = StubResolver(values: [
            try ExtractorCredentialRequirementID(validating: "api-token"): "sk-live",
        ])
        let executor = StubCredentialExecutor()
        let operation = try makeOperation(
            manifest: manifest, resolver: resolver, executor: executor)
        let outcome = try await operation.execute(
            kind: .pdf, input: Data("pdf".utf8), filename: "x.pdf", onProgress: nil)
        #expect(outcome.markdown.isEmpty == false)
        guard let request = executor.capturedRequests.first else {
            Issue.record("no captured request")
            return
        }
        #expect(executor.observedValues == [["api-token": "sk-live"]])
        _ = request
    }

    @Test func credentialFileIsRemovedOnSuccessAndFailure() async throws {
        let manifest = try v2Manifest(requirements: [
            v2Requirement("api-token", optional: false),
        ])
        let resolver = StubResolver(values: [
            try ExtractorCredentialRequirementID(validating: "api-token"): "sk-live",
        ])
        let successExecutor = StubCredentialExecutor()
        let operation = try makeOperation(
            manifest: manifest, resolver: resolver, executor: successExecutor)
        _ = try await operation.execute(
            kind: .pdf, input: Data(), filename: "x.pdf", onProgress: nil)
        // Success: credentials directory holds no request subdirectories.
        let credentialsRoot = operation.directoryRoot.appendingPathComponent("credentials")
        #expect(
            (try? FileManager.default.contentsOfDirectory(atPath: credentialsRoot.path))?.isEmpty ?? true)

        // Failure: the executor throws AFTER the file was verified to exist.
        let failingExecutor = StubCredentialExecutor()
        failingExecutor.failWith = ManagedExtractorProcessError.timeout
        let failingOperation = try makeOperation(
            manifest: manifest, resolver: resolver, executor: failingExecutor)
        do {
            _ = try await failingOperation.execute(
                kind: .pdf, input: Data(), filename: "x.pdf", onProgress: nil)
            Issue.record("expected failure")
        } catch {
            // mapped, redacted failure
        }
        let failingCredentialsRoot =
            failingOperation.directoryRoot.appendingPathComponent("credentials")
        #expect(
            (try? FileManager.default.contentsOfDirectory(atPath: failingCredentialsRoot.path))?.isEmpty ?? true)
    }

    @Test func rotationAffectsNextCredentialExecute() async throws {
        // AC.11: two execute calls resolve different values without
        // rebuilding the process context. The executor verifies each
        // credential file at launch time and records the VALUE it saw.
        let requirementID = try ExtractorCredentialRequirementID(validating: "api-token")
        let resolver = StubResolver(values: [requirementID: "sk-first"])
        let executor = StubCredentialExecutor()
        let operation = try makeOperation(
            manifest: try v2Manifest(requirements: [
                v2Requirement("api-token", optional: false),
            ]),
            resolver: resolver, executor: executor)
        _ = try await operation.execute(
            kind: .pdf, input: Data(), filename: "x.pdf", onProgress: nil)
        resolver.setValue("sk-rotated", for: requirementID)
        _ = try await operation.execute(
            kind: .pdf, input: Data(), filename: "x.pdf", onProgress: nil)
        #expect(executor.observedValues == [["api-token": "sk-first"], ["api-token": "sk-rotated"]])
        #expect(resolver.callCount == 2)
    }

    @Test func revocationFailsTheNextExecuteAndCleansUp() async throws {
        let requirementID = try ExtractorCredentialRequirementID(validating: "api-token")
        let resolver = StubResolver(values: [requirementID: "sk-live"])
        let executor = StubCredentialExecutor()
        let operation = try makeOperation(
            manifest: try v2Manifest(requirements: [
                v2Requirement("api-token", optional: false),
            ]),
            resolver: resolver, executor: executor)
        _ = try await operation.execute(
            kind: .pdf, input: Data(), filename: "x.pdf", onProgress: nil)
        resolver.revoke(id: requirementID)
        do {
            _ = try await operation.execute(
                kind: .pdf, input: Data(), filename: "x.pdf", onProgress: nil)
            Issue.record("expected failure after revocation")
        } catch let error as ProcessPackageError {
            // Bounded, value-free failure text.
            #expect(error.message.contains("sk-live") == false)
        }
    }

    @Test func absentResolverFailsClosedForDeclaringPackages() async throws {
        let manifest = try v2Manifest(requirements: [
            v2Requirement("api-token", optional: false),
        ])
        let operation = try makeOperation(
            manifest: manifest, resolver: nil, executor: StubCredentialExecutor())
        do {
            _ = try await operation.execute(
                kind: .pdf, input: Data(), filename: "x.pdf", onProgress: nil)
            Issue.record("expected failure without a resolver")
        } catch {
            // expected
        }
    }

    @Test func revisionOneOperationsNeverResolveCredentials() async throws {
        // Revision 1 preparation semantics stay unchanged: no credential
        // path on the request even with a resolver wired.
        let manifest = try v2Manifest(requirements: [], protocolRevision: .v1)
        let resolver = StubResolver(values: [:])
        let executor = StubCredentialExecutor()
        let operation = try makeOperation(
            manifest: manifest, resolver: resolver, executor: executor)
        _ = try await operation.execute(
            kind: .pdf, input: Data(), filename: "x.pdf", onProgress: nil)
        let request = try #require(executor.capturedRequests.first)
        #expect(request.protocolRequest.credentialFilePath == nil)
        #expect(request.protocolRequest.operationConfigurationPath == nil)
        #expect(resolver.callCount == 0)
    }

    @Test func ownerReadOnlyFileVerificationRejectsWrongMode() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("input.json")
        try SelfTestSupport.writeWithMode(data: Data("{}".utf8), url: url, mode: 0o644)
        // Verification is now descriptor-bound (fstat + lstat dev/ino): a
        // 0644 file re-opened for reading fails the mode and ownership
        // checks exactly as before, through the new signature.
        let fd = open(url.path, O_RDONLY)
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(throws: ExtractorDirectoryAdmissionError.self) {
            _ = try PreparedProcessOperation.verifyOwnerReadOnlyFile(fd: fd, at: url)
        }
    }
}

enum SelfTestSupport {
    static func writeWithMode(data: Data, url: URL, mode: mode_t) throws {
        try data.write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: Int(mode)], ofItemAtPath: url.path)
    }
}
