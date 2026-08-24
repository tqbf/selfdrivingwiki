#if os(macOS)
import Foundation
import WikiFSCore
import WikiFSTypes

/// One authoritative machine-index generation and its validated providers.
/// Installed package paths remain private to provider implementations.
public struct RendererPreparation: Sendable {
    public let machineIndex: RendererMachineIndex
    public let enabledDescriptors: [RendererDescriptor]
    public let failureRecorder: RendererSessionFailureRecording

    private let providers: [RendererPackageReservation: any RendererPackageResourceProviding]

    public init(
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

    public func provider(
        for reservation: RendererPackageReservation
    ) -> (any RendererPackageResourceProviding)? {
        providers[reservation]
    }
}

public enum RendererServicesError: Error, Equatable, Sendable, LocalizedError {
    case unavailable
    case disposed
    case validationFailed
    case unexpectedBundledIdentity
    case persistenceFailed
    case retryLimitReached

    public var errorDescription: String? {
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

public protocol RendererServices: Sendable {
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

public struct UnavailableRendererServices: RendererServices {
    public init() {}

    public func prepareCurrentRegistry() async throws -> RendererPreparation {
        throw RendererServicesError.unavailable
    }

    public func bootstrapBundledPackage() async throws -> RendererPreparation {
        throw RendererServicesError.unavailable
    }

    public func installLocalDirectory(_ directory: URL) async throws -> RendererPreparation {
        throw RendererServicesError.unavailable
    }

    public func removePackage(
        packageID: RendererPackageID,
        version: RendererPackageVersion
    ) async throws -> RendererPreparation {
        throw RendererServicesError.unavailable
    }

    public func resetSafeMode(
        packageID: RendererPackageID,
        version: RendererPackageVersion
    ) async throws -> RendererPreparation {
        throw RendererServicesError.unavailable
    }
}
#endif
