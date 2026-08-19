#if os(macOS)
import Foundation
import WikiFSCore
import WikiFSTypes

/// One authoritative machine-index generation and the providers validated from it.
/// Installed package paths remain private to the provider implementations.
struct RendererPreparation: Sendable {
    let machineIndex: RendererMachineIndex
    let enabledDescriptors: [RendererDescriptor]
    let failureRecorder: RendererSessionFailureRecording

    private let providers: [RendererPackageReservation: any RendererPackageResourceProviding]

    init(
        machineIndex: RendererMachineIndex,
        enabledDescriptors: [RendererDescriptor],
        providers: [RendererPackageReservation: any RendererPackageResourceProviding],
        failureRecorder: @escaping RendererSessionFailureRecording
    ) {
        self.machineIndex = machineIndex
        self.enabledDescriptors = enabledDescriptors
        self.providers = providers
        self.failureRecorder = failureRecorder
    }

    func provider(
        for reservation: RendererPackageReservation
    ) -> (any RendererPackageResourceProviding)? {
        providers[reservation]
    }
}

enum RendererServicesError: Error, Equatable, Sendable, LocalizedError {
    case unavailable
    case disposed
    case validationFailed
    case unexpectedBundledIdentity
    case persistenceFailed
    case retryLimitReached

    var errorDescription: String? {
        switch self {
        case .unavailable: "Renderer services are unavailable."
        case .disposed: "The renderer runtime has stopped."
        case .validationFailed: "The renderer package could not be validated."
        case .unexpectedBundledIdentity: "The bundled renderer identity was unexpected."
        case .persistenceFailed: "The renderer registry could not be updated."
        case .retryLimitReached: "The renderer registry changed too many times."
        }
    }
}

protocol RendererServices: Sendable {
    func prepareCurrentRegistry() async throws -> RendererPreparation
    func bootstrapBundledPackage() async throws -> RendererPreparation
    func installLocalDirectory(_ directory: URL) async throws -> RendererPreparation
    func removePackage(
        packageID: RendererPackageID,
        version: RendererPackageVersion
    ) async throws -> RendererPreparation
    func resetSafeMode(
        packageID: RendererPackageID,
        version: RendererPackageVersion
    ) async throws -> RendererPreparation
}

struct UnavailableRendererServices: RendererServices {
    func prepareCurrentRegistry() async throws -> RendererPreparation {
        throw RendererServicesError.unavailable
    }

    func bootstrapBundledPackage() async throws -> RendererPreparation {
        throw RendererServicesError.unavailable
    }

    func installLocalDirectory(_ directory: URL) async throws -> RendererPreparation {
        throw RendererServicesError.unavailable
    }

    func removePackage(
        packageID: RendererPackageID,
        version: RendererPackageVersion
    ) async throws -> RendererPreparation {
        throw RendererServicesError.unavailable
    }

    func resetSafeMode(
        packageID: RendererPackageID,
        version: RendererPackageVersion
    ) async throws -> RendererPreparation {
        throw RendererServicesError.unavailable
    }
}

/// Stable process facade used before assembly and invalidated before shutdown.
actor MutableRendererServices: RendererServices {
    struct Installation: Hashable, Sendable {
        fileprivate let id = UUID()
    }

    private var installed: any RendererServices = UnavailableRendererServices()
    private var activeInstallation: Installation?
    private var invalidatedInstallations: Set<Installation> = []

    func install(_ services: any RendererServices, for installation: Installation) {
        guard !invalidatedInstallations.contains(installation) else { return }
        installed = services
        activeInstallation = installation
    }

    func invalidate(_ installation: Installation) {
        invalidatedInstallations.insert(installation)
        guard activeInstallation == installation else { return }
        installed = UnavailableRendererServices()
        activeInstallation = nil
    }

    func prepareCurrentRegistry() async throws -> RendererPreparation {
        try await installed.prepareCurrentRegistry()
    }

    func bootstrapBundledPackage() async throws -> RendererPreparation {
        try await installed.bootstrapBundledPackage()
    }

    func installLocalDirectory(_ directory: URL) async throws -> RendererPreparation {
        try await installed.installLocalDirectory(directory)
    }

    func removePackage(
        packageID: RendererPackageID,
        version: RendererPackageVersion
    ) async throws -> RendererPreparation {
        try await installed.removePackage(packageID: packageID, version: version)
    }

    func resetSafeMode(
        packageID: RendererPackageID,
        version: RendererPackageVersion
    ) async throws -> RendererPreparation {
        try await installed.resetSafeMode(packageID: packageID, version: version)
    }
}
#endif
