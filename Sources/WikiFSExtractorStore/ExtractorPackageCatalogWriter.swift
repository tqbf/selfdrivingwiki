import CRendererPackageMove
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import WikiFSCore
import WikiFSTypes

public protocol ExtractorPackagePayloadRemoving: Sendable {
    func removePackage(named name: String, from parentFD: Int32) throws
}

public struct FileExtractorPackagePayloadRemover: ExtractorPackagePayloadRemoving, Sendable {
    public init() {}

    public func removePackage(named name: String, from parentFD: Int32) throws {
        try ExtractorDirectoryValidator.removeStoreTree(named: name, from: parentFD)
    }
}

public protocol ExtractorCatalogIndexWriting: Sendable {
    func replaceAtomically(_ data: Data, directoryFD: Int32) throws
}

public struct FileExtractorCatalogIndexWriter: ExtractorCatalogIndexWriting, Sendable {
    public init() {}

    public func replaceAtomically(_ data: Data, directoryFD: Int32) throws {
        let temporaryName = ".index-\(UUID().uuidString.lowercased()).tmp"
        let descriptor = temporaryName.withCString {
            openat(directoryFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else { throw ExtractorPackageStoreError.filesystemFailure }
        var mustRemoveTemporary = true
        defer {
            if close(descriptor) != 0 {
                DebugLog.extraction("Extractor catalog temporary descriptor close failed")
            }
            if mustRemoveTemporary {
                _ = temporaryName.withCString { unlinkat(directoryFD, $0, 0) }
            }
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, base.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw ExtractorPackageStoreError.filesystemFailure }
                offset += count
            }
        }
        guard fchmod(descriptor, 0o400) == 0, fsync(descriptor) == 0 else {
            throw ExtractorPackageStoreError.filesystemFailure
        }
        let result = temporaryName.withCString { source in
            "index.json".withCString { destination in
                renameat(directoryFD, source, directoryFD, destination)
            }
        }
        guard result == 0, fsync(directoryFD) == 0 else {
            throw ExtractorPackageStoreError.filesystemFailure
        }
        mustRemoveTemporary = false
    }
}

/// Records whether a catalog mutation published a new generation.
///
/// A published generation must wake readers even when a later step of the same
/// operation throws. Package removal, for example, publishes the emptied
/// catalog before it deletes payload bytes; if that deletion fails, the
/// durable generation is still live and every process must still observe it.
// Sendability invariant: one Bool, read and written only under one lock.
// swiftlint:disable:next unchecked_sendable
final class ExtractorCatalogPublicationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var published = false

    var didPublish: Bool { lock.withLock { published } }

    func markPublished() {
        lock.withLock { published = true }
    }
}

public actor ExtractorPackageCatalogWriter {
    private let layout: ExtractorPackageStoreLayout
    private let coordinator: ExtractorPackageStoreCoordinator
    private let indexWriter: any ExtractorCatalogIndexWriting
    private let payloadRemover: any ExtractorPackagePayloadRemoving
    private let postWake: @Sendable () -> Void

    public init(
        appGroupContainerRoot: URL,
        coordinator: ExtractorPackageStoreCoordinator? = nil,
        indexWriter: any ExtractorCatalogIndexWriting = FileExtractorCatalogIndexWriter(),
        payloadRemover: any ExtractorPackagePayloadRemoving = FileExtractorPackagePayloadRemover(),
        postWake: @escaping @Sendable () -> Void = { DarwinNotifier.postExtractorCatalogChange() }
    ) throws {
        let layout = try ExtractorPackageStoreLayout(
            appGroupContainerRoot: appGroupContainerRoot,
            processRole: .app)
        self.layout = layout
        self.coordinator = coordinator ?? ExtractorPackageStoreCoordinator(layout: layout)
        self.indexWriter = indexWriter
        self.payloadRemover = payloadRemover
        self.postWake = postWake
    }

    public static func testing(
        layout: ExtractorPackageStoreLayout,
        coordinator: ExtractorPackageStoreCoordinator? = nil,
        indexWriter: any ExtractorCatalogIndexWriting = FileExtractorCatalogIndexWriter(),
        payloadRemover: any ExtractorPackagePayloadRemoving = FileExtractorPackagePayloadRemover(),
        postWake: @escaping @Sendable () -> Void = { DarwinNotifier.postExtractorCatalogChange() }
    ) throws -> Self {
        guard layout.processRole == .app || layout.processRole == .test else {
            throw ExtractorPackageStoreError.mutationForbidden
        }
        return try Self(
            appGroupContainerRoot: layout.appGroupContainerRoot,
            coordinator: coordinator,
            indexWriter: indexWriter,
            payloadRemover: payloadRemover,
            postWake: postWake)
    }

    /// Signals observers after every lock is released, so a woken reader in
    /// this or another process always finds a complete published generation.
    /// Wakes are hints, so a duplicate wake is harmless and a publication must
    /// never go unannounced.
    private func announce(_ flag: ExtractorCatalogPublicationFlag) {
        guard flag.didPublish else { return }
        // The in-process notification carries the store root so a context
        // watching a different store is not woken. The Darwin notification
        // stays payload-free: it crosses processes, where every reader must
        // reread its own authoritative catalog anyway.
        NotificationCenter.default.post(
            name: .extractorPackageCatalogDidChange,
            object: layout.root.standardizedFileURL)
        postWake()
    }

    /// Runs one exclusive catalog mutation and announces any generation it
    /// published, including when the operation throws after publication.
    private func mutating(
        _ body: @escaping @Sendable (ExtractorCatalogPublicationFlag) throws -> ExtractorPackageCatalog
    ) async throws -> ExtractorPackageCatalog {
        let flag = ExtractorCatalogPublicationFlag()
        do {
            let catalog = try await coordinator.withExclusiveAccess { try body(flag) }
            announce(flag)
            return catalog
        } catch {
            announce(flag)
            throw error
        }
    }

    public func read() throws -> ExtractorPackageCatalog {
        try ExtractorPackageCatalogReader(layout: layout).read()
    }

    public func importDirectory(
        _ source: URL,
        installedAt: RFC3339Timestamp
    ) async throws -> ExtractorPackageCatalog {
        let staged = try ExtractorDirectoryValidator.admit(source: source, layout: layout)
        return try await mutating { [layout, indexWriter] flag in
            try installStaged(
                staged,
                layout: layout,
                installedAt: installedAt,
                indexWriter: indexWriter,
                flag: flag)
        }
    }

    public func remove(
        revision: ExtractorPackageRevisionID,
        expectedGeneration: UInt64? = nil
    ) async throws -> ExtractorPackageCatalog {
        return try await mutating { [layout, indexWriter, payloadRemover] flag in
            let roots = try ExtractorDirectoryValidator.prepareStoreRoots(layout)
            defer { closeStoreRoots(roots) }
            let current = try ExtractorPackageCatalogReader.readCatalog(directoryFD: roots.derived)
            if let expectedGeneration, current.generation != expectedGeneration {
                throw ExtractorPackageStoreError.staleGeneration
            }
            guard current.records.contains(where: { $0.revision == revision }) else {
                return current
            }
            let next = try current.replacing(records: current.records.filter { $0.revision != revision })
            try publish(next, directoryFD: roots.derived, writer: indexWriter)
            // Membership is now durably gone. Every reader must learn this even
            // if the payload cleanup below fails.
            flag.markPublished()
            let packageIDDirectory = try openStoreDirectory(
                named: revision.packageID.rawValue,
                parentFD: roots.packages)
            do {
                try payloadRemover.removePackage(
                    named: revision.version.rawValue,
                    from: packageIDDirectory)
            } catch {
                close(packageIDDirectory)
                DebugLog.extraction("Extractor package removal published but payload cleanup failed")
                throw ExtractorPackageStoreError.packageRemovalFailed
            }
            guard close(packageIDDirectory) == 0 else {
                DebugLog.extraction("Extractor package removal published but lineage descriptor close failed")
                throw ExtractorPackageStoreError.packageRemovalFailed
            }
            do {
                _ = try ExtractorDirectoryValidator.removeEmptyStoreDirectory(
                    named: revision.packageID.rawValue,
                    from: roots.packages)
            } catch {
                DebugLog.extraction("Extractor package removal published but lineage cleanup failed")
                throw ExtractorPackageStoreError.packageRemovalFailed
            }
            return next
        }
    }

    public func recover() async throws -> ExtractorPackageCatalog {
        try await mutating { [layout, indexWriter] flag in
            try recoverStore(layout: layout, indexWriter: indexWriter, flag: flag)
        }
    }

    public func replaceCatalog(
        expectedGeneration: UInt64,
        records: [ExtractorPackageCatalogRecord]
    ) async throws -> ExtractorPackageCatalog {
        return try await mutating { [layout, indexWriter] flag in
            let roots = try ExtractorDirectoryValidator.prepareStoreRoots(layout)
            defer { closeStoreRoots(roots) }
            let current = try ExtractorPackageCatalogReader.readCatalog(directoryFD: roots.derived)
            guard current.generation == expectedGeneration else {
                throw ExtractorPackageStoreError.staleGeneration
            }
            let next = try current.replacing(records: records)
            try publish(next, directoryFD: roots.derived, writer: indexWriter)
            flag.markPublished()
            return next
        }
    }
}

private func installStaged(
    _ staged: ValidatedExtractorDirectory,
    layout: ExtractorPackageStoreLayout,
    installedAt: RFC3339Timestamp,
    indexWriter: any ExtractorCatalogIndexWriting,
    flag: ExtractorCatalogPublicationFlag
) throws -> ExtractorPackageCatalog {
    let roots = try ExtractorDirectoryValidator.prepareStoreRoots(layout)
    defer { closeStoreRoots(roots) }
    let revalidated = try ExtractorDirectoryValidator.revalidate(
        root: staged.root,
        within: layout.stagingRoot,
        expectedRevision: staged.revisionID)
    // Reviewed lineages are RESERVED (issue #1159, security review HIGH-3):
    // an imported package can never claim a reviewed package ID unless its
    // bytes reproduce the pinned reviewed revision exactly. Without this, a
    // self-declared packageID + version bump would let third-party code
    // squat a reviewed lineage and silently inherit its credential grants.
    if let reviewed = ReviewedExtractorPackages.all.first(
        where: { $0.packageID == revalidated.revisionID.packageID }),
        revalidated.revisionID != reviewed.revision {
        throw ExtractorDirectoryAdmissionError.reviewedLineageReserved(
            revalidated.revisionID.packageID.rawValue)
    }
    let current = try ExtractorPackageCatalogReader.readCatalog(directoryFD: roots.derived)
    let reservation = ExtractorPackageReservation(
        packageID: revalidated.revisionID.packageID,
        version: revalidated.revisionID.version)
    if let reserved = current.reservations.first(where: { $0.reservation == reservation }),
       reserved.digest != revalidated.revisionID.digest {
        throw ExtractorPackageStoreError.conflictingRevision
    }
    if let existing = current.records.first(where: { $0.revision == revalidated.revisionID }) {
        _ = try ExtractorDirectoryValidator.revalidate(
            root: layout.packageURL(existing.revision.packageID, version: existing.revision.version),
            within: layout.packagesRoot,
            expectedRevision: existing.revision)
        try ExtractorDirectoryValidator.removeStoreTree(
            named: revalidated.root.lastPathComponent,
            from: roots.staging)
        return current
    }
    let packageIDDirectory = try openOrCreateStoreDirectory(
        named: revalidated.revisionID.packageID.rawValue,
        parentFD: roots.packages)
    defer { close(packageIDDirectory) }
    let result = revalidated.root.lastPathComponent.withCString { sourceName in
        revalidated.revisionID.version.rawValue.withCString { destinationName in
            renderer_package_move_no_replace_at(
                roots.staging,
                sourceName,
                packageIDDirectory,
                destinationName)
        }
    }
    guard result == 0 else {
        if errno == EEXIST { throw ExtractorPackageStoreError.packageRootAlreadyExists }
        throw ExtractorPackageStoreError.filesystemFailure
    }
    guard fsync(packageIDDirectory) == 0, fsync(roots.staging) == 0 else {
        throw ExtractorPackageStoreError.filesystemFailure
    }
    let installed = try ExtractorDirectoryValidator.revalidate(
        root: layout.packageURL(
            revalidated.revisionID.packageID,
            version: revalidated.revisionID.version),
        within: layout.packagesRoot,
        expectedRevision: revalidated.revisionID)
    let record = try ExtractorPackageCatalogRecord(
        validatedManifest: installed.validated.manifest,
        revision: installed.revisionID,
        installedAt: installedAt)
    let next = try current.replacing(records: current.records + [record])
    try publish(next, directoryFD: roots.derived, writer: indexWriter)
    flag.markPublished()
    return next
}

private func recoverStore(
    layout: ExtractorPackageStoreLayout,
    indexWriter: any ExtractorCatalogIndexWriting,
    flag: ExtractorCatalogPublicationFlag
) throws -> ExtractorPackageCatalog {
    let roots = try ExtractorDirectoryValidator.prepareStoreRoots(layout)
    defer { closeStoreRoots(roots) }
    let current = try ExtractorPackageCatalogReader.readCatalog(directoryFD: roots.derived)
    var desiredRecords: [ExtractorPackageCatalogRecord] = []
    var cleanup: [(packageID: String, version: String)] = []

    for record in current.records {
        do {
            _ = try ExtractorDirectoryValidator.revalidate(
                root: layout.packageURL(record.revision.packageID, version: record.revision.version),
                within: layout.packagesRoot,
                expectedRevision: record.revision)
            desiredRecords.append(record)
        } catch {
            cleanup.append((
                packageID: record.revision.packageID.rawValue,
                version: record.revision.version.rawValue))
        }
    }

    for packageID in try ExtractorDirectoryValidator.storeDirectoryEntryNames(roots.packages) {
        let packageDirectory = try openStoreDirectory(named: packageID, parentFD: roots.packages)
        defer { close(packageDirectory) }
        for version in try ExtractorDirectoryValidator.storeDirectoryEntryNames(packageDirectory) {
            if desiredRecords.contains(where: {
                $0.revision.packageID.rawValue == packageID && $0.revision.version.rawValue == version
            }) {
                continue
            }
            let versionURL = layout.packagesRoot
                .appendingPathComponent(packageID, isDirectory: true)
                .appendingPathComponent(version, isDirectory: true)
            do {
                let manifestData = try Data(contentsOf: versionURL.appendingPathComponent(
                    ExtractorManifestValidator.manifestFileName))
                let manifest = try JSONDecoder().decode(ExtractorManifest.self, from: manifestData)
                let revision = ExtractorPackageRevisionID(
                    packageID: manifest.packageID,
                    version: manifest.version,
                    digest: try manifest.packageDigest())
                let reservation = ExtractorPackageReservation(
                    packageID: revision.packageID,
                    version: revision.version)
                guard packageID == revision.packageID.rawValue,
                      version == revision.version.rawValue,
                      current.reservations.contains(where: { $0.reservation == reservation }) == false else {
                    cleanup.append((packageID: packageID, version: version))
                    continue
                }
                let validated = try ExtractorDirectoryValidator.revalidate(
                    root: versionURL,
                    within: layout.packagesRoot,
                    expectedRevision: revision)
                desiredRecords.append(try ExtractorPackageCatalogRecord(
                    validatedManifest: validated.validated.manifest,
                    revision: revision,
                    installedAt: RFC3339Timestamp(date: Date())))
            } catch {
                cleanup.append((packageID: packageID, version: version))
            }
        }
    }

    let next: ExtractorPackageCatalog
    if desiredRecords.sorted() == current.records {
        next = current
    } else {
        next = try current.replacing(records: desiredRecords)
        try publish(next, directoryFD: roots.derived, writer: indexWriter)
        // Published before the payload cleanup below, which can throw.
        flag.markPublished()
    }

    for item in cleanup {
        do {
            let packageDirectory = try openStoreDirectory(
                named: item.packageID,
                parentFD: roots.packages)
            defer { close(packageDirectory) }
            try ExtractorDirectoryValidator.removeStoreTree(
                named: item.version,
                from: packageDirectory)
        } catch {
            throw ExtractorPackageStoreError.recoveryFailed
        }
    }
    for packageID in Set(cleanup.map(\.packageID)) {
        do {
            _ = try ExtractorDirectoryValidator.removeEmptyStoreDirectory(
                named: packageID,
                from: roots.packages)
        } catch {
            throw ExtractorPackageStoreError.recoveryFailed
        }
    }
    try removeAllChildren(from: roots.staging)
    do {
        try ExtractorDirectoryValidator.cleanupOperationSessions(
            layout: layout,
            scope: .staleSessions)
    } catch {
        throw ExtractorPackageStoreError.recoveryFailed
    }
    return next
}

private func publish(
    _ catalog: ExtractorPackageCatalog,
    directoryFD: Int32,
    writer: any ExtractorCatalogIndexWriting
) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(catalog)
    guard data.count <= ExtractorPackageCatalogReader.maximumCatalogByteCount else {
        throw ExtractorPackageStoreError.catalogTooLarge
    }
    try writer.replaceAtomically(data, directoryFD: directoryFD)
}

private func closeStoreRoots(
    _ roots: (root: Int32, packages: Int32, staging: Int32, derived: Int32, operations: Int32)
) {
    close(roots.root); close(roots.packages); close(roots.staging); close(roots.derived); close(roots.operations)
}

private func openOrCreateStoreDirectory(named name: String, parentFD: Int32) throws -> Int32 {
    let created = name.withCString { pointer -> (Int32, Int32) in
        let result = mkdirat(parentFD, pointer, 0o700)
        return (result, errno)
    }
    guard created.0 == 0 || created.1 == EEXIST else { throw ExtractorPackageStoreError.filesystemFailure }
    return try openStoreDirectory(named: name, parentFD: parentFD)
}

private func openStoreDirectory(named name: String, parentFD: Int32) throws -> Int32 {
    let descriptor = name.withCString { openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
    guard descriptor >= 0 else { throw ExtractorPackageStoreError.packageMissing }
    var status = stat()
    guard fstat(descriptor, &status) == 0,
          status.st_mode & S_IFMT == S_IFDIR,
          status.st_uid == getuid(),
          fchmod(descriptor, 0o700) == 0 else {
        close(descriptor)
        throw ExtractorPackageStoreError.filesystemFailure
    }
    return descriptor
}

private func removeAllChildren(from parentFD: Int32) throws {
    for name in try ExtractorDirectoryValidator.storeDirectoryEntryNames(parentFD) {
        try ExtractorDirectoryValidator.removeStoreTree(named: name, from: parentFD)
    }
}
