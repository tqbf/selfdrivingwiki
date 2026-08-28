import Foundation
import WikiFSTypes
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum ExtractorManifestValidationError: Error, Equatable, Sendable {
    case manifestTooLarge
    case malformedManifest
    case undeclaredFile(String)
    case missingDeclaredFile(String)
    case forbiddenFileType(String)
    case normalizedPathCollision(String)
    case fileCountLimitExceeded
    case packageByteLimitExceeded
    case fileDigestMismatch(String)
    case directEntryPointIsNotOwnerExecutable
    case runtimeEntryPointIsNotReadable
}

public struct ValidatedExtractorManifest: Sendable {
    public let manifest: ExtractorManifest
    public let revisionID: ExtractorPackageRevisionID
    public let root: URL

    fileprivate init(manifest: ExtractorManifest, revisionID: ExtractorPackageRevisionID, root: URL) {
        self.manifest = manifest
        self.revisionID = revisionID
        self.root = root
    }
}

/// Validates an already staged directory. Phase 3 owns secure copying and mode normalization.
public enum ExtractorManifestValidator {
    public static let manifestFileName = "manifest.json"

    public static func validateStagedDirectory(_ root: URL) throws -> ValidatedExtractorManifest {
        let manifestURL = root.appendingPathComponent(manifestFileName, isDirectory: false)
        let manifestStatus = try fileStatus(manifestURL)
        guard isRegularFile(manifestStatus), manifestStatus.st_nlink == 1 else {
            throw ExtractorManifestValidationError.forbiddenFileType(manifestFileName)
        }
        guard manifestStatus.st_size <= ExtractorHostLimits.maximumManifestByteCount else {
            throw ExtractorManifestValidationError.manifestTooLarge
        }
        let manifestData = try Data(contentsOf: manifestURL)
        guard manifestData.count <= ExtractorHostLimits.maximumManifestByteCount else {
            throw ExtractorManifestValidationError.manifestTooLarge
        }
        let manifest: ExtractorManifest
        do {
            manifest = try JSONDecoder().decode(ExtractorManifest.self, from: manifestData)
        } catch {
            throw ExtractorManifestValidationError.malformedManifest
        }

        var regularFiles: [ExtractorRelativePath: URL] = [:]
        var collisionKeys: Set<String> = []
        var fileCount = 0
        var byteCount = 0
        let rootComponents = root.standardizedFileURL.pathComponents
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []) else {
            throw ExtractorManifestValidationError.malformedManifest
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            let relative = url.standardizedFileURL.pathComponents.dropFirst(rootComponents.count).joined(separator: "/")
            guard let path = ExtractorRelativePath(rawValue: relative) else {
                throw ExtractorManifestValidationError.forbiddenFileType(relative)
            }
            guard collisionKeys.insert(path.collisionKey).inserted else {
                throw ExtractorManifestValidationError.normalizedPathCollision(path.rawValue)
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ExtractorManifestValidationError.forbiddenFileType(path.rawValue)
            }
            if path.rawValue == manifestFileName { continue }
            fileCount += 1
            byteCount += values.fileSize ?? 0
            guard fileCount <= ExtractorHostLimits.maximumPackageFileCount else {
                throw ExtractorManifestValidationError.fileCountLimitExceeded
            }
            guard byteCount <= ExtractorHostLimits.maximumPackageByteCount else {
                throw ExtractorManifestValidationError.packageByteLimitExceeded
            }
            regularFiles[path] = url
        }

        let declared = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0) })
        for path in regularFiles.keys where declared[path] == nil {
            throw ExtractorManifestValidationError.undeclaredFile(path.rawValue)
        }
        for file in manifest.files {
            guard let url = regularFiles[file.path] else {
                throw ExtractorManifestValidationError.missingDeclaredFile(file.path.rawValue)
            }
            guard ExtractorSHA256.digest(try Data(contentsOf: url, options: [.mappedIfSafe])) == file.digest else {
                throw ExtractorManifestValidationError.fileDigestMismatch(file.path.rawValue)
            }
        }

        let entryURL = root.appendingPathComponent(manifest.entryPoint.rawValue, isDirectory: false)
        let status = try fileStatus(entryURL)
        switch manifest.launch {
        case .direct:
            guard status.st_mode & S_IRUSR != 0, status.st_mode & S_IXUSR != 0 else {
                throw ExtractorManifestValidationError.directEntryPointIsNotOwnerExecutable
            }
        case .runtime:
            guard status.st_mode & S_IRUSR != 0 else {
                throw ExtractorManifestValidationError.runtimeEntryPointIsNotReadable
            }
        }

        let digest = try manifest.packageDigest()
        return ValidatedExtractorManifest(
            manifest: manifest,
            revisionID: ExtractorPackageRevisionID(
                packageID: manifest.packageID,
                version: manifest.version,
                digest: digest),
            root: root)
    }

    private static func fileStatus(_ url: URL) throws -> stat {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return status
    }

    private static func isRegularFile(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFREG
    }
}
