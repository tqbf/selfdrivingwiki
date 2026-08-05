import Foundation
import Darwin

/// Named, conservative bounds for local renderer package v1 ingestion.
public enum RendererPackageValidationLimits {
    public static let maximumFileCount = 1_024
    public static let maximumCopiedByteCount = 32 * 1_024 * 1_024
    public static let maximumDecodedInputByteCount = 64 * 1_024 * 1_024
    static let manifestFileName = "manifest.json"
    static let stagingDirectoryName = ".staging"
    static let packagesDirectoryName = "renderer-packages"
}

public enum RendererPackageValidationError: Error, Equatable, Sendable {
    case sourceIsNotDirectory
    case invalidPath(String)
    case forbiddenFileType(String)
    case sourceChanged(String)
    case fileCountLimitExceeded
    case copiedByteLimitExceeded
    case decodedInputLimitExceeded
    case missingManifest
    case malformedManifest
    case missingDeclaredAsset(String)
    case undeclaredFile(String)
    case assetHashMismatch(String)
    case packageHashMismatch
    case cleanupFailed(String)
}

/// A package that has been copied, fully validated, and pinned to its immutable
/// package hash. Its initializer is intentionally unavailable to callers.
public struct ValidatedRendererPackage: Sendable {
    public let manifest: RendererManifest
    public let packageHash: RendererSHA256Digest
    public let stagedRoot: URL

    fileprivate init(manifest: RendererManifest, packageHash: RendererSHA256Digest, stagedRoot: URL) {
        self.manifest = manifest
        self.packageHash = packageHash
        self.stagedRoot = stagedRoot
    }
}

/// The sole authority for renderer-package v1 filesystem validation. Package
/// payloads live below a machine/App Group root, never a wiki.
public final class RendererPackageValidator {
    private let packageRoot: URL
    private let fileManager: FileManager
    private let diagnose: @Sendable (String) -> Void

    public init(
        packageRoot: URL,
        fileManager: FileManager = .default,
        diagnose: @escaping @Sendable (String) -> Void = { DebugLog.store($0) }
    ) {
        self.packageRoot = packageRoot.standardizedFileURL
        self.fileManager = fileManager
        self.diagnose = diagnose
    }

    public convenience init(diagnose: @escaping @Sendable (String) -> Void = { DebugLog.store($0) }) throws {
        let root = try DatabaseLocation.appGroupContainerDirectory()
            .appendingPathComponent(RendererPackageValidationLimits.packagesDirectoryName, isDirectory: true)
        self.init(packageRoot: root, diagnose: diagnose)
    }

    /// Removes abandoned staging directories. A cleanup error is reported so it
    /// cannot be mistaken for a successful recovery.
    public func recoverStaging() throws {
        let stagingRoot = packageRoot.appendingPathComponent(RendererPackageValidationLimits.stagingDirectoryName, isDirectory: true)
        guard fileManager.fileExists(atPath: stagingRoot.path) else { return }
        for child in try fileManager.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: nil) {
            try removeOrDiagnose(child)
        }
    }

    /// Copies a local directory into package-root staging and validates only that
    /// copied tree. No archive or remote source is accepted by this API.
    public func validate(directory source: URL, expectedHash: RendererSHA256Digest? = nil) throws -> ValidatedRendererPackage {
        try ensureDirectory(source, label: source.path)
        let stagingRoot = packageRoot.appendingPathComponent(RendererPackageValidationLimits.stagingDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let staging = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)

        do {
            var accounting = Accounting()
            try copyDirectory(source, to: staging, device: try fileStatus(source.path).st_dev, accounting: &accounting)
            let validated = try validateStagedDirectory(staging, expectedHash: expectedHash)
            return validated
        } catch {
            do { try removeOrDiagnose(staging) } catch { throw error }
            throw error
        }
    }

    private func validateStagedDirectory(_ root: URL, expectedHash: RendererSHA256Digest?) throws -> ValidatedRendererPackage {
        try ensureDirectory(root, label: root.path)
        var files: [RendererRelativePath: URL] = [:]
        var seenCaseFolded: Set<String> = []
        var accounting = Accounting()
        try enumerateStaged(root: root, current: root, device: try fileStatus(root.path).st_dev, files: &files, seenCaseFolded: &seenCaseFolded, accounting: &accounting)
        let manifestURL = root.appendingPathComponent(RendererPackageValidationLimits.manifestFileName)
        let manifestPath = try RendererRelativePath(validating: RendererPackageValidationLimits.manifestFileName)
        let manifestStatus = try fileStatus(manifestURL.path)
        guard isRegular(manifestStatus), manifestStatus.st_nlink == 1 else {
            throw RendererPackageValidationError.missingManifest
        }
        let manifestData: Data
        do { manifestData = try Data(contentsOf: manifestURL) }
        catch { throw RendererPackageValidationError.missingManifest }
        files.removeValue(forKey: manifestPath)
        let manifest: RendererManifest
        do { manifest = try JSONDecoder().decode(RendererManifest.self, from: manifestData) }
        catch { throw RendererPackageValidationError.malformedManifest }
        guard manifest.descriptors.allSatisfy({ $0.sizeLimits.maximumDecodedByteCount <= RendererPackageValidationLimits.maximumDecodedInputByteCount }) else {
            throw RendererPackageValidationError.decodedInputLimitExceeded
        }
        let declared = Dictionary(uniqueKeysWithValues: manifest.assets.map { ($0.path, $0) })
        for (path, url) in files {
            guard let asset = declared[path] else { throw RendererPackageValidationError.undeclaredFile(path.rawValue) }
            let digest = RendererSHA256.digest(try Data(contentsOf: url, options: [.mappedIfSafe]))
            guard digest == asset.digest else { throw RendererPackageValidationError.assetHashMismatch(path.rawValue) }
        }
        for path in declared.keys where files[path] == nil { throw RendererPackageValidationError.missingDeclaredAsset(path.rawValue) }
        let hash = try manifest.packageHash()
        if let expectedHash, hash != expectedHash { throw RendererPackageValidationError.packageHashMismatch }
        return ValidatedRendererPackage(manifest: manifest, packageHash: hash, stagedRoot: root)
    }

    private func enumerateStaged(root: URL, current: URL, device: dev_t, files: inout [RendererRelativePath: URL], seenCaseFolded: inout Set<String>, accounting: inout Accounting) throws {
        try ensureDirectory(current, label: current.path)
        for child in try fileManager.contentsOfDirectory(at: current, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            let rootComponents = root.standardizedFileURL.pathComponents
            let childComponents = child.standardizedFileURL.pathComponents
            guard childComponents.starts(with: rootComponents) else {
                throw RendererPackageValidationError.invalidPath(child.path)
            }
            let relative = childComponents.dropFirst(rootComponents.count).joined(separator: "/")
            let path = try RendererRelativePath(validating: relative)
            let folded = path.rawValue.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seenCaseFolded.insert(folded).inserted else { throw RendererPackageValidationError.invalidPath(path.rawValue) }
            let stat = try fileStatus(child.path)
            guard stat.st_dev == device else { throw RendererPackageValidationError.invalidPath(path.rawValue) }
            if isDirectory(stat) {
                try enumerateStaged(root: root, current: child, device: device, files: &files, seenCaseFolded: &seenCaseFolded, accounting: &accounting)
            } else if isRegular(stat) {
                guard stat.st_nlink == 1 else { throw RendererPackageValidationError.forbiddenFileType(path.rawValue) }
                accounting.fileCount += 1
                accounting.byteCount += Int(stat.st_size)
                guard accounting.fileCount <= RendererPackageValidationLimits.maximumFileCount else { throw RendererPackageValidationError.fileCountLimitExceeded }
                guard accounting.byteCount <= RendererPackageValidationLimits.maximumCopiedByteCount else { throw RendererPackageValidationError.copiedByteLimitExceeded }
                files[path] = child
            } else { throw RendererPackageValidationError.forbiddenFileType(path.rawValue) }
        }
    }

    private func copyDirectory(_ source: URL, to destination: URL, device: dev_t, accounting: inout Accounting) throws {
        try ensureDirectory(source, label: source.path)
        for child in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            let before = try fileStatus(child.path)
            guard before.st_dev == device else { throw RendererPackageValidationError.invalidPath(child.path) }
            let target = destination.appendingPathComponent(child.lastPathComponent, isDirectory: isDirectory(before))
            if isDirectory(before) {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: false)
                try copyDirectory(child, to: target, device: device, accounting: &accounting)
            } else if isRegular(before) {
                guard before.st_nlink == 1 else { throw RendererPackageValidationError.forbiddenFileType(child.path) }
                accounting.fileCount += 1
                accounting.byteCount += Int(before.st_size)
                guard accounting.fileCount <= RendererPackageValidationLimits.maximumFileCount else { throw RendererPackageValidationError.fileCountLimitExceeded }
                guard accounting.byteCount <= RendererPackageValidationLimits.maximumCopiedByteCount else { throw RendererPackageValidationError.copiedByteLimitExceeded }
                try copyRegularFile(source: child.path, destination: target.path, expected: before)
            } else { throw RendererPackageValidationError.forbiddenFileType(child.path) }
        }
    }

    private func copyRegularFile(source: String, destination: String, expected: stat) throws {
        let descriptor = open(source, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw RendererPackageValidationError.sourceChanged(source) }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, sameIdentity(expected, opened), isRegular(opened), opened.st_nlink == 1 else {
            throw RendererPackageValidationError.sourceChanged(source)
        }
        let output = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard output >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(output) }
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { bytes in
                    guard let baseAddress = bytes.baseAddress else { return -1 }
                    return write(output, baseAddress.advanced(by: offset), count - offset)
                }
                guard written > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += written
            }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, sameIdentity(opened, after), sameMetadata(expected, after) else {
            throw RendererPackageValidationError.sourceChanged(source)
        }
    }

    private func ensureDirectory(_ url: URL, label: String) throws {
        let status = try fileStatus(url.path)
        guard isDirectory(status), status.st_nlink >= 1 else { throw RendererPackageValidationError.sourceIsNotDirectory }
    }

    private func removeOrDiagnose(_ url: URL) throws {
        do { try fileManager.removeItem(at: url) }
        catch { diagnose("Renderer package cleanup failed for \(url.lastPathComponent): \(error)"); throw RendererPackageValidationError.cleanupFailed(url.lastPathComponent) }
    }
}

private struct Accounting { var fileCount = 0; var byteCount = 0 }

private func fileStatus(_ path: String) throws -> stat {
    var result = stat()
    guard lstat(path, &result) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT) }
    return result
}

private func isDirectory(_ value: stat) -> Bool { (value.st_mode & S_IFMT) == S_IFDIR }
private func isRegular(_ value: stat) -> Bool { (value.st_mode & S_IFMT) == S_IFREG }
private func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool { lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino }
private func sameMetadata(_ lhs: stat, _ rhs: stat) -> Bool {
    sameIdentity(lhs, rhs)
        && lhs.st_size == rhs.st_size
        && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
        && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
        && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
        && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
}
