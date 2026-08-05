import Foundation

// pattern: Imperative Shell

/// Serializes machine package-store mutations within a process and with other
/// processes sharing the same App Group container.
public actor RendererPackageStoreCoordinator {
    private static let retryBackoff: Duration = .milliseconds(25)
    private static let maximumOwnerRecordBytes = 4_096

    private let layout: RendererPackageStoreLayout
    private let fileSystem: any RendererPackageFileSystem
    private let clock: any RendererCoordinatorClock
    private let processIdentity: RendererProcessIdentity
    private let livenessChecker: any RendererProcessLivenessChecking
    private let tokenGenerator: any RendererCoordinatorOwnerTokenGenerating
    private let policy: RendererEventPolicy

    public init(
        layout: RendererPackageStoreLayout,
        fileSystem: any RendererPackageFileSystem = RealRendererPackageFileSystem(),
        clock: any RendererCoordinatorClock = SystemRendererCoordinatorClock(),
        processIdentity: RendererProcessIdentity = .current(),
        livenessChecker: any RendererProcessLivenessChecking = SystemRendererProcessLivenessChecker(),
        tokenGenerator: any RendererCoordinatorOwnerTokenGenerating = UUIDRendererCoordinatorOwnerTokenGenerator(),
        policy: RendererEventPolicy = .phase3Default
    ) {
        self.layout = layout
        self.fileSystem = fileSystem
        self.clock = clock
        self.processIdentity = processIdentity
        self.livenessChecker = livenessChecker
        self.tokenGenerator = tokenGenerator
        self.policy = policy
    }

    public func withExclusiveAccess<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        let ownership = try await acquireLock()
        defer { releaseLock(ownership) }
        try Task.checkCancellation()
        return try await body()
    }

    private func acquireLock() async throws -> LockOwnership {
        let deadline = clock.now().addingTimeInterval(policy.lockAcquisitionTimeout)
        while true {
            try Task.checkCancellation()
            do {
                return try createLock()
            } catch RendererPackageStoreError.posix(_, _, let code) where code == EEXIST {
                try recoverExpiredLockIfSafe()
            } catch let failure as RendererCoordinatorFailure {
                throw failure
            } catch {
                throw RendererCoordinatorFailure.filesystemOperationFailed
            }
            guard clock.now() < deadline else { throw RendererCoordinatorFailure.lockAcquisitionTimedOut }
            try await Task.sleep(for: Self.retryBackoff)
        }
    }

    private func createLock() throws -> LockOwnership {
        try fileSystem.ensureDirectory(at: layout.root)
        let record = try RendererCoordinatorOwnerRecord(
            processIdentity: processIdentity,
            now: clock.now(),
            ownerToken: tokenGenerator.nextOwnerToken()
        )
        let data: Data
        do { data = try JSONEncoder().encode(record) }
        catch { throw RendererCoordinatorFailure.filesystemOperationFailed }
        let identity = try fileSystem.createExclusiveFile(at: layout.lockURL, contents: data)
        return LockOwnership(identity: identity, ownerToken: record.ownerToken)
    }

    private func recoverExpiredLockIfSafe() throws {
        let (record, identity) = try readOwnerRecord()
        guard try rendererCoordinatorShouldRecover(owner: record, now: clock.now(), policy: policy, livenessChecker: livenessChecker) else { return }
        let (verifiedRecord, verifiedIdentity) = try readOwnerRecord()
        guard identity == verifiedIdentity else { throw RendererCoordinatorFailure.lockIdentityChanged }
        guard record.ownerToken == verifiedRecord.ownerToken else { throw RendererCoordinatorFailure.lockOwnershipChanged }
        do { try fileSystem.removeFile(at: layout.lockURL) }
        catch { throw RendererCoordinatorFailure.lockCleanupFailed }
    }

    private func readOwnerRecord() throws -> (RendererCoordinatorOwnerRecord, RendererPackageFileIdentity) {
        let identity: RendererPackageFileIdentity
        let descriptor: Int32
        do {
            identity = try fileSystem.lstat(at: layout.lockURL)
            descriptor = try fileSystem.openReadOnlyNoFollow(at: layout.lockURL)
        } catch { throw RendererCoordinatorFailure.filesystemOperationFailed }
        let data: Data
        do {
            data = try fileSystem.readAll(fileDescriptor: descriptor, maximumBytes: Self.maximumOwnerRecordBytes)
            try fileSystem.close(fileDescriptor: descriptor)
        } catch {
            do { try fileSystem.close(fileDescriptor: descriptor) } catch { DebugLog.store("Renderer coordinator lock read descriptor close failed.") }
            throw RendererCoordinatorFailure.filesystemOperationFailed
        }
        return (try RendererCoordinatorOwnerRecord.decode(data), identity)
    }

    private func releaseLock(_ ownership: LockOwnership) {
        do {
            let (record, identity) = try readOwnerRecord()
            guard identity == ownership.identity else { throw RendererCoordinatorFailure.lockIdentityChanged }
            guard record.ownerToken == ownership.ownerToken else { throw RendererCoordinatorFailure.lockOwnershipChanged }
            try fileSystem.removeFile(at: layout.lockURL)
        } catch {
            DebugLog.store("Renderer coordinator lock release failed: redacted ownership verification error.")
        }
    }
}

private struct LockOwnership: Sendable {
    let identity: RendererPackageFileIdentity
    let ownerToken: String
}
