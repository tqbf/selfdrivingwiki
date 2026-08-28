import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import WikiFSTypes

public protocol ExtractorPackageCatalogReading: Sendable {
    func read() throws -> ExtractorPackageCatalog
}

public enum ExtractorPackageStoreError: Error, Equatable, Sendable {
    case mutationForbidden
    case lockTimedOut
    case filesystemFailure
    case corruptCatalog
    case catalogTooLarge
    case staleGeneration
    case conflictingRevision
    case packageRootAlreadyExists
    case packageMissing
    case packageRemovalFailed
    case recoveryFailed
}

public struct ExtractorPackageCatalogReader: ExtractorPackageCatalogReading, Sendable {
    public static let maximumCatalogByteCount = 4 * 1_024 * 1_024

    private let layout: ExtractorPackageStoreLayout

    public init(layout: ExtractorPackageStoreLayout) {
        self.layout = layout
    }

    public func read() throws -> ExtractorPackageCatalog {
        let descriptor = try openExistingDerivedDirectory()
        guard let descriptor else { return try ExtractorPackageCatalog() }
        defer { close(descriptor) }
        return try Self.readCatalog(directoryFD: descriptor)
    }

    public static func readCatalog(directoryFD: Int32) throws -> ExtractorPackageCatalog {
        let opened = "index.json".withCString { pointer -> (descriptor: Int32, error: Int32) in
            let descriptor = openat(directoryFD, pointer, O_RDONLY | O_NOFOLLOW)
            return (descriptor, errno)
        }
        guard opened.descriptor >= 0 else {
            if opened.error == ENOENT { return try ExtractorPackageCatalog() }
            throw ExtractorPackageStoreError.filesystemFailure
        }
        defer { close(opened.descriptor) }
        let before = try extractorCatalogFileStatus(opened.descriptor)
        guard before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1,
              before.st_size >= 0,
              before.st_size <= Self.maximumCatalogByteCount else {
            throw before.st_size > Self.maximumCatalogByteCount
                ? ExtractorPackageStoreError.catalogTooLarge
                : ExtractorPackageStoreError.corruptCatalog
        }
        let data = try readExtractorCatalogData(
            opened.descriptor,
            maximum: Self.maximumCatalogByteCount)
        let after = try extractorCatalogFileStatus(opened.descriptor)
        guard extractorCatalogMetadataMatches(before, after) else {
            throw ExtractorPackageStoreError.corruptCatalog
        }
        do {
            return try JSONDecoder().decode(ExtractorPackageCatalog.self, from: data)
        } catch let error as ExtractorPackageCatalogError {
            throw error
        } catch {
            throw ExtractorPackageStoreError.corruptCatalog
        }
    }

    private func openExistingDerivedDirectory() throws -> Int32? {
        guard layout.appGroupContainerRoot.isFileURL else {
            throw ExtractorPackageStoreError.filesystemFailure
        }
        let root = layout.appGroupContainerRoot.path.withCString {
            pointer -> (descriptor: Int32, error: Int32) in
            let descriptor = open(pointer, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            return (descriptor, errno)
        }
        guard root.descriptor >= 0 else {
            if root.error == ENOENT { return nil }
            throw ExtractorPackageStoreError.filesystemFailure
        }
        defer { close(root.descriptor) }
        var current = dup(root.descriptor)
        guard current >= 0 else { throw ExtractorPackageStoreError.filesystemFailure }
        for component in ["extractors", "v1", "derived"] {
            let next = component.withCString {
                pointer -> (descriptor: Int32, error: Int32) in
                let descriptor = openat(current, pointer, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                return (descriptor, errno)
            }
            close(current)
            guard next.descriptor >= 0 else {
                if next.error == ENOENT { return nil }
                throw ExtractorPackageStoreError.filesystemFailure
            }
            current = next.descriptor
        }
        return current
    }
}

public actor ExtractorPackageStoreCoordinator {
    private static let retryDelay: Duration = .milliseconds(25)
    private static let acquisitionTimeout: Duration = .seconds(5)
    private static let processGate = ExtractorPackageStoreProcessGate()

    private let layout: ExtractorPackageStoreLayout

    public init(layout: ExtractorPackageStoreLayout) {
        self.layout = layout
    }

    public func withExclusiveAccess<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        let key = layout.root.standardizedFileURL.path
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.acquisitionTimeout)
        while true {
            try Task.checkCancellation()
            guard await Self.processGate.tryAcquire(key) else {
                guard clock.now < deadline else { throw ExtractorPackageStoreError.lockTimedOut }
                try await Task.sleep(for: Self.retryDelay)
                continue
            }
            let descriptor: Int32
            do {
                descriptor = try openAndLock()
            } catch ExtractorPackageStoreLockContention.contended {
                await Self.processGate.release(key)
                guard clock.now < deadline else { throw ExtractorPackageStoreError.lockTimedOut }
                try await Task.sleep(for: Self.retryDelay)
                continue
            } catch {
                await Self.processGate.release(key)
                throw error
            }
            do {
                let value = try await operation()
                await release(descriptor, key: key)
                return value
            } catch {
                await release(descriptor, key: key)
                throw error
            }
        }
    }

    private func openAndLock() throws -> Int32 {
        let descriptor = try ExtractorDirectoryValidator.openStoreAuthority(layout)
        do {
            let status = try extractorCatalogFileStatus(descriptor)
            guard status.st_mode & S_IFMT == S_IFDIR,
                  status.st_uid == getuid() else {
                throw ExtractorPackageStoreError.filesystemFailure
            }
            guard extractorCatalogFlock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                close(descriptor)
                if code == EWOULDBLOCK || code == EAGAIN {
                    throw ExtractorPackageStoreLockContention.contended
                }
                throw ExtractorPackageStoreError.filesystemFailure
            }
            let roots = try ExtractorDirectoryValidator.prepareStoreRoots(layout)
            close(roots.root); close(roots.packages); close(roots.staging)
            close(roots.derived); close(roots.operations)
            return descriptor
        } catch {
            if fcntl(descriptor, F_GETFD) != -1 { close(descriptor) }
            throw error
        }
    }

    private func release(_ descriptor: Int32, key: String) async {
        if extractorCatalogFlock(descriptor, LOCK_UN) != 0 {
            DebugLog.extraction("Extractor catalog lock release failed")
        }
        if close(descriptor) != 0 {
            DebugLog.extraction("Extractor catalog lock descriptor close failed")
        }
        await Self.processGate.release(key)
    }
}

private actor ExtractorPackageStoreProcessGate {
    private var heldKeys: Set<String> = []
    func tryAcquire(_ key: String) -> Bool { heldKeys.insert(key).inserted }
    func release(_ key: String) { heldKeys.remove(key) }
}

private enum ExtractorPackageStoreLockContention: Error { case contended }

private func extractorCatalogFileStatus(_ descriptor: Int32) throws -> stat {
    var result = stat()
    guard fstat(descriptor, &result) == 0 else {
        throw ExtractorPackageStoreError.filesystemFailure
    }
    return result
}

private func readExtractorCatalogData(_ descriptor: Int32, maximum: Int) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, maximum))
    while data.count < maximum {
        let remaining = min(buffer.count, maximum - data.count)
        let count = read(descriptor, &buffer, remaining)
        guard count >= 0 else { throw ExtractorPackageStoreError.filesystemFailure }
        if count == 0 { return data }
        data.append(contentsOf: buffer[0 ..< count])
    }
    var extra: UInt8 = 0
    if read(descriptor, &extra, 1) > 0 { throw ExtractorPackageStoreError.catalogTooLarge }
    return data
}

private func extractorCatalogMetadataMatches(_ lhs: stat, _ rhs: stat) -> Bool {
    #if canImport(Darwin)
    return lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino &&
        lhs.st_size == rhs.st_size && lhs.st_mode == rhs.st_mode &&
        lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
        lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
        lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec &&
        lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    #else
    return lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino &&
        lhs.st_size == rhs.st_size && lhs.st_mode == rhs.st_mode &&
        lhs.st_mtim.tv_sec == rhs.st_mtim.tv_sec &&
        lhs.st_mtim.tv_nsec == rhs.st_mtim.tv_nsec &&
        lhs.st_ctim.tv_sec == rhs.st_ctim.tv_sec &&
        lhs.st_ctim.tv_nsec == rhs.st_ctim.tv_nsec
    #endif
}

@_silgen_name("flock")
private func extractorCatalogNativeFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

private func extractorCatalogFlock(_ descriptor: Int32, _ operation: Int32) -> Int32 {
    extractorCatalogNativeFlock(descriptor, operation)
}
