#if os(macOS)
import Foundation
import WikiFSCore
import WikiFSEngine
import WikiFSTypes

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
