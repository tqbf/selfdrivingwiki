#if os(macOS)
import Foundation
import Observation
import SwiftUI
import WikiFSCore
import WikiFSTypes

// pattern: Imperative Shell

@MainActor
struct RendererHostNavigationRouting {
    private let routeTarget: @MainActor (RendererNavigationTarget) -> Void

    init(route: @escaping @MainActor (RendererNavigationTarget) -> Void) {
        routeTarget = route
    }

    static let unavailable = Self(route: { _ in })

    static func store(_ store: WikiStoreModel) -> Self {
        Self { target in
            switch target {
            case let .page(pageID):
                _ = store.selectPage(byID: pageID)
            case let .source(sourceID):
                _ = store.selectSource(byID: sourceID)
            case let .namedContent(reference):
                let filename = reference.path.split(separator: "/").last.map(String.init) ?? reference.path
                let title = (filename as NSString).deletingPathExtension
                let anchor = reference.subpath.map { String($0.dropFirst()) }
                if store.selectPage(byTitle: title, anchor: anchor) == false {
                    _ = store.selectSource(byDisplayName: title, anchor: anchor)
                }
            }
        }
    }

    func route(_ target: RendererNavigationTarget) { routeTarget(target) }
}

/// Machine-scoped, validated package facts. It deliberately contains no
/// presentation reader: every renderer session receives fresh authority.
@MainActor
struct InstalledRendererSessionConfiguration {
    let identity: InstalledRendererWebViewIdentity
    let reservation: RendererPackageReservation
    let resourceProvider: any RendererPackageResourceProviding
    let failureRecorder: RendererSessionFailureRecording?
}

/// Typed identity for one exact renderer preparation request.
struct RendererSessionPreparationIdentity: Equatable, Sendable {
    let reference: RendererReference
    let input: RendererBridgeInput
}

/// All host facts used to prepare one renderer session. Sibling authority is
/// the exact projection for the rendered source, never an all-source lookup.
@MainActor
struct RendererSessionPreparationRequest {
    let descriptor: RendererDescriptor
    let configuration: InstalledRendererSessionConfiguration
    let input: RendererBridgeInput
    let admittedSource: RendererEmbeddedContent.Source?
    let store: any WikiStore
    let siblingSources: [String: SourceID]
    let sourceExtensions: [SourceID: String]
    let hostNavigationRouting: RendererHostNavigationRouting

    var identity: RendererSessionPreparationIdentity {
        .init(reference: descriptor.reference, input: input)
    }
}

/// The complete, session-private authority consumed by every package host.
/// Closing is idempotent and revokes both byte-reading capabilities together.
@MainActor
final class RendererPreparedSessionAuthority {
    let descriptor: RendererDescriptor
    let configuration: InstalledRendererSessionConfiguration
    let inputReader: RendererAuthorizedInputReader
    let assetReader: RendererAuthorizedAssetReader?
    let allowedNavigationTargetKinds: Set<RendererHostNavigationTargetKind>
    let hostNavigationRouting: RendererHostNavigationRouting
    let externalActivationPolicy: RendererExternalActivationPolicy
    private(set) var isClosed = false

    init(request: RendererSessionPreparationRequest, inputReader: RendererAuthorizedInputReader,
         assetReader: RendererAuthorizedAssetReader?) {
        descriptor = request.descriptor
        configuration = request.configuration
        self.inputReader = inputReader
        self.assetReader = assetReader
        allowedNavigationTargetKinds = request.descriptor.hostNavigation?.allowedTargetKinds ?? []
        hostNavigationRouting = request.hostNavigationRouting
        externalActivationPolicy = request.descriptor.linkPolicy == .userActivatedExternal ? .enabled : .disabled
    }

    func close() {
        guard isClosed == false else { return }
        isClosed = true
        inputReader.close()
        assetReader?.close()
    }
}

/// Host resource limits which are intentionally not package-controlled.
enum RendererSessionHostPolicy {
    static let maximumReadsPerAssetReference = 4
    static let extractorStandardOutputLimit = 256 * 1_024
    static let extractorStandardErrorLimit = 64 * 1_024
}

@MainActor
enum RendererSessionPreparer {
    static func prepare(
        _ request: RendererSessionPreparationRequest,
        executeHelper: @escaping RendererAssetSessionPreparer.HelperExecutor = RendererAssetSessionPreparer.executeHelper
    ) async throws -> RendererPreparedSessionAuthority {
        try Task.checkCancellation()
        let inputReader: RendererAuthorizedInputReader
        if let admittedSource = request.admittedSource {
            inputReader = try RendererAuthorizedInputReader(
                store: request.store, authorizedInput: request.input, admittedSource: admittedSource)
        } else {
            inputReader = RendererAuthorizedInputReader(store: request.store, authorizedInput: request.input)
        }
        let inputLimit = min(request.descriptor.sizeLimits.maximumInputByteCount,
                             WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount)
        let decodedLimit = min(request.descriptor.sizeLimits.maximumDecodedByteCount,
                               WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount)
        try inputReader.validateInput(maximumInputByteCount: inputLimit, maximumDecodedByteCount: decodedLimit)

        var assetReader: RendererAuthorizedAssetReader?
        if let declaration = request.descriptor.assetRead {
            do {
                let extractorURL = RendererPackageScheme.url(
                    packageID: request.configuration.reservation.packageID,
                    version: request.configuration.reservation.version,
                    path: declaration.extractorAsset)
                let extractor = try request.configuration.resourceProvider.resource(for: extractorURL).data
                let primary = try exactPrimaryPayload(for: request)
                let helperResult = try await executeHelper(.init(
                    helperURL: RendererAssetExtractorHelperLocation.locate(),
                    extractorBytes: extractor,
                    entryFunction: declaration.extractorEntryFunction,
                    primaryInput: primary.bytes,
                    maximumExtractorInputBytes: declaration.maximumExtractorInputBytes,
                    maximumExtractorOutputBytes: declaration.maximumExtractorOutputBytes,
                    maximumExtractorExecutionSeconds: declaration.maximumExtractorExecutionSeconds,
                    maximumReferenceCount: declaration.maximumExtractedReferenceCount,
                    stdoutLimit: RendererSessionHostPolicy.extractorStandardOutputLimit,
                    stderrLimit: RendererSessionHostPolicy.extractorStandardErrorLimit))
                try Task.checkCancellation()
                assetReader = RendererAssetSessionPreparer.makeAssetReader(
                    from: helperResult,
                    siblingSources: request.siblingSources,
                    store: request.store,
                    sourceExtensions: request.sourceExtensions,
                    allowedRoles: declaration.allowedRoles,
                    maximumBytesPerAsset: declaration.maximumBytesPerAsset,
                    maximumAggregateSessionBytes: declaration.maximumAggregateSessionBytes,
                    maximumPerRequestReadCount: RendererSessionHostPolicy.maximumReadsPerAssetReference)
            } catch is CancellationError {
                inputReader.close()
                throw CancellationError()
            } catch {
                DebugLog.reader("Renderer asset extraction was unavailable; continuing without asset authority.")
                assetReader = nil
            }
        }
        try Task.checkCancellation()
        return RendererPreparedSessionAuthority(request: request, inputReader: inputReader, assetReader: assetReader)
    }

    private static func exactPrimaryPayload(
        for request: RendererSessionPreparationRequest
    ) throws -> RendererBridgeInputPayload {
        if let source = request.admittedSource {
            return .init(mimeType: source.mimeType.rawValue, bytes: source.bytes)
        }
        switch request.input {
        case .inlineArtifact(let artifact):
            return .init(mimeType: artifact.mimeType.rawValue, bytes: artifact.bytes)
        case .source(let versionID):
            let bytes = try request.store.sourceContent(versionID: versionID)
            return .init(mimeType: "application/octet-stream", bytes: bytes)
        case .markdown:
            let reader = RendererAuthorizedInputReader(store: request.store, authorizedInput: request.input)
            defer { reader.close() }
            return try reader.read(request.input)
        }
    }
}

/// One-task, generation-checked preparation owner for SwiftUI presentation.
@MainActor
@Observable
final class RendererSessionPreparationOwner {
    typealias Preparation = @MainActor (RendererSessionPreparationRequest) async throws -> RendererPreparedSessionAuthority

    private(set) var prepared: RendererPreparedSessionAuthority?
    private(set) var identity: RendererSessionPreparationIdentity?
    private let preparation: Preparation
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?

    init(preparation: @escaping Preparation = { request in
        try await RendererSessionPreparer.prepare(request)
    }) {
        self.preparation = preparation
    }

    func prepare(_ request: RendererSessionPreparationRequest) {
        generation &+= 1
        let requestedGeneration = generation
        let requestedIdentity = request.identity
        task?.cancel()
        prepared?.close()
        prepared = nil
        identity = requestedIdentity
        task = Task {
            do {
                let result = try await preparation(request)
                guard Task.isCancelled == false, generation == requestedGeneration,
                      identity == requestedIdentity else { result.close(); return }
                prepared = result
            } catch {
                guard generation == requestedGeneration, identity == requestedIdentity else { return }
                DebugLog.reader("Renderer session preparation failed; using Source fallback: \(error)")
            }
        }
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        prepared?.close()
        prepared = nil
        identity = nil
    }

}

/// The app-side seam for package-backed renderers. This is intentionally a peer
/// of `BuiltInRendererFactoryMap`: built-ins remain a closed native-view map.
@MainActor
struct InstalledRendererFactory {
    typealias SessionFactory = @MainActor (
        InstalledRendererWebViewIdentity,
        @escaping @MainActor (RendererSessionFailure) -> Void,
        RendererPreparedSessionAuthority
    ) -> any WikiAppWebViewSessionControlling
    typealias ConfigurationResolver = @MainActor (
        RendererDescriptor,
        RendererWebEntryPoint
    ) -> InstalledRendererSessionConfiguration?

    let makeSession: SessionFactory

    init(makeSession: @escaping SessionFactory = Self.makeLiveSession) {
        self.makeSession = makeSession
    }

    static let unavailable = Self()

    func makeView(
        authority: RendererPreparedSessionAuthority,
        onFailure: @escaping @MainActor (RendererSessionFailure) -> Void
    ) -> AnyView? {
        let descriptor = authority.descriptor
        let configuration = authority.configuration
        guard case let .webPackage(entryPoint) = descriptor.implementation,
              configuration.identity.rendererReference == descriptor.reference,
              configuration.reservation.packageID == descriptor.reference.packageID,
              configuration.reservation.version == descriptor.reference.version,
              entryURLMatches(entryPoint: entryPoint, identity: configuration.identity),
              authority.isClosed == false
        else { return nil }

        return AnyView(WikiAppWebView(
            identity: configuration.identity,
            makeSession: { identity, reportFailure in
                makeSession(identity, reportFailure, authority)
            },
            onFailure: onFailure))
    }

    private static func makeLiveSession(
        identity: InstalledRendererWebViewIdentity,
        reportFailure: @escaping @MainActor (RendererSessionFailure) -> Void,
        authority: RendererPreparedSessionAuthority
    ) -> any WikiAppWebViewSessionControlling {
        WikiAppWebViewSession(
            entryURL: identity.entryURL,
            resourceProvider: authority.configuration.resourceProvider,
            installedPackage: authority.configuration.reservation,
            failureRecorder: authority.configuration.failureRecorder,
            lifecycleFailureHandler: reportFailure,
            bridgeFactory: { sessionID in
                RendererContentWorldBroker(
                    sessionID: sessionID,
                    capability: .init(rawValue: UUID().uuidString),
                    inputReader: authority.inputReader,
                    assetReader: authority.assetReader,
                    allowedNavigationTargetKinds: authority.allowedNavigationTargetKinds,
                    routeNavigation: authority.hostNavigationRouting.route,
                    expectedOrigin: identity.entryURL)
            },
            externalActivationPolicy: authority.externalActivationPolicy)
    }

    private func entryURLMatches(
        entryPoint: RendererWebEntryPoint,
        identity: InstalledRendererWebViewIdentity
    ) -> Bool {
        let request: RendererPackageScheme.Request
        do {
            request = try RendererPackageScheme.request(from: identity.entryURL)
        } catch {
            DebugLog.reader("Installed renderer factory rejected an invalid package entry URL.")
            return false
        }
        return request.packageID == identity.rendererReference.packageID &&
            request.version == identity.rendererReference.version &&
            request.path == entryPoint.path
    }

    /// The surrounding app composition root supplies a validated package
    /// snapshot. Until that snapshot is available, returning `nil` preserves the
    /// host-owned Source fallback without opening an unvalidated renderer.
    @MainActor
    struct Inputs {
        let availableDescriptors: [RendererDescriptor]
        let hostNavigationRouting: RendererHostNavigationRouting
        private let resolveConfiguration: ConfigurationResolver

        init(
            availableDescriptors: [RendererDescriptor] = [],
            hostNavigationRouting: RendererHostNavigationRouting = .unavailable,
            resolveConfiguration: @escaping ConfigurationResolver
        ) {
            self.availableDescriptors = availableDescriptors
            self.hostNavigationRouting = hostNavigationRouting
            self.resolveConfiguration = resolveConfiguration
        }

        static let unavailable = Self(resolveConfiguration: { _, _ in nil })

        func withHostNavigationRouting(_ routing: RendererHostNavigationRouting) -> Self {
            Self(
                availableDescriptors: availableDescriptors,
                hostNavigationRouting: routing,
                resolveConfiguration: resolveConfiguration)
        }

        func configuration(
            for descriptor: RendererDescriptor,
            entryPoint: RendererWebEntryPoint
        ) -> InstalledRendererSessionConfiguration? {
            resolveConfiguration(descriptor, entryPoint)
        }

        /// The validated package resource provider for one descriptor, used to
        /// serve `renderer-package:` assets to an in-page iframe on the reader
        /// webview (no separate WKWebView session). Nil when the descriptor has
        /// no web-package entry point or the package snapshot is unavailable.
        func configuration(for descriptor: RendererDescriptor) -> InstalledRendererSessionConfiguration? {
            guard case let .webPackage(entryPoint) = descriptor.implementation else { return nil }
            return resolveConfiguration(descriptor, entryPoint)
        }

        func resourceProvider(
            for descriptor: RendererDescriptor
        ) -> (entryPath: String, provider: any RendererPackageResourceProviding)? {
            guard case let .webPackage(entryPoint) = descriptor.implementation,
                  let configuration = resolveConfiguration(descriptor, entryPoint)
            else { return nil }
            return (entryPoint.path.rawValue, configuration.resourceProvider)
        }
    }
}
#endif
