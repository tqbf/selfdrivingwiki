import Foundation
import Synchronization
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import WikiFSTypes

public struct ExtractorStagingID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init?(rawValue: String) {
        guard rawValue.isEmpty == false, rawValue.utf8.count <= 128,
              rawValue.allSatisfy({ $0.isASCII && ($0.isNumber || $0.isLetter || $0 == "-" || $0 == "_" ) }),
              rawValue != ".", rawValue != ".." else { return nil }
        self.rawValue = rawValue
    }
    public init() { self.rawValue = UUID().uuidString.lowercased() }
}

public struct ExtractorOperationID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init?(rawValue: String) {
        guard let value = ExtractorStagingID(rawValue: rawValue) else { return nil }; self.rawValue = value.rawValue
    }
    public init() { self.rawValue = UUID().uuidString.lowercased() }
}

public enum ExtractorPackageProcessRole: String, Codable, Hashable, Sendable {
    case app
    case daemon
    case commandLine
    case test
}

public enum ExtractorOperationCleanupScope: Sendable {
    case currentSession
    case staleSessions
}

public struct ExtractorPackageStoreLayout: Sendable {
    public let appGroupContainerRoot: URL
    public let processRole: ExtractorPackageProcessRole
    public let processSessionID: ExtractorStagingID

    public init(
        appGroupContainerRoot: URL,
        processRole: ExtractorPackageProcessRole = .app,
        processSessionID: ExtractorStagingID = ExtractorStagingID()
    ) throws {
        guard appGroupContainerRoot.isFileURL else { throw ExtractorDirectoryAdmissionError.nonFileURL }
        self.appGroupContainerRoot = appGroupContainerRoot.standardizedFileURL
        self.processRole = processRole
        self.processSessionID = processSessionID
    }
    public static func production(role: ExtractorPackageProcessRole) throws -> Self {
        try Self(
            appGroupContainerRoot: DatabaseLocation.appGroupContainerDirectory(),
            processRole: role)
    }
    public var root: URL { appGroupContainerRoot.appendingPathComponent("extractors/v1", isDirectory: true) }
    public var packagesRoot: URL { root.appendingPathComponent("packages", isDirectory: true) }
    public var stagingRoot: URL { root.appendingPathComponent("staging", isDirectory: true) }
    public var derivedRoot: URL { root.appendingPathComponent("derived", isDirectory: true) }
    public var derivedIndexURL: URL { derivedRoot.appendingPathComponent("index.json") }
    public var operationsRoot: URL { root.appendingPathComponent("operations", isDirectory: true) }
    public var processOperationsRoot: URL {
        operationsRoot
            .appendingPathComponent(processRole.rawValue, isDirectory: true)
            .appendingPathComponent("\(getpid())-\(processSessionID.rawValue)", isDirectory: true)
    }
    public func packageURL(_ id: ExtractorPackageID, version: ExtractorPackageVersion) -> URL { packagesRoot.appendingPathComponent(id.rawValue).appendingPathComponent(version.rawValue) }
    public func stagingURL(_ id: ExtractorStagingID) -> URL { stagingRoot.appendingPathComponent(id.rawValue, isDirectory: true) }
    public func operationURL(_ id: ExtractorOperationID) -> URL { processOperationsRoot.appendingPathComponent(id.rawValue, isDirectory: true) }
}

public enum ExtractorDirectoryAdmissionError: Error, Equatable, Sendable {
    case mutationForbidden
    case nonFileURL, sourceNotDirectory, sourceChanged, symlink(String), hardLink(String), specialFile(String)
    case deviceChanged(String), metadataChanged(String), modeChanged(String), collision(String), containment
    case copyFailed(String), preparationFailed, validationFailed, expectedRevisionMismatch, invalidStagingID, limitExceeded
    case manifest(ExtractorManifestValidationError)
    /// A third-party import tried to claim a reviewed package lineage with
    /// bytes that do not reproduce the pinned reviewed revision (#1159,
    /// security review HIGH-3).
    case reviewedLineageReserved(String)
}

public struct ValidatedExtractorDirectory: Sendable {
    public let validated: ValidatedExtractorManifest
    public let root: URL
    public init(validated: ValidatedExtractorManifest, root: URL) { self.validated = validated; self.root = root }
    public var revisionID: ExtractorPackageRevisionID { validated.revisionID }
}

public enum ExtractorDirectoryValidator {
    private static let sourceEnumerationHooks = Mutex<
        [String: @Sendable () throws -> Void]
    >([:])

    /// Tests use this package-only seam to simulate one exact source-directory change.
    package static func installSourceEnumerationHookForTesting(
        source: URL,
        _ hook: (@Sendable () throws -> Void)?
    ) {
        let key = source.standardizedFileURL.path
        sourceEnumerationHooks.withLock { hooks in
            hooks[key] = hook
        }
    }

    public static func admit(source: URL, layout: ExtractorPackageStoreLayout) throws -> ValidatedExtractorDirectory {
        guard layout.processRole == .app || layout.processRole == .test else {
            throw ExtractorDirectoryAdmissionError.mutationForbidden
        }
        guard source.isFileURL else { throw ExtractorDirectoryAdmissionError.nonFileURL }
        let sourceStatus = try lstat(source)
        guard sourceStatus.st_mode & S_IFMT == S_IFDIR else { throw ExtractorDirectoryAdmissionError.sourceNotDirectory }
        let sourceFD = source.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        guard sourceFD >= 0 else { throw ExtractorDirectoryAdmissionError.sourceChanged }
        defer { close(sourceFD) }
        let openedSource = try status(of: sourceFD)
        guard sameIdentity(sourceStatus, openedSource), openedSource.st_mode & S_IFMT == S_IFDIR else {
            throw ExtractorDirectoryAdmissionError.sourceChanged
        }

        let stagingID = ExtractorStagingID()
        let destination = layout.stagingURL(stagingID)
        let stagingFD: Int32
        let destinationFD: Int32
        do {
            let roots = try prepareStoreRoots(layout)
            stagingFD = roots.staging
            close(roots.root); close(roots.packages); close(roots.derived); close(roots.operations)
            destinationFD = try createDirectory(named: stagingID.rawValue, in: stagingFD)
        } catch {
            throw ExtractorDirectoryAdmissionError.preparationFailed
        }
        defer { close(destinationFD); close(stagingFD) }

        do {
            let sourceManifest = try readSourceManifest(directoryFD: sourceFD)
            let enumerationHook = sourceEnumerationHooks.withLock {
                $0[source.standardizedFileURL.path]
            }
            try copyTree(
                sourceFD: sourceFD,
                destinationFD: destinationFD,
                sourceDevice: openedSource.st_dev,
                manifest: sourceManifest,
                enumerationHook: enumerationHook)
            try verifyDirectory(sourceFD, matches: openedSource)
            try verifyPath(destination, matchesFD: destinationFD)

            let copiedManifest: ValidatedExtractorManifest
            do {
                copiedManifest = try ExtractorManifestValidator.validateStagedDirectory(destination)
                guard copiedManifest.manifest == sourceManifest else { throw ExtractorDirectoryAdmissionError.sourceChanged }
            } catch let error as ExtractorManifestValidationError {
                throw ExtractorDirectoryAdmissionError.manifest(error)
            }
            try verifyPath(destination, matchesFD: destinationFD)
            let result = try validate(destination)
            try verifyNormalizedModes(destination, manifest: result.validated.manifest)
            try verifyPath(destination, matchesFD: destinationFD)
            try verifyDirectory(sourceFD, matches: openedSource)
            return result
        } catch {
            // Recovery removes failed staging trees while the catalog writer lock excludes replacement races.
            if let error = error as? ExtractorDirectoryAdmissionError { throw error }
            throw ExtractorDirectoryAdmissionError.copyFailed("package")
        }
    }

    public static func revalidate(
        root: URL,
        within allowedRoot: URL,
        expectedRevision: ExtractorPackageRevisionID
    ) throws -> ValidatedExtractorDirectory {
        guard isContained(root, in: allowedRoot) else {
            throw ExtractorDirectoryAdmissionError.containment
        }
        let result = try validate(root)
        guard result.revisionID == expectedRevision else {
            throw ExtractorDirectoryAdmissionError.expectedRevisionMismatch
        }
        try verifyNormalizedModes(root, manifest: result.validated.manifest)
        return result
    }

    /// Admits one reviewed package that ships inside the application bundle or
    /// the daemon service bundle.
    ///
    /// A bundled source carries checkout or installer permissions, not the
    /// normalized store modes, so it cannot be revalidated in place. This copies
    /// it securely into the calling process's own operation root, normalizes it,
    /// validates it, and then checks the result against the compiled expected
    /// revision. A bundled revision whose bytes do not produce that exact
    /// revision is rejected.
    ///
    /// Every process role may call this. It writes only inside the process-owned
    /// operation directory. It never writes shared staging, the package root, or
    /// the catalog, so it does not make the daemon a catalog writer.
    public static func admitReviewedBundle(
        source: URL,
        expectedRevision: ExtractorPackageRevisionID,
        layout: ExtractorPackageStoreLayout
    ) throws -> ValidatedExtractorDirectory {
        guard source.isFileURL else { throw ExtractorDirectoryAdmissionError.nonFileURL }
        let sourceStatus = try lstat(source)
        guard sourceStatus.st_mode & S_IFMT == S_IFDIR else {
            throw ExtractorDirectoryAdmissionError.sourceNotDirectory
        }
        let sourceFD = source.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        guard sourceFD >= 0 else { throw ExtractorDirectoryAdmissionError.sourceChanged }
        defer { close(sourceFD) }
        let openedSource = try status(of: sourceFD)
        guard sameIdentity(sourceStatus, openedSource), openedSource.st_mode & S_IFMT == S_IFDIR else {
            throw ExtractorDirectoryAdmissionError.sourceChanged
        }

        let id = ExtractorOperationID()
        let destination = layout.operationURL(id)
        let processRootFD: Int32
        let destinationFD: Int32
        do {
            let roots = try prepareStoreRoots(layout)
            close(roots.root); close(roots.packages); close(roots.staging); close(roots.derived)
            let roleFD = try openOrCreateDirectory(named: layout.processRole.rawValue, in: roots.operations)
            close(roots.operations)
            defer { close(roleFD) }
            let processName = "\(getpid())-\(layout.processSessionID.rawValue)"
            processRootFD = try openOrCreateDirectory(named: processName, in: roleFD)
            destinationFD = try createDirectory(named: id.rawValue, in: processRootFD)
        } catch { throw ExtractorDirectoryAdmissionError.preparationFailed }
        defer { close(destinationFD); close(processRootFD) }

        do {
            let sourceManifest = try readSourceManifest(directoryFD: sourceFD)
            try copyTree(
                sourceFD: sourceFD,
                destinationFD: destinationFD,
                sourceDevice: openedSource.st_dev,
                manifest: sourceManifest)
            try verifyDirectory(sourceFD, matches: openedSource)
            try verifyPath(destination, matchesFD: destinationFD)

            let copiedManifest: ValidatedExtractorManifest
            do {
                copiedManifest = try ExtractorManifestValidator.validateStagedDirectory(destination)
                guard copiedManifest.manifest == sourceManifest else {
                    throw ExtractorDirectoryAdmissionError.sourceChanged
                }
            } catch let error as ExtractorManifestValidationError {
                throw ExtractorDirectoryAdmissionError.manifest(error)
            }
            try verifyPath(destination, matchesFD: destinationFD)
            let result = try revalidate(
                root: destination,
                within: layout.processOperationsRoot,
                expectedRevision: expectedRevision)
            try verifyPath(destination, matchesFD: destinationFD)
            try verifyDirectory(sourceFD, matches: openedSource)
            return result
        } catch {
            // Process startup recovery removes failed operation trees before
            // this process admits new work.
            if let error = error as? ExtractorDirectoryAdmissionError { throw error }
            throw ExtractorDirectoryAdmissionError.copyFailed("reviewed")
        }
    }

    /// - Parameter sourceContainingRoot: the root the source must sit beneath.
    ///   Installed revisions use the package root. A reviewed bundled revision
    ///   already admitted into this process's operation root passes that root
    ///   instead, because bundled bytes are never installed by a reader process.
    public static func snapshot(
        installedRoot: URL,
        expectedRevision: ExtractorPackageRevisionID,
        layout: ExtractorPackageStoreLayout,
        sourceContainingRoot: URL? = nil
    ) throws -> ValidatedExtractorDirectory {
        let installed = try revalidate(
            root: installedRoot,
            within: sourceContainingRoot ?? layout.packagesRoot,
            expectedRevision: expectedRevision)
        let id = ExtractorOperationID()
        let destination = layout.operationURL(id)
        let sourceStatus = try lstat(installedRoot)
        let sourceFD = installedRoot.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        guard sourceFD >= 0 else { throw ExtractorDirectoryAdmissionError.sourceChanged }
        defer { close(sourceFD) }
        let openedSource = try status(of: sourceFD)
        guard sameIdentity(sourceStatus, openedSource) else { throw ExtractorDirectoryAdmissionError.sourceChanged }
        let processRootFD: Int32
        let destinationFD: Int32
        do {
            let roots = try prepareStoreRoots(layout)
            close(roots.root); close(roots.packages); close(roots.staging); close(roots.derived)
            let roleFD = try openOrCreateDirectory(named: layout.processRole.rawValue, in: roots.operations)
            close(roots.operations)
            defer { close(roleFD) }
            let processName = "\(getpid())-\(layout.processSessionID.rawValue)"
            processRootFD = try openOrCreateDirectory(named: processName, in: roleFD)
            destinationFD = try createDirectory(named: id.rawValue, in: processRootFD)
        } catch { throw ExtractorDirectoryAdmissionError.preparationFailed }
        defer { close(destinationFD); close(processRootFD) }
        do {
            try copyTree(sourceFD: sourceFD, destinationFD: destinationFD, sourceDevice: openedSource.st_dev, manifest: installed.validated.manifest)
            try verifyDirectory(sourceFD, matches: openedSource)
            try verifyPath(destination, matchesFD: destinationFD)
            let result = try revalidate(root: destination, within: layout.processOperationsRoot, expectedRevision: expectedRevision)
            try verifyPath(destination, matchesFD: destinationFD)
            return result
        } catch {
            // Process startup recovery removes failed snapshots before this process admits new work.
            if let error = error as? ExtractorDirectoryAdmissionError { throw error }
            throw ExtractorDirectoryAdmissionError.copyFailed("snapshot")
        }
    }

    /// Copies one admitted or revalidated package tree into a fresh private
    /// operation directory owned by the calling process. The target must not
    /// exist; its parent must already be an owner-private directory. The copy
    /// is no-follow and identity-checked at the source, and the result is
    /// revalidated against normalized modes before returning.
    public static func materializeOperationPackage(
        from validated: ValidatedExtractorDirectory,
        into target: URL
    ) throws -> ExtractorPackageRevisionID {
        let parentStatus = try lstat(target.deletingLastPathComponent())
        guard parentStatus.st_mode & S_IFMT == S_IFDIR,
              parentStatus.st_uid == getuid() else {
            throw ExtractorDirectoryAdmissionError.preparationFailed
        }
        let createResult = target.lastPathComponent.withCString { name -> Int32 in
            let parentFD = open(
                target.deletingLastPathComponent().path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            defer { if parentFD >= 0 { close(parentFD) } }
            guard parentFD >= 0 else { return -1 }
            return mkdirat(parentFD, name, 0o700)
        }
        guard createResult == 0 else {
            throw ExtractorDirectoryAdmissionError.preparationFailed
        }

        let sourceURL = validated.root.standardizedFileURL
        let targetStandardized = target.standardizedFileURL
        let sourceStatus = try lstat(sourceURL)
        let sourceFD = sourceURL.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        }
        guard sourceFD >= 0 else { throw ExtractorDirectoryAdmissionError.sourceChanged }
        defer { close(sourceFD) }
        let openedSource = try status(of: sourceFD)
        guard sameIdentity(sourceStatus, openedSource),
              openedSource.st_mode & S_IFMT == S_IFDIR else {
            throw ExtractorDirectoryAdmissionError.sourceChanged
        }

        let destinationFD = targetStandardized.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        }
        guard destinationFD >= 0 else {
            throw ExtractorDirectoryAdmissionError.preparationFailed
        }
        defer { close(destinationFD) }
        do {
            try normalizePrivateDirectory(destinationFD)
            try copyTree(
                sourceFD: sourceFD,
                destinationFD: destinationFD,
                sourceDevice: openedSource.st_dev,
                manifest: validated.validated.manifest)
            try verifyDirectory(sourceFD, matches: openedSource)
            try verifyPath(targetStandardized, matchesFD: destinationFD)
            let result = try validate(targetStandardized)
            try verifyNormalizedModes(targetStandardized, manifest: result.validated.manifest)
            try verifyPath(targetStandardized, matchesFD: destinationFD)
            return result.revisionID
        } catch {
            if let error = error as? ExtractorDirectoryAdmissionError { throw error }
            throw ExtractorDirectoryAdmissionError.copyFailed("operation-package")
        }
    }

    public static func cleanupOperationSessions(
        layout: ExtractorPackageStoreLayout,
        scope: ExtractorOperationCleanupScope
    ) throws {
        guard let roleDirectory = try openExistingOperationRoleDirectory(layout) else { return }
        defer { close(roleDirectory) }
        let currentName = "\(getpid())-\(layout.processSessionID.rawValue)"
        for name in try directoryEntryNames(roleDirectory) {
            let mustRemove: Bool
            switch scope {
            case .currentSession:
                mustRemove = name == currentName
            case .staleSessions:
                mustRemove = name != currentName && operationSessionIsStale(name)
            }
            if mustRemove {
                try removeStoreTree(named: name, from: roleDirectory)
            }
        }
    }

    private static func openExistingOperationRoleDirectory(
        _ layout: ExtractorPackageStoreLayout
    ) throws -> Int32? {
        let root = layout.appGroupContainerRoot.path.withCString {
            pointer -> (descriptor: Int32, error: Int32) in
            let descriptor = open(pointer, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            return (descriptor, errno)
        }
        guard root.descriptor >= 0 else {
            if root.error == ENOENT { return nil }
            throw ExtractorDirectoryAdmissionError.preparationFailed
        }
        var current = root.descriptor
        for component in ["extractors", "v1", "operations", layout.processRole.rawValue] {
            let next = component.withCString {
                pointer -> (descriptor: Int32, error: Int32) in
                let descriptor = openat(current, pointer, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                return (descriptor, errno)
            }
            close(current)
            guard next.descriptor >= 0 else {
                if next.error == ENOENT { return nil }
                throw ExtractorDirectoryAdmissionError.preparationFailed
            }
            current = next.descriptor
        }
        return current
    }

    private static func operationSessionIsStale(_ name: String) -> Bool {
        guard let separator = name.firstIndex(of: "-"),
              let processID = Int32(name[..<separator]),
              processID > 0 else {
            return true
        }
        if processID == getpid() { return true }
        if kill(processID, 0) == 0 { return false }
        return errno != EPERM
    }

    private static func validate(_ root: URL) throws -> ValidatedExtractorDirectory {
        do { return ValidatedExtractorDirectory(validated: try ExtractorManifestValidator.validateStagedDirectory(root), root: root) }
        catch let e as ExtractorManifestValidationError { throw ExtractorDirectoryAdmissionError.manifest(e) }
    }
    private struct CopyAccounting {
        var fileCount = 0
        var byteCount = 0
        var collisionKeys: Set<String> = []
    }

    private static func copyTree(
        sourceFD: Int32,
        destinationFD: Int32,
        sourceDevice: dev_t,
        manifest: ExtractorManifest,
        enumerationHook: (@Sendable () throws -> Void)? = nil
    ) throws {
        var accounting = CopyAccounting()
        try copyDirectory(
            sourceFD: sourceFD,
            destinationFD: destinationFD,
            relativePrefix: "",
            sourceDevice: sourceDevice,
            manifest: manifest,
            enumerationHook: enumerationHook,
            accounting: &accounting)
        guard fchmod(destinationFD, 0o700) == 0 else { throw ExtractorDirectoryAdmissionError.modeChanged("package") }
    }

    private static func copyDirectory(
        sourceFD: Int32,
        destinationFD: Int32,
        relativePrefix: String,
        sourceDevice: dev_t,
        manifest: ExtractorManifest,
        enumerationHook: (@Sendable () throws -> Void)?,
        accounting: inout CopyAccounting
    ) throws {
        let directoryBefore = try status(of: sourceFD)
        guard directoryBefore.st_mode & S_IFMT == S_IFDIR, directoryBefore.st_dev == sourceDevice else {
            throw ExtractorDirectoryAdmissionError.sourceChanged
        }
        let names = try directoryEntryNames(sourceFD)
        if relativePrefix.isEmpty { try enumerationHook?() }
        for name in names {
            guard name != ".", name != "..", name.contains("/") == false else {
                throw ExtractorDirectoryAdmissionError.copyFailed("path")
            }
            let relativeValue = relativePrefix.isEmpty ? name : relativePrefix + "/" + name
            guard let relativePath = ExtractorRelativePath(rawValue: relativeValue) else {
                throw ExtractorDirectoryAdmissionError.copyFailed("path")
            }
            guard accounting.collisionKeys.insert(relativePath.collisionKey).inserted else {
                throw ExtractorDirectoryAdmissionError.collision(relativePath.rawValue)
            }
            let before = try status(at: sourceFD, name: name, noFollow: true)
            guard before.st_dev == sourceDevice else {
                throw ExtractorDirectoryAdmissionError.deviceChanged(relativePath.rawValue)
            }
            switch before.st_mode & S_IFMT {
            case S_IFLNK:
                throw ExtractorDirectoryAdmissionError.symlink(relativePath.rawValue)
            case S_IFDIR:
                let childSource = name.withCString { openat(sourceFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
                guard childSource >= 0 else { throw ExtractorDirectoryAdmissionError.sourceChanged }
                defer { close(childSource) }
                let opened = try status(of: childSource)
                guard sameIdentity(before, opened) else { throw ExtractorDirectoryAdmissionError.sourceChanged }
                let childDestination = try createDirectory(named: name, in: destinationFD)
                defer { close(childDestination) }
                try copyDirectory(
                    sourceFD: childSource,
                    destinationFD: childDestination,
                    relativePrefix: relativeValue,
                    sourceDevice: sourceDevice,
                    manifest: manifest,
                    enumerationHook: enumerationHook,
                    accounting: &accounting)
                try verifyDirectory(childSource, matches: opened)
            case S_IFREG:
                guard before.st_nlink == 1 else { throw ExtractorDirectoryAdmissionError.hardLink(relativePath.rawValue) }
                accounting.fileCount += 1
                accounting.byteCount += Int(before.st_size)
                guard accounting.fileCount <= ExtractorHostLimits.maximumPackageFileCount,
                      accounting.byteCount <= ExtractorHostLimits.maximumPackageByteCount + ExtractorHostLimits.maximumManifestByteCount else {
                    throw ExtractorDirectoryAdmissionError.limitExceeded
                }
                if relativePath == manifest.entryPoint {
                    switch manifest.launch {
                    case .direct:
                        guard before.st_mode & S_IRUSR != 0, before.st_mode & S_IXUSR != 0 else { throw ExtractorDirectoryAdmissionError.manifest(.directEntryPointIsNotOwnerExecutable) }
                    case .runtime:
                        guard before.st_mode & S_IRUSR != 0 else { throw ExtractorDirectoryAdmissionError.manifest(.runtimeEntryPointIsNotReadable) }
                    }
                }
                let maximum = relativePath.rawValue == ExtractorManifestValidator.manifestFileName ? ExtractorHostLimits.maximumManifestByteCount : ExtractorHostLimits.maximumPackageByteCount
                let data = try readNoFollow(directoryFD: sourceFD, name: name, expected: before, maximum: maximum)
                let fileMode: mode_t = relativePath == manifest.entryPoint && isDirect(manifest.launch) ? 0o500 : 0o400
                try createExclusiveFile(directoryFD: destinationFD, name: name, data: data, mode: fileMode)
                let after = try status(at: sourceFD, name: name, noFollow: true)
                guard sameMetadata(before, after) else { throw ExtractorDirectoryAdmissionError.metadataChanged(relativePath.rawValue) }
            default:
                throw ExtractorDirectoryAdmissionError.specialFile(relativePath.rawValue)
            }
        }
        try verifyDirectory(sourceFD, matches: directoryBefore)
    }

    private static func verifyNormalizedModes(_ root: URL, manifest: ExtractorManifest) throws {
        guard try mode(root) == 0o700,
              let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw ExtractorDirectoryAdmissionError.modeChanged("package")
        }
        let rootComponents = root.standardizedFileURL.pathComponents
        for case let url as URL in enumerator {
            let relativeValue = url.standardizedFileURL.pathComponents
                .dropFirst(rootComponents.count)
                .joined(separator: "/")
            guard let relativePath = ExtractorRelativePath(rawValue: relativeValue) else {
                throw ExtractorDirectoryAdmissionError.copyFailed("path")
            }
            let status = try lstat(url)
            let expectedMode: mode_t
            switch status.st_mode & S_IFMT {
            case S_IFDIR:
                expectedMode = 0o700
            case S_IFREG:
                expectedMode = relativePath == manifest.entryPoint && isDirect(manifest.launch) ? 0o500 : 0o400
            default:
                throw ExtractorDirectoryAdmissionError.specialFile(relativePath.rawValue)
            }
            guard status.st_mode & 0o7777 == expectedMode else {
                throw ExtractorDirectoryAdmissionError.modeChanged(relativePath.rawValue)
            }
        }
    }

    private static func mode(_ url: URL) throws -> mode_t {
        try lstat(url).st_mode & 0o7777
    }

    private static func readSourceManifest(directoryFD: Int32) throws -> ExtractorManifest {
        let name = ExtractorManifestValidator.manifestFileName
        let fileStatus = try status(at: directoryFD, name: name, noFollow: true)
        guard fileStatus.st_mode & S_IFMT == S_IFREG, fileStatus.st_nlink == 1 else {
            throw ExtractorDirectoryAdmissionError.manifest(.forbiddenFileType(name))
        }
        let data = try readNoFollow(directoryFD: directoryFD, name: name, expected: fileStatus, maximum: ExtractorHostLimits.maximumManifestByteCount)
        do { return try JSONDecoder().decode(ExtractorManifest.self, from: data) }
        catch { throw ExtractorDirectoryAdmissionError.manifest(.malformedManifest) }
    }

    private static func isDirect(_ launch: ExtractorLaunch) -> Bool {
        if case .direct = launch { return true }
        return false
    }

    private static func createExclusiveFile(directoryFD: Int32, name: String, data: Data, mode: mode_t) throws {
        let descriptor = name.withCString { openat(directoryFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode) }
        guard descriptor >= 0 else { throw ExtractorDirectoryAdmissionError.copyFailed("file") }
        defer { close(descriptor) }
        let opened = try status(of: descriptor)
        guard opened.st_mode & S_IFMT == S_IFREG, opened.st_nlink == 1 else { throw ExtractorDirectoryAdmissionError.copyFailed("file") }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, base.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw ExtractorDirectoryAdmissionError.copyFailed("file") }
                offset += count
            }
        }
        guard fchmod(descriptor, mode) == 0, fsync(descriptor) == 0 else { throw ExtractorDirectoryAdmissionError.copyFailed("file") }
    }

    private static func readNoFollow(directoryFD: Int32, name: String, expected: stat, maximum: Int) throws -> Data {
        let descriptor = name.withCString { openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw ExtractorDirectoryAdmissionError.sourceChanged }
        defer { close(descriptor) }
        let opened = try status(of: descriptor)
        guard sameIdentity(opened, expected), opened.st_mode & S_IFMT == S_IFREG, opened.st_nlink == 1 else { throw ExtractorDirectoryAdmissionError.sourceChanged }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            guard count >= 0 else { throw ExtractorDirectoryAdmissionError.copyFailed("file") }
            if count == 0 { break }
            data.append(contentsOf: buffer[0 ..< count])
            guard data.count <= maximum else { throw ExtractorDirectoryAdmissionError.limitExceeded }
        }
        let after = try status(of: descriptor)
        guard sameMetadata(opened, after) else { throw ExtractorDirectoryAdmissionError.sourceChanged }
        return data
    }

    private static func status(of descriptor: Int32) throws -> stat {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw ExtractorDirectoryAdmissionError.sourceChanged }
        return value
    }

    private static func status(at directoryFD: Int32, name: String, noFollow: Bool) throws -> stat {
        var value = stat()
        let flags = noFollow ? AT_SYMLINK_NOFOLLOW : 0
        guard name.withCString({ fstatat(directoryFD, $0, &value, flags) }) == 0 else { throw ExtractorDirectoryAdmissionError.sourceChanged }
        return value
    }

    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool { lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino }

    private static func verifyDirectory(_ descriptor: Int32, matches expected: stat) throws {
        let current = try status(of: descriptor)
        guard sameMetadata(expected, current), current.st_mode & S_IFMT == S_IFDIR else { throw ExtractorDirectoryAdmissionError.sourceChanged }
    }

    private static func verifyPath(_ url: URL, matchesFD descriptor: Int32) throws {
        let pathStatus = try lstat(url)
        let descriptorStatus = try status(of: descriptor)
        guard sameIdentity(pathStatus, descriptorStatus), pathStatus.st_mode & S_IFMT == S_IFDIR else { throw ExtractorDirectoryAdmissionError.sourceChanged }
    }

    private static func directoryEntryNames(_ descriptor: Int32) throws -> [String] {
        let duplicate = dup(descriptor)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            throw ExtractorDirectoryAdmissionError.copyFailed("enumeration")
        }
        defer { closedir(directory) }
        rewinddir(directory)
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                #if canImport(Darwin)
                let capacity = Int(entry.pointee.d_namlen) + 1
                #else
                let capacity = Int(NAME_MAX) + 1
                #endif
                return $0.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    String(validatingCString: $0)
                }
            }
            guard let name else { throw ExtractorDirectoryAdmissionError.copyFailed("path") }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }

    private static func createDirectory(named name: String, in parentFD: Int32) throws -> Int32 {
        guard name.withCString({ mkdirat(parentFD, $0, 0o700) }) == 0 else {
            throw ExtractorDirectoryAdmissionError.preparationFailed
        }
        let descriptor = name.withCString { openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw ExtractorDirectoryAdmissionError.preparationFailed }
        do {
            try normalizePrivateDirectory(descriptor)
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func openOrCreateDirectory(named name: String, in parentFD: Int32) throws -> Int32 {
        let creation = name.withCString { pointer -> (Int32, Int32) in
            let result = mkdirat(parentFD, pointer, 0o700)
            return (result, errno)
        }
        if creation.0 != 0, creation.1 != EEXIST { throw ExtractorDirectoryAdmissionError.preparationFailed }
        let descriptor = name.withCString { openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw ExtractorDirectoryAdmissionError.preparationFailed }
        do {
            try normalizePrivateDirectory(descriptor)
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func normalizePrivateDirectory(_ descriptor: Int32) throws {
        guard fchmod(descriptor, 0o700) == 0 else {
            throw ExtractorDirectoryAdmissionError.preparationFailed
        }
        let directoryStatus = try status(of: descriptor)
        guard directoryStatus.st_mode & S_IFMT == S_IFDIR,
              directoryStatus.st_uid == getuid(),
              directoryStatus.st_mode & 0o7777 == 0o700 else {
            throw ExtractorDirectoryAdmissionError.preparationFailed
        }
    }

    private static func canonicalURL(_ url: URL) throws -> URL {
        let resolved = url.path.withCString { pointer -> UnsafeMutablePointer<CChar>? in realpath(pointer, nil) }
        guard let resolved else { throw ExtractorDirectoryAdmissionError.preparationFailed }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    public static func openStoreAuthority(_ layout: ExtractorPackageStoreLayout) throws -> Int32 {
        try FileManager.default.createDirectory(
            at: layout.appGroupContainerRoot,
            withIntermediateDirectories: true)
        let authorityURL = try canonicalURL(layout.appGroupContainerRoot)
        let pathStatus = try lstat(authorityURL)
        let descriptor = authorityURL.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw ExtractorDirectoryAdmissionError.preparationFailed }
        do {
            let opened = try status(of: descriptor)
            guard sameIdentity(pathStatus, opened),
                  opened.st_mode & S_IFMT == S_IFDIR else {
                throw ExtractorDirectoryAdmissionError.preparationFailed
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    public static func storeDirectoryEntryNames(_ descriptor: Int32) throws -> [String] {
        try directoryEntryNames(descriptor)
    }

    public static func removeEmptyStoreDirectory(
        named name: String,
        from parentFD: Int32
    ) throws -> Bool {
        let before = try status(at: parentFD, name: name, noFollow: true)
        guard before.st_mode & S_IFMT == S_IFDIR,
              before.st_uid == getuid() else {
            throw ExtractorDirectoryAdmissionError.preparationFailed
        }
        let descriptor = name.withCString {
            openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw ExtractorDirectoryAdmissionError.preparationFailed }
        defer { close(descriptor) }
        let opened = try status(of: descriptor)
        guard sameIdentity(before, opened), opened.st_mode & S_IFMT == S_IFDIR else {
            throw ExtractorDirectoryAdmissionError.preparationFailed
        }
        guard try directoryEntryNames(descriptor).isEmpty else { return false }
        let current = try status(at: parentFD, name: name, noFollow: true)
        guard sameIdentity(opened, current) else {
            throw ExtractorDirectoryAdmissionError.preparationFailed
        }
        let result = name.withCString { unlinkat(parentFD, $0, AT_REMOVEDIR) }
        if result == 0 { return true }
        if errno == ENOTEMPTY || errno == EEXIST { return false }
        throw ExtractorDirectoryAdmissionError.preparationFailed
    }

    public static func removeStoreTree(
        named name: String,
        from parentFD: Int32
    ) throws {
        let before = try status(at: parentFD, name: name, noFollow: true)
        guard before.st_mode & S_IFMT == S_IFDIR,
              before.st_uid == getuid() else {
            throw ExtractorDirectoryAdmissionError.preparationFailed
        }
        let descriptor = name.withCString {
            openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw ExtractorDirectoryAdmissionError.preparationFailed }
        defer { close(descriptor) }
        let opened = try status(of: descriptor)
        guard sameIdentity(before, opened), opened.st_mode & S_IFMT == S_IFDIR else {
            throw ExtractorDirectoryAdmissionError.preparationFailed
        }
        for child in try directoryEntryNames(descriptor) {
            let childStatus = try status(at: descriptor, name: child, noFollow: true)
            switch childStatus.st_mode & S_IFMT {
            case S_IFDIR:
                try removeStoreTree(named: child, from: descriptor)
            case S_IFREG:
                guard childStatus.st_uid == getuid(), childStatus.st_nlink == 1 else {
                    throw ExtractorDirectoryAdmissionError.preparationFailed
                }
                guard child.withCString({ unlinkat(descriptor, $0, 0) }) == 0 else {
                    throw ExtractorDirectoryAdmissionError.preparationFailed
                }
            default:
                throw ExtractorDirectoryAdmissionError.preparationFailed
            }
        }
        let after = try status(of: descriptor)
        let entry = try status(at: parentFD, name: name, noFollow: true)
        guard sameIdentity(opened, after), sameIdentity(opened, entry) else {
            throw ExtractorDirectoryAdmissionError.preparationFailed
        }
        guard name.withCString({ unlinkat(parentFD, $0, AT_REMOVEDIR) }) == 0 else {
            throw ExtractorDirectoryAdmissionError.preparationFailed
        }
    }

    public static func prepareStoreRoots(_ layout: ExtractorPackageStoreLayout) throws -> (root: Int32, packages: Int32, staging: Int32, derived: Int32, operations: Int32) {
        try FileManager.default.createDirectory(at: layout.appGroupContainerRoot, withIntermediateDirectories: true)
        let authorityURL = try canonicalURL(layout.appGroupContainerRoot)
        let authorityPathStatus = try lstat(authorityURL)
        let authorityFD = authorityURL.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        guard authorityFD >= 0 else { throw ExtractorDirectoryAdmissionError.preparationFailed }
        defer { close(authorityFD) }
        let authorityOpenedStatus = try status(of: authorityFD)
        guard sameIdentity(authorityPathStatus, authorityOpenedStatus), authorityOpenedStatus.st_mode & S_IFMT == S_IFDIR else {
            throw ExtractorDirectoryAdmissionError.preparationFailed
        }
        let extractors = try openOrCreateDirectory(named: "extractors", in: authorityFD)
        defer { close(extractors) }
        let authorityBaseline = try status(of: authorityFD)
        let root = try openOrCreateDirectory(named: "v1", in: extractors)
        defer { close(root) }
        let authorityAfter = try status(of: authorityFD)
        guard sameIdentity(authorityBaseline, authorityAfter),
              authorityAfter.st_mode & S_IFMT == S_IFDIR else {
            throw ExtractorDirectoryAdmissionError.sourceChanged
        }
        let packages = try openOrCreateDirectory(named: "packages", in: root)
        do {
            let staging = try openOrCreateDirectory(named: "staging", in: root)
            let derived = try openOrCreateDirectory(named: "derived", in: root)
            let operations = try openOrCreateDirectory(named: "operations", in: root)
            let rootBaseline = try status(of: root)
            try verifyDirectory(root, matches: rootBaseline)
            let retainedRoot = dup(root)
            guard retainedRoot >= 0 else {
                close(packages); close(staging); close(derived); close(operations)
                throw ExtractorDirectoryAdmissionError.preparationFailed
            }
            return (retainedRoot, packages, staging, derived, operations)
        } catch { close(packages); throw error }
    }
    private static func lstat(_ u: URL) throws -> stat { var s = stat(); guard DarwinOrGlibc.lstat(u.path, &s) == 0 else { throw ExtractorDirectoryAdmissionError.copyFailed(u.lastPathComponent) }; return s }
    private static func sameMetadata(_ a: stat, _ b: stat) -> Bool {
        #if canImport(Darwin)
        return a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec && a.st_mode == b.st_mode
        #else
        return a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size && a.st_mtim.tv_sec == b.st_mtim.tv_sec && a.st_mtim.tv_nsec == b.st_mtim.tv_nsec && a.st_ctim.tv_sec == b.st_ctim.tv_sec && a.st_ctim.tv_nsec == b.st_ctim.tv_nsec && a.st_mode == b.st_mode
        #endif
    }
    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        isRendererPackageStorePathContained(candidate, within: root)
    }
}

private enum DarwinOrGlibc {
    static func lstat(_ path: String, _ s: UnsafeMutablePointer<stat>) -> Int32 {
        #if canImport(Darwin)
        return Darwin.lstat(path, s)
        #else
        return Glibc.lstat(path, s)
        #endif
    }
}
