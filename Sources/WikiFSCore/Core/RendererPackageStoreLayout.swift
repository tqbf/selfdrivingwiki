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
    public var lockURL: URL { root.appendingPathComponent(Names.lockFile, isDirectory: false) }
    public var journalURL: URL { root.appendingPathComponent(Names.journalFile, isDirectory: false) }

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
        static let lockFile = "store.lock"
        static let journalFile = "machine.sqlite"
    }
}

/// Returns whether a path remains within `root` after standardization and resolving
/// existing symlinks. Equality is accepted so callers may validate the root itself.
public func isRendererPackageStorePathContained(_ candidate: URL, within root: URL) -> Bool {
    guard candidate.isFileURL, root.isFileURL else { return false }
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
}

public protocol RendererPackageFileSystem: Sendable {
    func lstat(at url: URL) throws -> RendererPackageFileIdentity
    func openReadOnlyNoFollow(at url: URL) throws -> Int32
    func close(fileDescriptor: Int32) throws
}

// pattern: Imperative Shell

/// POSIX filesystem boundary for package-store runtime files. It intentionally
/// avoids `FileManager` inspection APIs, which follow symlinks before exposing facts.
public struct RealRendererPackageFileSystem: RendererPackageFileSystem, Sendable {
    public init() {}

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
}

private func rendererPackageStoreClose(_ fileDescriptor: Int32) -> Int32 {
    #if canImport(Darwin)
    return Darwin.close(fileDescriptor)
    #elseif canImport(Glibc)
    return Glibc.close(fileDescriptor)
    #endif
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
