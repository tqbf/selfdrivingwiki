import Foundation
import WikiFSCore

public struct RendererPackageValidationOutput: Codable, Equatable, Sendable {
    public let packageID: String
    public let version: String
    public let registrationIDs: [String]
    public let packageHash: String

    public init(validatedPackage: ValidatedRendererPackage) {
        packageID = validatedPackage.manifest.packageID.rawValue
        version = validatedPackage.manifest.version.rawValue
        registrationIDs = validatedPackage.manifest.descriptors
            .map(\.reference.registrationID.rawValue)
            .sorted()
        packageHash = validatedPackage.packageHash.hex
    }
}

public enum RendererPackageToolFailure: Error, Equatable, Sendable {
    case invalidArguments
    case validation(RendererPackageValidationError)
    case cleanupFailed
    case fileSystem(String)
    case unexpected(String)

    public var diagnostic: String {
        switch self {
        case .invalidArguments:
            return "usage: RendererPackageTool validate <package-folder>"
        case .validation(let error):
            return Self.validationDiagnostic(error)
        case .cleanupFailed:
            return "could not remove temporary validation data"
        case .fileSystem(let operation):
            return "could not prepare temporary validation data: \(operation)"
        case .unexpected(let message):
            return "validation failed: \(message)"
        }
    }

    private static func validationDiagnostic(_ error: RendererPackageValidationError) -> String {
        switch error {
        case .sourceIsNotDirectory:
            return "the package path must be one local folder"
        case .invalidPath(let path):
            return "the package contains an invalid path: \(path)"
        case .forbiddenFileType(let path):
            return "the package contains an unsupported file type: \(path)"
        case .sourceChanged(let path):
            return "the package changed during validation: \(path)"
        case .fileCountLimitExceeded:
            return "the package contains too many files"
        case .copiedByteLimitExceeded:
            return "the package is larger than the supported package limit"
        case .decodedInputLimitExceeded:
            return "a renderer decoded-input limit exceeds the supported maximum"
        case .missingManifest:
            return "the package folder must contain manifest.json"
        case .malformedManifest:
            return "manifest.json is malformed or does not satisfy package v1"
        case .missingDeclaredAsset(let path):
            return "manifest.json declares a missing asset: \(path)"
        case .undeclaredFile(let path):
            return "declare this package file in manifest.json: \(path)"
        case .assetHashMismatch(let path):
            return "the SHA-256 digest does not match the final bytes for: \(path)"
        case .packageHashMismatch:
            return "the package hash does not match"
        case .cleanupFailed:
            return "the validator could not remove temporary staging data"
        }
    }
}

public struct RendererPackageToolExecutor {
    public typealias ValidationRootFactory = @Sendable () throws -> URL
    public typealias ValidatorFactory = @Sendable (URL, URL, FileManager) -> RendererPackageValidator
    public typealias RootCleanup = @Sendable (URL) throws -> Void

    private let fileManager: FileManager
    private let validationRootFactory: ValidationRootFactory
    private let validatorFactory: ValidatorFactory
    private let rootCleanup: RootCleanup

    public init(
        fileManager: FileManager = .default,
        validationRootFactory: @escaping ValidationRootFactory = {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("renderer-package-validation-\(UUID().uuidString)", isDirectory: true)
        },
        validatorFactory: @escaping ValidatorFactory = { packagesRoot, stagingRoot, fileManager in
            RendererPackageValidator(
                packageRoot: packagesRoot,
                stagingRoot: stagingRoot,
                fileManager: fileManager,
                diagnose: { _ in })
        },
        rootCleanup: RootCleanup? = nil
    ) {
        self.fileManager = fileManager
        self.validationRootFactory = validationRootFactory
        self.validatorFactory = validatorFactory
        self.rootCleanup = rootCleanup ?? { root in
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        }
    }

    public func execute(arguments: [String]) throws -> RendererPackageValidationOutput {
        guard arguments.count == 2, arguments[0] == "validate" else {
            throw RendererPackageToolFailure.invalidArguments
        }

        let invocationRoot: URL
        do {
            invocationRoot = try validationRootFactory().standardizedFileURL
        } catch {
            throw RendererPackageToolFailure.fileSystem("create root path")
        }

        let result: Result<RendererPackageValidationOutput, RendererPackageToolFailure>
        do {
            let packagesRoot = invocationRoot.appendingPathComponent("packages", isDirectory: true)
            let stagingRoot = invocationRoot.appendingPathComponent("staging", isDirectory: true)
            try fileManager.createDirectory(at: packagesRoot, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            let source = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
            let validator = validatorFactory(packagesRoot, stagingRoot, fileManager)
            let package = try validator.validate(directory: source)
            result = .success(RendererPackageValidationOutput(validatedPackage: package))
        } catch let error as RendererPackageValidationError {
            result = .failure(.validation(error))
        } catch {
            result = .failure(.unexpected(Self.safeDescription(error)))
        }

        do {
            try rootCleanup(invocationRoot)
        } catch {
            throw RendererPackageToolFailure.cleanupFailed
        }

        return try result.get()
    }

    private static func safeDescription(_ error: any Error) -> String {
        if let cocoaError = error as? CocoaError {
            return cocoaError.code == .fileNoSuchFile
                ? "the package path does not exist"
                : "a file operation failed"
        }
        if let posixError = error as? POSIXError {
            return posixError.code == .ENOENT
                ? "the package path does not exist"
                : "a file operation failed"
        }
        return String(describing: error)
    }
}
