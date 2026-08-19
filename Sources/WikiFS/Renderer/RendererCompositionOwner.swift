#if os(macOS)
import Foundation
import Synchronization
import WikiFSTypes

final class RendererPublicationAdmission: Sendable {
    private let admitted = Mutex(true)

    func invalidate() {
        admitted.withLock { $0 = false }
    }

    @MainActor
    func publish(_ body: () -> Void) -> Bool {
        admitted.withLock { admitted in
            guard admitted else { return false }
            admitted = false
            body()
            return true
        }
    }
}

struct RendererStartupPublication: Sendable {
    let preparation: RendererPreparation
    private let admission: RendererPublicationAdmission

    init(preparation: RendererPreparation, admission: RendererPublicationAdmission) {
        self.preparation = preparation
        self.admission = admission
    }

    @MainActor
    @discardableResult
    func publish(to host: InstalledRendererHost) -> Bool {
        admission.publish { host.apply(preparation) }
    }
}

/// Owns renderer assembly, bundled bootstrap, publication admission, and shutdown.
actor RendererCompositionOwner {
    typealias AssemblyFactory = @Sendable () async throws -> any RendererRuntimeOwning

    nonisolated let services: MutableRendererServices

    private enum State {
        case idle
        case starting(Task<Void, Never>, MutableRendererServices.Installation)
        case installed(any RendererRuntimeOwning, MutableRendererServices.Installation)
        case stopped
    }

    private let assemble: AssemblyFactory
    private let publicationAdmission = RendererPublicationAdmission()
    private var state: State = .idle
    private var startupPreparation: RendererPreparation?
    private var startupError: (any Error)?

    init(
        services: MutableRendererServices = MutableRendererServices(),
        assemble: @escaping AssemblyFactory
    ) {
        self.services = services
        self.assemble = assemble
    }

    func start() {
        guard case .idle = state else { return }
        let installation = MutableRendererServices.Installation()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runStartup(installation: installation)
        }
        state = .starting(task, installation)
    }

    func awaitSettled() async {
        guard case .starting(let task, _) = state else { return }
        await task.value
    }

    func consumeStartupPreparation() -> RendererStartupPublication? {
        guard case .installed = state, let startupPreparation else { return nil }
        self.startupPreparation = nil
        return RendererStartupPublication(
            preparation: startupPreparation,
            admission: publicationAdmission)
    }

    func failureDescription() -> String? {
        startupError.map(String.init(describing:))
    }

    func shutdown() async {
        publicationAdmission.invalidate()
        startupPreparation = nil
        switch state {
        case .idle:
            state = .stopped
        case .starting(let task, let installation):
            state = .stopped
            await services.invalidate(installation)
            task.cancel()
            await task.value
        case .installed(let handle, let installation):
            state = .stopped
            await services.invalidate(installation)
            await dispose(handle, late: false)
        case .stopped:
            return
        }
    }

    private func runStartup(
        installation: MutableRendererServices.Installation
    ) async {
        var assembledHandle: (any RendererRuntimeOwning)?
        do {
            let handle = try await assemble()
            assembledHandle = handle
            guard isAdmitted(installation) else {
                await dispose(handle, late: true)
                return
            }
            await services.install(handle.services, for: installation)
            guard isAdmitted(installation) else {
                await services.invalidate(installation)
                await dispose(handle, late: true)
                return
            }
            let preparation = try await handle.services.bootstrapBundledPackage()
            guard isAdmitted(installation) else {
                await services.invalidate(installation)
                await dispose(handle, late: true)
                return
            }
            startupPreparation = preparation
            state = .installed(handle, installation)
            assembledHandle = nil
            startupError = nil
        } catch is CancellationError {
            if let assembledHandle {
                await services.invalidate(installation)
                await dispose(assembledHandle, late: true)
            }
            // Shutdown owns cancellation and leaves the facade unavailable.
        } catch {
            guard isAdmitted(installation) else {
                if let assembledHandle { await dispose(assembledHandle, late: true) }
                return
            }
            await services.invalidate(installation)
            if let assembledHandle { await dispose(assembledHandle, late: true) }
            startupError = error
            state = .idle
            DebugLog.store("Renderer composition startup failed; using Source fallback.")
        }
    }

    private func isAdmitted(_ installation: MutableRendererServices.Installation) -> Bool {
        guard case .starting(_, let current) = state else { return false }
        return current == installation && !Task.isCancelled
    }

    private func dispose(_ handle: any RendererRuntimeOwning, late: Bool) async {
        do { try await handle.dispose() }
        catch {
            let phase = late ? "late" : "shutdown"
            DebugLog.store("Renderer composition \(phase) cleanup failed.")
        }
    }
}
#endif
