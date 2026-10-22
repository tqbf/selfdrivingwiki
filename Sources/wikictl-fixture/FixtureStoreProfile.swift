import Foundation
import WikiFSCore

#if os(macOS)
import Cordis
import CordisLoader
import WikiFSEngine

// The in-process store profile boot for `wikictl-fixture` — moved here from
// WikiCtlCore when the fixture-binary split landed (plans/cli-domain-
// commands.md §"The fixture binary"). The shipping `wikictl` never boots a
// local store: every registry-selected command rides the daemon. THIS binary
// exists to open one explicit fixture database headlessly, so the profile boot
// lives beside the explicit-database selection it serves.

public enum CLIStoreProfileError: Error {
    case incompatibleStore
    case operationAndCleanup(operation: any Error, cleanup: any Error)
}

/// Boots the CLI's headless Cordis profile over ONE explicit fixture database
/// (`wikictl-fixture`'s only store surface), runs the operation against the
/// composed `GRDBWikiStore`, and always shuts the profile down — a shutdown
/// failure never masks the operation's own error.
public struct CLIStoreProfile: Sendable {
    public struct Request: Sendable {
        public let databaseURL: URL
        public let wikiID: WikiID
        public let containerDirectory: URL

        public init(databaseURL: URL, wikiID: WikiID, containerDirectory: URL) {
            self.databaseURL = databaseURL
            self.wikiID = wikiID
            self.containerDirectory = containerDirectory
        }
    }

    public typealias Boot = @Sendable (Request) async throws -> BootedProfile

    private let boot: Boot

    public var resolveRendererCatalog: @Sendable () async -> RegisteredRendererSourceTypes =
        { await RendererCatalogResolution.productionSourceTypes() }

    public init() {
        self.boot = CLIStoreProfile.productionBoot
    }

    public init(boot: @escaping Boot) {
        self.boot = boot
    }

    public func withStore<Result>(
        request: Request,
        operation: (GRDBWikiStore) async throws -> Result
    ) async throws -> Result {
        let profile = try await boot(request)
        let operationResult: Swift.Result<Result, any Error>
        do {
            let service = try await profile.context.require(StoreServiceKeys.store)
            guard let store = service as? GRDBWikiStore else {
                throw CLIStoreProfileError.incompatibleStore
            }
            // Headless fixture profile: project source-type claims from the
            // authoritative machine index (WebKit-free, best-effort).
            store.registeredRendererSourceTypes = await resolveRendererCatalog()
            operationResult = .success(try await operation(store))
        } catch {
            operationResult = .failure(error)
        }

        do {
            try await profile.shutdown()
        } catch {
            switch operationResult {
            case .success:
                throw error
            case .failure(let operationError):
                throw CLIStoreProfileError.operationAndCleanup(
                    operation: operationError,
                    cleanup: error)
            }
        }

        return try operationResult.get()
    }

    public static func withStore<Result>(
        databaseURL: URL,
        wikiID: WikiID,
        containerDirectory: URL,
        operation: (GRDBWikiStore) async throws -> Result
    ) async throws -> Result {
        try await CLIStoreProfile().withStore(
            request: Request(
                databaseURL: databaseURL,
                wikiID: wikiID,
                containerDirectory: containerDirectory),
            operation: operation)
    }

    private static func productionBoot(_ request: Request) async throws -> BootedProfile {
        try await CordisBoot.boot(.init(
            catalog: try CLIPluginCatalog.build(),
            layers: [PatchFile(entries: try ProductionProfiles.cli(
                databaseURL: request.databaseURL,
                wikiID: request.wikiID,
                homeDirectory: request.containerDirectory))]))
    }

}

#else
public enum CLIStoreProfileError: Error {
    case incompatibleStore
    case operationAndCleanup(operation: any Error, cleanup: any Error)
}

public enum CLIStoreProfile {
    /// The catalog resolver for headless store opens. Injectable so tests can
    /// prove the wiring without machine package state.
    public static var resolveRendererCatalog: @Sendable () async -> RegisteredRendererSourceTypes =
        { await RendererCatalogResolution.productionSourceTypes() }

    public static func withStore<Result>(
        databaseURL: URL,
        wikiID: WikiID,
        containerDirectory: URL,
        operation: (GRDBWikiStore) async throws -> Result
    ) async throws -> Result {
        let service = try StoreBackend.current.makeStore(databaseURL: databaseURL)
        guard let store = service as? GRDBWikiStore else {
            throw CLIStoreProfileError.incompatibleStore
        }
        // Headless profiles project source-type claims straight from the
        // authoritative machine index (WebKit-free). A failure keeps the
        // empty catalog and never blocks the command.
        store.registeredRendererSourceTypes = await resolveRendererCatalog()
        return try await operation(store)
    }
}
#endif
