import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif
import WikiFSCore
import WikiFSTypes

// Reviewed-only operation support. The signed `podcast-token-helper` Mach-O
// cannot live inside the immutable package snapshot (code signing rewrites
// Mach-O bytes, which would break the digest contract), so the host stages it
// into the private operation root for exact reviewed revisions only. The
// package receives a RELATIVE path inside its own operation root through the
// operation-configuration file — never an absolute path, never a manifest
// capability, never an environment override it could read generically.

/// The stable role of one host-staged operation-support executable. The role
/// names WHY the executable exists; it is never a policy key — admission is
/// exact-revision only.
public enum ExtractorOperationSupportRole: String, Codable, Hashable, Sendable {
    case podcastTokenHelper = "podcast-token-helper"
}

/// One bounded executable grant for ONE exact package revision: copy this
/// host file into the operation's private support directory under this name,
/// verifying it still hashes to this identity while copying. The expected
/// identity is host configuration — it never comes from package data.
public struct ExtractorOperationSupportGrant: Hashable, Sendable {
    public let role: ExtractorOperationSupportRole
    /// The trusted host-side source executable.
    public let sourceURL: URL
    /// The destination FILE NAME inside the request's support directory.
    /// A single validated path component; no nesting.
    public let destinationFileName: ExtractorRelativePath
    /// The approved SHA-256 digest (lowercase hex) of the source bytes.
    public let expectedSHA256: String
    /// The approved source byte count.
    public let expectedByteCount: Int

    public init?(
        role: ExtractorOperationSupportRole,
        sourceURL: URL,
        destinationFileName: String,
        expectedSHA256: String,
        expectedByteCount: Int
    ) {
        guard let destination = ExtractorRelativePath(rawValue: destinationFileName),
              destination.rawValue.contains("/") == false else {
            return nil
        }
        self.role = role
        self.sourceURL = sourceURL
        self.destinationFileName = destination
        self.expectedSHA256 = expectedSHA256
        self.expectedByteCount = expectedByteCount
    }
}

/// The host-side operation-support authority. Returns no support, or one
/// bounded executable grant. Implementations admit by EXACT package revision
/// only — never by kind, MIME type, capability, credential, or any
/// package-controlled string.
public protocol ExtractorOperationSupportProviding: Sendable {
    func operationSupport(for revision: ExtractorPackageRevisionID) -> ExtractorOperationSupportGrant?
}

public enum ExtractorOperationSupportError: Error, Equatable, Sendable {
    case sourceUnavailable
    case sourceNotRegularFile
    case sourceIsHardLink
    case sourceIdentityChanged
    case sourceHashMismatch
    case destinationExists
    case containmentFailed
    case stagingFailed
    case stagedIdentityChanged
}

/// One staged executable: its RELATIVE path inside the operation root (what
/// the operation-configuration file carries), the support directory the
/// host removes on every terminal path, and the pinned identity of the
/// published inode for the pre-launch re-verification.
public struct StagedExtractorOperationSupport: Sendable {
    public let relativePath: ExtractorRelativePath
    public let supportDirectoryURL: URL
    public let publishedIdentity: StagedExecutableIdentity
}

/// The pinned on-disk identity of one staged executable.
public struct StagedExecutableIdentity: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let size: Int
}

/// Stages a grant into `<operationRoot>/support/<request>/` with a
/// race-resistant copy: open the source WITHOUT following links, inspect the
/// open descriptor, copy from that descriptor while hashing, verify size and
/// hash, fsync + close, set mode 0500, publish with an exclusive rename, then
/// reopen and re-verify the staged inode. Every step fails closed.
public enum ExtractorOperationSupportStager {

    /// Stages the grant's executable for one request. `requestName` is the
    /// request-scoped directory name already used by the credential and
    /// configuration subdirectories.
    public static func stage(
        grant: ExtractorOperationSupportGrant,
        operationRoot: URL,
        requestName: String
    ) throws -> StagedExtractorOperationSupport {
        // Containment: the support directory is built from validated parts
        // inside the operation root.
        let supportDirectory = operationRoot
            .appendingPathComponent("support", isDirectory: true)
            .appendingPathComponent(requestName, isDirectory: true)
        let destinationURL = supportDirectory
            .appendingPathComponent(grant.destinationFileName.rawValue, isDirectory: false)
        guard isContained(destinationURL, in: operationRoot) else {
            throw ExtractorOperationSupportError.containmentFailed
        }
        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        // Cleanup contract: a throw from THIS function leaves no support
        // directory and no partial destination behind — the caller has not
        // yet recorded the directory, so the stager owns failure cleanup.
        do {
            return try stageVerified(
                grant: grant, requestName: requestName,
                supportDirectory: supportDirectory, destinationURL: destinationURL)
        } catch {
            // Best-effort failure cleanup: the directory is being discarded,
            // and a removal error here must not mask the staging error.
            // swiftlint:disable:next silent_try_optional
            try? FileManager.default.removeItem(at: destinationURL)
            // swiftlint:disable:next silent_try_optional
            try? FileManager.default.removeItem(at: supportDirectory)
            throw error
        }
    }

    private static func stageVerified(
        grant: ExtractorOperationSupportGrant,
        requestName: String,
        supportDirectory: URL,
        destinationURL: URL
    ) throws -> StagedExtractorOperationSupport {

        // Open the source WITHOUT following a final symlink and inspect the
        // OPEN descriptor: regular file, owner UID, single link (no hard
        // links), approved size.
        let sourceFD = grant.sourceURL.path.withCString {
            open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard sourceFD >= 0 else { throw ExtractorOperationSupportError.sourceUnavailable }
        defer { close(sourceFD) }
        var sourceStatus = stat()
        guard fstat(sourceFD, &sourceStatus) == 0 else {
            throw ExtractorOperationSupportError.sourceUnavailable
        }
        guard sourceStatus.st_mode & S_IFMT == S_IFREG else {
            throw ExtractorOperationSupportError.sourceNotRegularFile
        }
        guard sourceStatus.st_nlink == 1 else {
            throw ExtractorOperationSupportError.sourceIsHardLink
        }
        guard sourceStatus.st_uid == getuid() else {
            throw ExtractorOperationSupportError.sourceIdentityChanged
        }
        guard Int(sourceStatus.st_size) == grant.expectedByteCount else {
            throw ExtractorOperationSupportError.sourceIdentityChanged
        }

        // Exclusively created owner-only temporary file in the SAME
        // directory, so the publish link stays on one filesystem.
        let temporaryName = "\(grant.destinationFileName.rawValue).tmp-\(UUID().uuidString.lowercased())"
        let temporaryURL = supportDirectory.appendingPathComponent(temporaryName)
        guard isContained(temporaryURL, in: supportDirectory) else {
            throw ExtractorOperationSupportError.containmentFailed
        }
        let temporaryFD = temporaryURL.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        }
        guard temporaryFD >= 0 else { throw ExtractorOperationSupportError.stagingFailed }

        var hasher = Hasher256()
        var copied = 0
        var copyFailed = false
        while copied < grant.expectedByteCount {
            let chunkSize = 65_536
            var buffer = [UInt8](repeating: 0, count: chunkSize)
            let readBytes = buffer.withUnsafeMutableBytes { raw in
                read(sourceFD, raw.baseAddress, chunkSize)
            }
            if readBytes <= 0 { copyFailed = true; break }
            let chunk = readBytes
            hasher.update(bytes: buffer[0..<chunk])
            let written = buffer.withUnsafeBytes { raw in
                write(temporaryFD, raw.baseAddress, chunk)
            }
            if written != chunk { copyFailed = true; break }
            copied += chunk
        }
        // Flush before verification and publication.
        if copyFailed == false, fsync(temporaryFD) != 0 { copyFailed = true }
        close(temporaryFD)
        guard copyFailed == false,
              copied == grant.expectedByteCount,
              hasher.finalHex() == grant.expectedSHA256.lowercased() else {
            removeTemporaryBestEffort(temporaryURL)
            throw copied == grant.expectedByteCount
                ? ExtractorOperationSupportError.sourceHashMismatch
                : ExtractorOperationSupportError.sourceIdentityChanged
        }

        // Owner-executable only, then atomic EXCLUSIVE publication.
        // POSIX rename(2) silently REPLACES an existing destination on
        // macOS, so a planted file must be refused by link(2), which fails
        // with EEXIST when the destination exists. The staged inode briefly
        // carries two links (temporary + destination) until the temporary
        // name is unlinked.
        guard chmod(temporaryURL.path, 0o500) == 0 else {
            removeTemporaryBestEffort(temporaryURL)
            throw ExtractorOperationSupportError.stagingFailed
        }
        var publishedStatus = stat()
        guard lstat(temporaryURL.path, &publishedStatus) == 0 else {
            removeTemporaryBestEffort(temporaryURL)
            throw ExtractorOperationSupportError.stagingFailed
        }
        let linkResult = temporaryURL.path.withCString { tempPath in
            destinationURL.path.withCString { destPath in
                link(tempPath, destPath)
            }
        }
        guard linkResult == 0 else {
            removeTemporaryBestEffort(temporaryURL)
            // EEXIST (a planted or double-staged destination) and any other
            // failure both fail closed; the destination is never overwritten.
            throw ExtractorOperationSupportError.destinationExists
        }
        removeTemporaryBestEffort(temporaryURL)

        // Reopen the published file WITHOUT following links and verify the
        // staged identity: the same inode we wrote, regular, owner, single
        // link, mode 0500, approved size.
        let verifyFD = destinationURL.path.withCString {
            open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard verifyFD >= 0 else {
            throw ExtractorOperationSupportError.stagedIdentityChanged
        }
        defer { close(verifyFD) }
        var verifyStatus = stat()
        guard fstat(verifyFD, &verifyStatus) == 0 else {
            throw ExtractorOperationSupportError.stagedIdentityChanged
        }
        guard verifyStatus.st_dev == publishedStatus.st_dev,
              verifyStatus.st_ino == publishedStatus.st_ino,
              verifyStatus.st_mode & S_IFMT == S_IFREG,
              verifyStatus.st_uid == getuid(),
              verifyStatus.st_nlink == 1,
              verifyStatus.st_mode & 0o777 == 0o500,
              Int(verifyStatus.st_size) == grant.expectedByteCount else {
            throw ExtractorOperationSupportError.stagedIdentityChanged
        }

        let relativePath = try ExtractorRelativePath(
            validating: "support/\(requestName)/\(grant.destinationFileName.rawValue)")
        return StagedExtractorOperationSupport(
            relativePath: relativePath,
            supportDirectoryURL: supportDirectory,
            publishedIdentity: StagedExecutableIdentity(
                device: UInt64(verifyStatus.st_dev),
                inode: UInt64(verifyStatus.st_ino),
                mode: UInt32(verifyStatus.st_mode),
                size: Int(verifyStatus.st_size)))
    }

    /// Re-verifies the staged executable's pinned identity against the open
    /// descriptor semantics used at staging: regular file, owner, single
    /// link, mode 0500, approved size, and the SAME device+inode. Called as
    /// the last action before spawn, after the launch gate.
    public static func verifyPublishedIdentity(
        _ identity: StagedExecutableIdentity,
        at stagedPath: ExtractorRelativePath,
        operationRoot: URL
    ) throws {
        let url = operationRoot.appendingPathComponent(stagedPath.rawValue)
        guard isContained(url, in: operationRoot) else {
            throw ExtractorOperationSupportError.containmentFailed
        }
        let fd = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw ExtractorOperationSupportError.stagedIdentityChanged }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0 else {
            throw ExtractorOperationSupportError.stagedIdentityChanged
        }
        guard UInt64(status.st_dev) == identity.device,
              UInt64(status.st_ino) == identity.inode,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              status.st_nlink == 1,
              status.st_mode & 0o777 == 0o500,
              Int(status.st_size) == identity.size else {
            throw ExtractorOperationSupportError.stagedIdentityChanged
        }
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    /// Best-effort removal of an unpublished temporary file. The typed error
    /// thrown by the caller is the report; a removal error here must not
    /// mask it, and the caller's failure cleanup discards the directory.
    private static func removeTemporaryBestEffort(_ url: URL) {
        // swiftlint:disable:next silent_try_optional
        try? FileManager.default.removeItem(at: url)
    }
}

/// Incremental SHA-256 over the copy loop (CryptoKit on Darwin, swift-crypto
/// on Linux). ExtractorSHA256 digests one Data value; the copy needs update
/// semantics.
struct Hasher256 {
    #if canImport(CryptoKit)
    private var hasher = SHA256()
    #elseif canImport(Crypto)
    private var hasher = SHA256()
    #else
    #error("Hasher256 requires CryptoKit or Crypto")
    #endif

    mutating func update(bytes: ArraySlice<UInt8>) {
        hasher.update(data: Data(bytes))
    }

    func finalHex() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
