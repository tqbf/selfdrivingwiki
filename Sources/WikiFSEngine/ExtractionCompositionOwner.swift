#if os(macOS)
import Foundation
import WikiFSCore

public protocol ExtractionRuntimeOwning: Sendable {
    var services: any ExtractionServices { get }
    func dispose() async throws
}

extension ExtractionRuntimeHandle: ExtractionRuntimeOwning {}

/// Owns one process extraction runtime and its asynchronous startup task.
/// The stable facade remains usable while assembly is pending or fails.
public actor ExtractionCompositionOwner {
    public typealias AssemblyFactory = @Sendable () async throws -> any ExtractionRuntimeOwning

    public nonisolated let services: MutableExtractionServices

    private enum State {
        case idle
        case starting(Task<Void, Never>, MutableExtractionServices.Installation)
        case installed(any ExtractionRuntimeOwning, MutableExtractionServices.Installation)
        case stopped
    }

    private let assemble: AssemblyFactory
    private var state: State = .idle
    private var startupError: (any Error)?

    public init(
        services: MutableExtractionServices = MutableExtractionServices(),
        assemble: @escaping AssemblyFactory
    ) {
        self.services = services
        self.assemble = assemble
    }

    public func start() {
        guard case .idle = state else { return }
        let installation = MutableExtractionServices.Installation()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runStartup(installation: installation)
        }
        state = .starting(task, installation)
    }

    public func awaitSettled() async {
        guard case .starting(let task, _) = state else { return }
        await task.value
    }

    public func failureDescription() -> String? {
        startupError.map(String.init(describing:))
    }

    public func shutdown() async {
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
            do {
                try await handle.dispose()
            } catch {
                DebugLog.extraction("ExtractionCompositionOwner: runtime disposal failed: \(error)")
            }
        case .stopped:
            return
        }
    }

    private func runStartup(
        installation: MutableExtractionServices.Installation
    ) async {
        do {
            let handle = try await assemble()
            guard case .starting(_, let currentInstallation) = state,
                  currentInstallation == installation,
                  !Task.isCancelled else {
                await disposeLate(handle)
                return
            }
            await services.install(handle.services, for: installation)
            guard case .starting(_, let currentInstallation) = state,
                  currentInstallation == installation,
                  !Task.isCancelled else {
                await services.invalidate(installation)
                await disposeLate(handle)
                return
            }
            state = .installed(handle, installation)
            startupError = nil
        } catch is CancellationError {
            // Shutdown owns cancellation and leaves the facade unavailable.
        } catch {
            guard case .starting(_, let currentInstallation) = state,
                  currentInstallation == installation else { return }
            startupError = error
            state = .idle
            DebugLog.extraction("ExtractionCompositionOwner: runtime assembly failed: \(error)")
        }
    }

    private func disposeLate(_ handle: any ExtractionRuntimeOwning) async {
        do {
            try await handle.dispose()
        } catch {
            DebugLog.extraction("ExtractionCompositionOwner: late runtime cleanup failed: \(error)")
        }
    }
}
#endif
