import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import WikiFSCore
import WikiFSTypes

public struct ExtractorPackageValidationOutput: Codable, Equatable, Sendable {
    public let command: String
    public let packageID: String
    public let version: String
    public let packageDigest: String
    public let registrationIDs: [String]
    public let protocolRevision: Int
    public let frameCount: Int?
    public let progressEventCount: Int?
    public let terminalKind: String?

    init(validatedDirectory: ValidatedExtractorDirectory) {
        command = "validate"
        packageID = validatedDirectory.revisionID.packageID.rawValue
        version = validatedDirectory.revisionID.version.rawValue
        packageDigest = validatedDirectory.revisionID.digest.hex
        registrationIDs = validatedDirectory.validated.manifest.registrations.map(\.id.rawValue).sorted()
        protocolRevision = validatedDirectory.validated.manifest.protocolRevision.rawValue
        frameCount = nil
        progressEventCount = nil
        terminalKind = nil
    }

    init(
        validatedDirectory: ValidatedExtractorDirectory,
        frameCount: Int,
        progressEventCount: Int,
        terminalKind: String
    ) {
        command = "protocol-smoke"
        packageID = validatedDirectory.revisionID.packageID.rawValue
        version = validatedDirectory.revisionID.version.rawValue
        packageDigest = validatedDirectory.revisionID.digest.hex
        registrationIDs = validatedDirectory.validated.manifest.registrations.map(\.id.rawValue).sorted()
        protocolRevision = validatedDirectory.validated.manifest.protocolRevision.rawValue
        self.frameCount = frameCount
        self.progressEventCount = progressEventCount
        self.terminalKind = terminalKind
    }
}

public enum ExtractorPackageToolFailure: Error, Equatable, Sendable {
    case invalidArguments
    case admission(ExtractorDirectoryAdmissionError)
    case requestTooLarge
    case malformedRequest
    case protocolRevisionMismatch
    case unsupportedRegistration
    case framesTooLarge
    case frames(ExtractorJSONLinesError)
    case sequence(ExtractorProtocolSequenceError)
    case cleanupFailed
    case fileSystem

    public var diagnostic: String {
        switch self {
        case .invalidArguments:
            "usage: extractor-package-tool validate <package-folder> | protocol-smoke <package-folder> <request.json> <frames.jsonl>"
        case .admission(let error):
            "package validation failed: \(Self.admissionDiagnostic(error))"
        case .requestTooLarge:
            "the protocol request exceeds the supported byte limit"
        case .malformedRequest:
            "the protocol request is malformed"
        case .protocolRevisionMismatch:
            "the protocol request revision does not match the package"
        case .unsupportedRegistration:
            "the package has no registration for the request kind and MIME type"
        case .framesTooLarge:
            "the protocol frame fixture exceeds the supported byte limit"
        case .frames(let error):
            "the protocol frame fixture is invalid: \(error)"
        case .sequence(let error):
            "the protocol frame sequence is invalid: \(error)"
        case .cleanupFailed:
            "could not remove temporary validation data"
        case .fileSystem:
            "could not read or prepare validation data"
        }
    }

    private static func admissionDiagnostic(_ error: ExtractorDirectoryAdmissionError) -> String {
        switch error {
        case .nonFileURL, .sourceNotDirectory:
            "the package path must be one local folder"
        case .mutationForbidden:
            "the validation process cannot create isolated staging data"
        case .sourceChanged, .metadataChanged, .modeChanged:
            "the package changed during validation"
        case .symlink, .hardLink, .specialFile, .deviceChanged:
            "the package contains an unsupported file"
        case .collision:
            "the package contains colliding paths"
        case .containment:
            "the package path escapes the validation root"
        case .copyFailed, .preparationFailed:
            "the validator could not copy the package"
        case .validationFailed, .expectedRevisionMismatch:
            "the package revision is invalid"
        case .invalidStagingID:
            "the validator staging identifier is invalid"
        case .limitExceeded:
            "the package exceeds a host limit"
        case .manifest(let error):
            "manifest validation failed: \(error)"
        }
    }
}

public struct ExtractorPackageToolExecutor: Sendable {
    public typealias ValidationRootFactory = @Sendable () throws -> URL
    public typealias RootCleanup = @Sendable (URL) throws -> Void

    private let validationRootFactory: ValidationRootFactory
    private let rootCleanup: RootCleanup

    public init(
        validationRootFactory: @escaping ValidationRootFactory = {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("extractor-package-validation-\(UUID().uuidString)", isDirectory: true)
        },
        rootCleanup: RootCleanup? = nil
    ) {
        self.validationRootFactory = validationRootFactory
        self.rootCleanup = rootCleanup ?? { root in
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        }
    }

    public func execute(arguments: [String]) throws -> ExtractorPackageValidationOutput {
        let command: Command
        if arguments.count == 2, arguments[0] == "validate" {
            command = .validate(packagePath: arguments[1])
        } else if arguments.count == 4, arguments[0] == "protocol-smoke" {
            command = .protocolSmoke(
                packagePath: arguments[1],
                requestPath: arguments[2],
                framesPath: arguments[3])
        } else {
            throw ExtractorPackageToolFailure.invalidArguments
        }

        let invocationRoot: URL
        do {
            invocationRoot = try validationRootFactory().standardizedFileURL
        } catch {
            throw ExtractorPackageToolFailure.fileSystem
        }

        let result: Result<ExtractorPackageValidationOutput, ExtractorPackageToolFailure>
        do {
            let layout = try ExtractorPackageStoreLayout(
                appGroupContainerRoot: invocationRoot,
                processRole: .test)
            let packageRoot = URL(
                fileURLWithPath: command.packagePath,
                isDirectory: true).standardizedFileURL
            let validated = try ExtractorDirectoryValidator.admit(
                source: packageRoot,
                layout: layout)
            switch command {
            case .validate:
                result = .success(ExtractorPackageValidationOutput(validatedDirectory: validated))
            case .protocolSmoke(_, let requestPath, let framesPath):
                result = .success(try smoke(
                    validated: validated,
                    requestURL: URL(fileURLWithPath: requestPath),
                    framesURL: URL(fileURLWithPath: framesPath)))
            }
        } catch let failure as ExtractorPackageToolFailure {
            result = .failure(failure)
        } catch let error as ExtractorDirectoryAdmissionError {
            result = .failure(.admission(error))
        } catch {
            result = .failure(.fileSystem)
        }

        do {
            try rootCleanup(invocationRoot)
        } catch {
            throw ExtractorPackageToolFailure.cleanupFailed
        }
        return try result.get()
    }

    private func smoke(
        validated: ValidatedExtractorDirectory,
        requestURL: URL,
        framesURL: URL
    ) throws -> ExtractorPackageValidationOutput {
        let requestData = try readBounded(
            requestURL,
            maximumByteCount: ExtractorHostLimits.maximumFrameByteCount,
            overflow: .requestTooLarge)
        let request: ExtractorProtocolRequest
        do {
            request = try JSONDecoder().decode(ExtractorProtocolRequest.self, from: requestData)
        } catch {
            throw ExtractorPackageToolFailure.malformedRequest
        }
        let manifest = validated.validated.manifest
        guard request.protocolRevision == manifest.protocolRevision else {
            throw ExtractorPackageToolFailure.protocolRevisionMismatch
        }
        let isSupported = manifest.registrations.contains { registration in
            registration.kinds.contains(request.kind) && registration.mimeTypes.contains(request.mimeType)
        }
        guard isSupported else { throw ExtractorPackageToolFailure.unsupportedRegistration }

        let maximumFramesByteCount = min(
            ExtractorHostLimits.maximumPackageByteCount,
            ExtractorHostLimits.maximumFrameByteCount * (manifest.limits.maximumProgressEventCount + 130))
        let frameData = try readBounded(
            framesURL,
            maximumByteCount: maximumFramesByteCount,
            overflow: .framesTooLarge)
        var decoder = ExtractorJSONLinesDecoder()
        let frames: [ExtractorProtocolFrame]
        do {
            frames = try decoder.append(frameData)
            try decoder.finish()
        } catch let error as ExtractorJSONLinesError {
            throw ExtractorPackageToolFailure.frames(error)
        }
        var sequence = ExtractorProtocolSequence(
            requestID: request.requestID,
            expectedOutputPath: request.outputPath,
            maximumProgressEventCount: manifest.limits.maximumProgressEventCount)
        do {
            for frame in frames { try sequence.consume(frame) }
            let terminal = try sequence.finish()
            return ExtractorPackageValidationOutput(
                validatedDirectory: validated,
                frameCount: frames.count,
                progressEventCount: sequence.progressEventCount,
                terminalKind: terminalKind(terminal))
        } catch let error as ExtractorProtocolSequenceError {
            throw ExtractorPackageToolFailure.sequence(error)
        }
    }

    private func readBounded(
        _ url: URL,
        maximumByteCount: Int,
        overflow: ExtractorPackageToolFailure
    ) throws -> Data {
        var pathStatus = stat()
        guard lstat(url.path, &pathStatus) == 0,
              pathStatus.st_mode & S_IFMT == S_IFREG,
              pathStatus.st_nlink == 1,
              pathStatus.st_size >= 0 else {
            throw ExtractorPackageToolFailure.fileSystem
        }
        guard pathStatus.st_size <= maximumByteCount else { throw overflow }
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw ExtractorPackageToolFailure.fileSystem }
        defer { close(descriptor) }
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
              openedStatus.st_dev == pathStatus.st_dev,
              openedStatus.st_ino == pathStatus.st_ino,
              openedStatus.st_mode & S_IFMT == S_IFREG,
              openedStatus.st_nlink == 1 else {
            throw ExtractorPackageToolFailure.fileSystem
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, maximumByteCount + 1))
        while data.count <= maximumByteCount {
            let count = read(descriptor, &buffer, buffer.count)
            guard count >= 0 else { throw ExtractorPackageToolFailure.fileSystem }
            if count == 0 { break }
            data.append(contentsOf: buffer[0 ..< count])
            guard data.count <= maximumByteCount else { throw overflow }
        }
        var afterStatus = stat()
        guard fstat(descriptor, &afterStatus) == 0,
              afterStatus.st_dev == openedStatus.st_dev,
              afterStatus.st_ino == openedStatus.st_ino,
              afterStatus.st_size == openedStatus.st_size,
              afterStatus.st_mode == openedStatus.st_mode else {
            throw ExtractorPackageToolFailure.fileSystem
        }
        return data
    }

    private func terminalKind(_ frame: ExtractorProtocolFrame) -> String {
        switch frame {
        case .result: "result"
        case .failure: "failure"
        case .progress, .diagnostic: preconditionFailure("terminal frame required")
        }
    }
}

private enum Command: Sendable {
    case validate(packagePath: String)
    case protocolSmoke(packagePath: String, requestPath: String, framesPath: String)

    var packagePath: String {
        switch self {
        case .validate(let packagePath), .protocolSmoke(let packagePath, _, _): packagePath
        }
    }
}
