import Foundation

// pattern: Imperative Shell

/// Serializes machine package-store mutations within a process and with other
/// processes sharing the same App Group container.
public actor RendererPackageStoreCoordinator {
    private static let retryBackoff: Duration = .milliseconds(25)
    private static let inProcessGate = RendererPackageStoreInProcessGate()

    private let layout: RendererPackageStoreLayout
    private let fileSystem: any RendererPackageFileSystem
    private let clock: any RendererCoordinatorClock
    private let processIdentity: RendererProcessIdentity
    private let tokenGenerator: any RendererCoordinatorOwnerTokenGenerating
    private let policy: RendererEventPolicy

    public init(
        layout: RendererPackageStoreLayout,
        fileSystem: any RendererPackageFileSystem = RealRendererPackageFileSystem(),
        clock: any RendererCoordinatorClock = SystemRendererCoordinatorClock(),
        processIdentity: RendererProcessIdentity = .current(),
        tokenGenerator: any RendererCoordinatorOwnerTokenGenerating = UUIDRendererCoordinatorOwnerTokenGenerator(),
        policy: RendererEventPolicy = .phase3Default
    ) {
        self.layout = layout
        self.fileSystem = fileSystem
        self.clock = clock
        self.processIdentity = processIdentity
        self.tokenGenerator = tokenGenerator
        self.policy = policy
    }

    public func withExclusiveAccess<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        let ownership = try await acquireLock()
        do {
            try Task.checkCancellation()
            let value = try await body()
            await releaseLock(ownership)
            return value
        } catch {
            await releaseLock(ownership)
            throw error
        }
    }

    private func acquireLock() async throws -> LockOwnership {
        let deadline = clock.now().addingTimeInterval(policy.lockAcquisitionTimeout)
        while true {
            try Task.checkCancellation()
            guard await Self.inProcessGate.tryAcquire(layout.lockURL.path) else {
                try await Task.sleep(for: Self.retryBackoff)
                guard clock.now() < deadline else { throw RendererCoordinatorFailure.lockAcquisitionTimedOut }
                continue
            }
            do {
                return try createLock()
            } catch RendererPackageStoreError.posix(_, _, let code) where code == EWOULDBLOCK || code == EAGAIN {
                await Self.inProcessGate.release(layout.lockURL.path)
                // Ordinary contention: the current owner may cooperatively release.
                try await Task.sleep(for: Self.retryBackoff)
            } catch let failure as RendererCoordinatorFailure {
                await Self.inProcessGate.release(layout.lockURL.path)
                throw failure
            } catch {
                await Self.inProcessGate.release(layout.lockURL.path)
                throw RendererCoordinatorFailure.filesystemOperationFailed
            }
            guard clock.now() < deadline else { throw RendererCoordinatorFailure.lockAcquisitionTimedOut }
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
        let descriptor: Int32
        do {
            descriptor = try fileSystem.createExclusiveLockFile(at: layout.lockURL, contents: data)
        } catch RendererPackageStoreError.posix(_, _, let code) where code == EEXIST {
            descriptor = try fileSystem.openLockFileNoFollow(at: layout.lockURL)
        }
        do {
            try fileSystem.lockExclusiveNonblocking(fileDescriptor: descriptor)
            return LockOwnership(fileDescriptor: descriptor)
        } catch {
            do { try fileSystem.close(fileDescriptor: descriptor) } catch { DebugLog.store("Renderer coordinator lock descriptor close failed.") }
            throw error
        }
    }

    private func releaseLock(_ ownership: LockOwnership) async {
        do {
            try fileSystem.unlock(fileDescriptor: ownership.fileDescriptor)
            try fileSystem.close(fileDescriptor: ownership.fileDescriptor)
        } catch {
            DebugLog.store("Renderer coordinator lock release failed: redacted ownership verification error.")
        }
        await Self.inProcessGate.release(layout.lockURL.path)
    }
}

/// A layout-keyed gate prevents a reentrant actor suspension from allowing a
/// second coordinator in this process to race a separately opened lock file.
/// The kernel `flock` remains the cross-process authority.
private actor RendererPackageStoreInProcessGate {
    private var heldLayouts: Set<String> = []

    func tryAcquire(_ layoutKey: String) -> Bool {
        return heldLayouts.insert(layoutKey).inserted
    }

    func release(_ layoutKey: String) {
        heldLayouts.remove(layoutKey)
    }
}

private struct LockOwnership: Sendable {
    let fileDescriptor: Int32
}
