import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// pattern: Functional Core

/// A validated identifier for one short-lived package installation staging area.
///
/// The identifier is a single path component; package installation code supplies
/// its own collision-resistant value in a later slice.
public struct RendererPackageStagingID: RawRepresentable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.isEmpty == false,
              rawValue.count <= Self.maximumLength,
              rawValue.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        self.rawValue = rawValue
    }

    public init(validating rawValue: String) throws {
        guard let value = Self(rawValue: rawValue) else {
            throw RendererPackageStoreError.invalidStagingID(rawValue)
        }
        self = value
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    private static let maximumLength = 128
}

/// Immutable names and paths for the machine-scoped renderer package store.
///
/// The injected root is the App Group container, not a wiki database directory.
/// Payloads and later SQLite records both remain beneath this machine-only root.
public struct RendererPackageStoreLayout: Sendable {
    public let appGroupContainerRoot: URL

    public init(appGroupContainerRoot: URL) throws {
        guard appGroupContainerRoot.isFileURL else {
            throw RendererPackageStoreError.nonFileURL(appGroupContainerRoot)
        }
        self.appGroupContainerRoot = appGroupContainerRoot.standardizedFileURL
    }

    /// Resolves the production App Group container through the existing canonical resolver.
    public static func production() throws -> Self {
        try Self(appGroupContainerRoot: DatabaseLocation.appGroupContainerDirectory())
    }

    public var root: URL { appGroupContainerRoot.appendingPathComponent(Names.renderers, isDirectory: true).appendingPathComponent(Names.layoutVersion, isDirectory: true) }
    public var packagesRoot: URL { root.appendingPathComponent(Names.packages, isDirectory: true) }
    public var stagingRoot: URL { root.appendingPathComponent(Names.staging, isDirectory: true) }
    public var derivedRoot: URL { root.appendingPathComponent(Names.derived, isDirectory: true) }
    public var derivedIndexURL: URL { derivedRoot.appendingPathComponent(Names.indexFile, isDirectory: false) }
    /// SQLite is the authoritative A3 machine index. The JSON index is a
    /// derived, replaceable compatibility/projection artifact.
    public var indexDatabaseURL: URL { root.appendingPathComponent(Names.indexDatabaseFile, isDirectory: false) }
    public var lockURL: URL { root.appendingPathComponent(Names.lockFile, isDirectory: false) }
    public var journalURL: URL { root.appendingPathComponent(Names.journalFile, isDirectory: false) }

    func recoveryQuarantineURL(ownerToken: String) -> URL {
        root.appendingPathComponent(".store.lock.reclaim-\(ownerToken)", isDirectory: false)
    }

    public func packageURL(packageID: RendererPackageID, version: RendererPackageVersion) -> URL {
        packagesRoot
            .appendingPathComponent(packageID.rawValue, isDirectory: true)
            .appendingPathComponent(version.rawValue, isDirectory: true)
    }

    public func stagingURL(stagingID: RendererPackageStagingID) -> URL {
        stagingRoot.appendingPathComponent(stagingID.rawValue, isDirectory: true)
    }

    private enum Names {
        static let renderers = "renderers"
        static let layoutVersion = "v1"
        static let packages = "packages"
        static let staging = "staging"
        static let derived = "derived"
        static let indexFile = "index.json"
        static let indexDatabaseFile = "index.sqlite"
        static let lockFile = "store.lock"
        static let journalFile = "machine.sqlite"
    }
}

/// Returns whether a path remains within `root` after standardization and resolving
/// existing symlinks. Equality is accepted so callers may validate the root itself.
public func isRendererPackageStorePathContained(_ candidate: URL, within root: URL) -> Bool {
    guard candidate.isFileURL, root.isFileURL else { return false }
    // Preserve the security meaning of an explicit parent traversal. Standardizing
    // before this check would erase `..` and could turn it into an in-root path.
    guard candidate.pathComponents.contains("..") == false else { return false }
    let resolvedRoot = rendererPackageStoreCanonicalPath(root)
    let resolvedCandidate = rendererPackageStoreCanonicalPath(candidate)
    if resolvedCandidate == resolvedRoot { return true }
    let nestedPrefix = resolvedRoot == "/" ? "/" : resolvedRoot + "/"
    return resolvedCandidate.hasPrefix(nestedPrefix)
}

private func rendererPackageStoreCanonicalPath(_ url: URL) -> String {
    var unresolvedComponents: [String] = []
    var currentURL = url.standardizedFileURL
    while true {
        let standardizedPath = currentURL.path
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if standardizedPath.withCString({ realpath($0, &buffer) }) != nil {
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let resolved = URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true)
            return unresolvedComponents.reduce(into: resolved) { path, component in
                path.appendPathComponent(component, isDirectory: false)
            }.standardizedFileURL.path
        }
        guard currentURL.path != "/" else { return url.standardizedFileURL.path }
        unresolvedComponents.insert(currentURL.lastPathComponent, at: 0)
        currentURL.deleteLastPathComponent()
    }
}

public struct RendererPackageFileIdentity: Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let linkCount: UInt64
    public let size: UInt64
    public let mode: UInt32
    public let ownerUserID: UInt32
    public let ownerGroupID: UInt32
    public let modifiedAt: Date
    public let changedAt: Date

    fileprivate init(metadata: stat) {
        device = UInt64(metadata.st_dev)
        inode = UInt64(metadata.st_ino)
        linkCount = UInt64(metadata.st_nlink)
        size = UInt64(metadata.st_size)
        mode = UInt32(metadata.st_mode)
        ownerUserID = UInt32(metadata.st_uid)
        ownerGroupID = UInt32(metadata.st_gid)
        #if canImport(Darwin)
        modifiedAt = Date(timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec) + TimeInterval(metadata.st_mtimespec.tv_nsec) / 1_000_000_000)
        changedAt = Date(timeIntervalSince1970: TimeInterval(metadata.st_ctimespec.tv_sec) + TimeInterval(metadata.st_ctimespec.tv_nsec) / 1_000_000_000)
        #elseif canImport(Glibc)
        modifiedAt = Date(timeIntervalSince1970: TimeInterval(metadata.st_mtim.tv_sec) + TimeInterval(metadata.st_mtim.tv_nsec) / 1_000_000_000)
        changedAt = Date(timeIntervalSince1970: TimeInterval(metadata.st_ctim.tv_sec) + TimeInterval(metadata.st_ctim.tv_nsec) / 1_000_000_000)
        #endif
    }

    public func refersToSameObject(as other: Self) -> Bool {
        device == other.device && inode == other.inode
    }
}

public protocol RendererPackageFileSystem: Sendable {
    func ensureDirectory(at url: URL) throws
    func lstat(at url: URL) throws -> RendererPackageFileIdentity
    func openReadOnlyNoFollow(at url: URL) throws -> Int32
    func fileIdentity(fileDescriptor: Int32) throws -> RendererPackageFileIdentity
    func readAll(fileDescriptor: Int32, maximumBytes: Int) throws -> Data
    func createExclusiveFile(at url: URL, contents: Data) throws -> RendererPackageFileIdentity
    /// Opens the stable lock inode without following links. The caller retains
    /// the descriptor until it has released the kernel-held advisory lock.
    func openLockFileNoFollow(at url: URL) throws -> Int32
    func createExclusiveLockFile(at url: URL, contents: Data) throws -> Int32
    func lockExclusiveNonblocking(fileDescriptor: Int32) throws
    func unlock(fileDescriptor: Int32) throws
    func createHardLink(from source: URL, to destination: URL) throws
    func removeFile(at url: URL) throws
    func close(fileDescriptor: Int32) throws
}

// pattern: Imperative Shell

/// POSIX filesystem boundary for package-store runtime files. It intentionally
/// avoids `FileManager` inspection APIs, which follow symlinks before exposing facts.
public struct RealRendererPackageFileSystem: RendererPackageFileSystem, Sendable {
    public init() {}

    public func ensureDirectory(at url: URL) throws {
        try requireFileURL(url)
        let parent = url.deletingLastPathComponent()
        for directory in [parent, url] {
            let result = directory.path.withCString { mkdir($0, S_IRWXU) }
            if result != 0 && errno != EEXIST { throw posixError(operation: "mkdir", path: directory.path) }
            let identity = try lstat(at: directory)
            guard (identity.mode & UInt32(S_IFMT)) == UInt32(S_IFDIR) else {
                throw RendererPackageStoreError.posix(operation: "mkdir", path: directory.path, code: ENOTDIR)
            }
        }
    }

    public func lstat(at url: URL) throws -> RendererPackageFileIdentity {
        try requireFileURL(url)
        var metadata = stat()
        let result = url.path.withCString { rendererPackageStoreLstat($0, &metadata) }
        guard result == 0 else { throw posixError(operation: "lstat", path: url.path) }
        return RendererPackageFileIdentity(metadata: metadata)
    }

    public func openReadOnlyNoFollow(at url: URL) throws -> Int32 {
        try requireFileURL(url)
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw posixError(operation: "open", path: url.path) }
        return descriptor
    }

    public func fileIdentity(fileDescriptor: Int32) throws -> RendererPackageFileIdentity {
        var metadata = stat()
        guard fstat(fileDescriptor, &metadata) == 0 else {
            throw RendererPackageStoreError.posix(operation: "fstat", path: nil, code: errno)
        }
        return RendererPackageFileIdentity(metadata: metadata)
    }

    public func readAll(fileDescriptor: Int32, maximumBytes: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(maximumBytes, 4096))
        while data.count < maximumBytes {
            let remaining = min(buffer.count, maximumBytes - data.count)
            let count = buffer.withUnsafeMutableBytes { read(fileDescriptor, $0.baseAddress, remaining) }
            guard count >= 0 else { throw RendererPackageStoreError.posix(operation: "read", path: nil, code: errno) }
            guard count > 0 else { return data }
            data.append(contentsOf: buffer.prefix(Int(count)))
        }
        var extra: UInt8 = 0
        if read(fileDescriptor, &extra, 1) > 0 {
            throw RendererPackageStoreError.posix(operation: "read", path: nil, code: EOVERFLOW)
        }
        return data
    }

    public func createExclusiveFile(at url: URL, contents: Data) throws -> RendererPackageFileIdentity {
        try requireFileURL(url)
        let descriptor = url.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR) }
        guard descriptor >= 0 else { throw posixError(operation: "openExclusive", path: url.path) }
        do {
            try writeAll(contents, fileDescriptor: descriptor)
            guard fsync(descriptor) == 0 else { throw RendererPackageStoreError.posix(operation: "fsync", path: nil, code: errno) }
            try close(fileDescriptor: descriptor)
            return try lstat(at: url)
        } catch {
            do { try close(fileDescriptor: descriptor) } catch { DebugLog.store("Renderer coordinator lock descriptor close failed.") }
            throw error
        }
    }

    public func openLockFileNoFollow(at url: URL) throws -> Int32 {
        try requireFileURL(url)
        let descriptor = url.path.withCString { open($0, O_RDWR | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw posixError(operation: "openLock", path: url.path) }
        do {
            let identity = try fileIdentity(fileDescriptor: descriptor)
            guard (identity.mode & UInt32(S_IFMT)) == UInt32(S_IFREG) else {
                throw RendererPackageStoreError.posix(operation: "openLock", path: url.path, code: EINVAL)
            }
            return descriptor
        } catch {
            do { try close(fileDescriptor: descriptor) } catch { DebugLog.store("Renderer coordinator lock descriptor close failed.") }
            throw error
        }
    }

    public func createExclusiveLockFile(at url: URL, contents: Data) throws -> Int32 {
        try requireFileURL(url)
        let descriptor = url.path.withCString { open($0, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR) }
        guard descriptor >= 0 else { throw posixError(operation: "openExclusiveLock", path: url.path) }
        do {
            try writeAll(contents, fileDescriptor: descriptor)
            guard fsync(descriptor) == 0 else { throw RendererPackageStoreError.posix(operation: "fsync", path: nil, code: errno) }
            return descriptor
        } catch {
            do { try close(fileDescriptor: descriptor) } catch { DebugLog.store("Renderer coordinator lock descriptor close failed.") }
            throw error
        }
    }

    public func lockExclusiveNonblocking(fileDescriptor: Int32) throws {
        guard rendererPackageStoreFlock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw RendererPackageStoreError.posix(operation: "flock", path: nil, code: errno)
        }
    }

    public func unlock(fileDescriptor: Int32) throws {
        guard rendererPackageStoreFlock(fileDescriptor, LOCK_UN) == 0 else {
            throw RendererPackageStoreError.posix(operation: "flock", path: nil, code: errno)
        }
    }

    public func createHardLink(from source: URL, to destination: URL) throws {
        try requireFileURL(source)
        try requireFileURL(destination)
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                link(sourcePath, destinationPath)
            }
        }
        guard result == 0 else { throw posixError(operation: "link", path: destination.path) }
    }

    public func removeFile(at url: URL) throws {
        try requireFileURL(url)
        guard url.path.withCString({ unlink($0) }) == 0 else { throw posixError(operation: "unlink", path: url.path) }
    }

    public func close(fileDescriptor: Int32) throws {
        guard rendererPackageStoreClose(fileDescriptor) == 0 else {
            throw RendererPackageStoreError.posix(operation: "close", path: nil, code: errno)
        }
    }

    private func requireFileURL(_ url: URL) throws {
        guard url.isFileURL else { throw RendererPackageStoreError.nonFileURL(url) }
    }

    private func posixError(operation: String, path: String) -> RendererPackageStoreError {
        RendererPackageStoreError.posix(operation: operation, path: path, code: errno)
    }

    private func writeAll(_ data: Data, fileDescriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = write(fileDescriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw RendererPackageStoreError.posix(operation: "write", path: nil, code: errno) }
                offset += Int(count)
            }
        }
    }
}

private func rendererPackageStoreClose(_ fileDescriptor: Int32) -> Int32 {
    #if canImport(Darwin)
    return Darwin.close(fileDescriptor)
    #elseif canImport(Glibc)
    return Glibc.close(fileDescriptor)
    #endif
}

/// `flock` is a type name in Swift's Darwin/Glibc overlays, so bind the POSIX
/// function symbol explicitly rather than accidentally calling `fcntl` record
/// locking with incompatible ownership semantics.
@_silgen_name("flock")
private func rendererPackageStoreNativeFlock(_ fileDescriptor: Int32, _ operation: Int32) -> Int32

private func rendererPackageStoreFlock(_ fileDescriptor: Int32, _ operation: Int32) -> Int32 {
    rendererPackageStoreNativeFlock(fileDescriptor, operation)
}

private func rendererPackageStoreLstat(_ path: UnsafePointer<CChar>, _ metadata: UnsafeMutablePointer<stat>) -> Int32 {
    #if canImport(Darwin)
    return Darwin.lstat(path, metadata)
    #elseif canImport(Glibc)
    return Glibc.lstat(path, metadata)
    #endif
}

public enum RendererPackageStoreError: Error, Equatable, Sendable {
    case invalidStagingID(String)
    case nonFileURL(URL)
    case pathEscapesStore(candidate: URL, root: URL)
    case posix(operation: String, path: String?, code: Int32)
}
