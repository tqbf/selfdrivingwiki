#if os(macOS)
import Foundation
import WikiFSCore
import WikiFSEngine
import WikiFSTypes

private actor RendererMutationGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var active: UUID?
    private var waiters: [Waiter] = []
    private var cancelled: Set<UUID> = []
    private var closed = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    func acquire(id: UUID) async throws {
        try Task.checkCancellation()
        guard !closed else { throw RendererServicesError.disposed }
        if active == nil {
            active = id
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if cancelled.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                } else if closed {
                    continuation.resume(throwing: RendererServicesError.disposed)
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func release(id: UUID) {
        guard active == id else { return }
        cancelled.remove(id)
        active = nil
        admitNext()
    }

    func closeAndWait() async {
        guard !closed else {
            if active != nil { await waitUntilIdle() }
            return
        }
        closed = true
        let queued = waiters
        waiters.removeAll()
        for waiter in queued {
            waiter.continuation.resume(throwing: RendererServicesError.disposed)
        }
        if active != nil { await waitUntilIdle() }
    }

    private func cancel(id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
        } else if active != id {
            cancelled.insert(id)
        }
    }

    private func admitNext() {
        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            if cancelled.remove(waiter.id) != nil {
                waiter.continuation.resume(throwing: CancellationError())
                continue
            }
            active = waiter.id
            waiter.continuation.resume()
            return
        }
        if active == nil {
            let continuations = closeWaiters
            closeWaiters.removeAll()
            for continuation in continuations { continuation.resume() }
        }
    }

    private func waitUntilIdle() async {
        guard active != nil else { return }
        await withCheckedContinuation { continuation in
            closeWaiters.append(continuation)
        }
    }
}

actor RendererRuntime: RendererServices {
    typealias ValidatorFactory = @Sendable () -> RendererPackageValidator
    typealias ProviderFactory = @Sendable (
        RendererPackageInstallRecord
    ) throws -> any RendererPackageResourceProviding
    typealias BundledPackageSource = @Sendable () -> URL?

    struct ReviewedBundledIdentity: Sendable {
        let packageID: RendererPackageID
        let version: RendererPackageVersion
        let registrationID: RendererRegistrationID
    }

    private enum RetryPolicy {
        static let installationAttemptLimit = 3
    }

    private let machineStore: RendererMachineIndexStore
    private let makeValidator: ValidatorFactory
    private let makeProvider: ProviderFactory
    private let bundledPackageSource: BundledPackageSource
    private let reviewedBundledIdentity: ReviewedBundledIdentity
    private let mutationGate = RendererMutationGate()
    private var admitted = true

    init(
        machineStore: RendererMachineIndexStore,
        makeValidator: @escaping ValidatorFactory,
        makeProvider: @escaping ProviderFactory,
        bundledPackageSource: @escaping BundledPackageSource,
        reviewedBundledIdentity: ReviewedBundledIdentity
    ) {
        self.machineStore = machineStore
        self.makeValidator = makeValidator
        self.makeProvider = makeProvider
        self.bundledPackageSource = bundledPackageSource
        self.reviewedBundledIdentity = reviewedBundledIdentity
    }

    func prepareCurrentRegistry() async throws -> RendererPreparation {
        try requireAdmission()
        let index: RendererMachineIndex
        do { index = try await machineStore.read() }
        catch { throw mapPersistence(error) }
        try requireAdmission()
        return try prepare(index)
    }

    func bootstrapBundledPackage() async throws -> RendererPreparation {
        guard let directory = bundledPackageSource() else {
            throw RendererServicesError.validationFailed
        }
        return try await mutateInstalling(directory, requiresReviewedIdentity: true)
    }

    func installLocalDirectory(_ directory: URL) async throws -> RendererPreparation {
        try await mutateInstalling(directory, requiresReviewedIdentity: false)
    }

    func removePackage(
        packageID: RendererPackageID,
        version: RendererPackageVersion
    ) async throws -> RendererPreparation {
        try await withMutationLease {
            let index: RendererMachineIndex
            do {
                index = try await machineStore.remove(packageID: packageID, version: version)
            } catch {
                throw mapPersistence(error)
            }
            try requireAdmission()
            return try prepare(index)
        }
    }

    func resetSafeMode(
        packageID: RendererPackageID,
        version: RendererPackageVersion
    ) async throws -> RendererPreparation {
        try await withMutationLease {
            let index: RendererMachineIndex
            do {
                index = try await machineStore.resetInstalledRendererSafeMode(
                    packageID: packageID,
                    version: version)
            } catch {
                throw mapPersistence(error)
            }
            try requireAdmission()
            return try prepare(index)
        }
    }

    func dispose() async {
        guard admitted else { return }
        admitted = false
        await mutationGate.closeAndWait()
    }

    private func mutateInstalling(
        _ directory: URL,
        requiresReviewedIdentity: Bool
    ) async throws -> RendererPreparation {
        try await withMutationLease {
            for attempt in 0 ..< RetryPolicy.installationAttemptLimit {
                try requireAdmission()
                let package: ValidatedRendererPackage
                do { package = try makeValidator().validate(directory: directory) }
                catch { throw RendererServicesError.validationFailed }
                if requiresReviewedIdentity {
                    guard package.manifest.packageID == reviewedBundledIdentity.packageID,
                          package.manifest.version == reviewedBundledIdentity.version,
                          package.manifest.descriptors.contains(where: {
                              $0.reference.registrationID == reviewedBundledIdentity.registrationID
                          }) else {
                        throw RendererServicesError.unexpectedBundledIdentity
                    }
                }
                try requireAdmission()
                let current: RendererMachineIndex
                do { current = try await machineStore.read() }
                catch { throw mapPersistence(error) }
                try requireAdmission()
                do {
                    let installed = try await machineStore.activate(
                        package,
                        expectedGeneration: current.generation)
                    try requireAdmission()
                    return try prepare(installed)
                } catch RendererMachineIndexStoreError.staleGeneration {
                    try requireAdmission()
                    if attempt + 1 == RetryPolicy.installationAttemptLimit {
                        throw RendererServicesError.retryLimitReached
                    }
                } catch {
                    throw mapPersistence(error)
                }
            }
            throw RendererServicesError.retryLimitReached
        }
    }

    private func withMutationLease<T: Sendable>(
        _ operation: () async throws -> T
    ) async throws -> T {
        try requireAdmission()
        let leaseID = UUID()
        try await mutationGate.acquire(id: leaseID)
        do {
            try requireAdmission()
            let result = try await operation()
            try requireAdmission()
            await mutationGate.release(id: leaseID)
            try requireAdmission()
            return result
        } catch {
            await mutationGate.release(id: leaseID)
            throw error
        }
    }

    private func prepare(_ index: RendererMachineIndex) throws -> RendererPreparation {
        try requireAdmission()
        var providers: [RendererPackageReservation: any RendererPackageResourceProviding] = [:]
        for record in index.records where record.state == .validated && !record.isSafeModeSuppressed {
            let reservation = RendererPackageReservation(
                packageID: record.packageID,
                version: record.version)
            do { providers[reservation] = try makeProvider(record) }
            catch {
                DebugLog.store("Installed renderer package failed runtime revalidation; keeping Source fallback.")
            }
        }
        let descriptors = index.availableDescriptorProjection.filter { descriptor in
            providers[RendererPackageReservation(
                packageID: descriptor.reference.packageID,
                version: descriptor.reference.version)] != nil
        }
        return RendererPreparation(
            machineIndex: index,
            enabledDescriptors: descriptors,
            providers: providers,
            failureRecorder: machineStore.sessionFailureRecorder())
    }

    private func requireAdmission() throws {
        guard admitted else { throw RendererServicesError.disposed }
        try Task.checkCancellation()
    }

    private func mapPersistence(_ error: any Error) -> RendererServicesError {
        if error is CancellationError { return .disposed }
        if let serviceError = error as? RendererServicesError { return serviceError }
        return .persistenceFailed
    }
}
#endif
