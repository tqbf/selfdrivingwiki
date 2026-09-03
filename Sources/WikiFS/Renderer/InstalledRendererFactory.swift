#if os(macOS)
import Foundation
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

/// Version-pinned inputs needed to mount one validated installed renderer.
/// The package resource provider exposes bytes only, never its local file URL.
@MainActor
struct InstalledRendererSessionConfiguration {
    let identity: InstalledRendererWebViewIdentity
    let reservation: RendererPackageReservation
    let resourceProvider: any RendererPackageResourceProviding
    let failureRecorder: RendererSessionFailureRecording?
    let inputReader: RendererAuthorizedInputReader?
    let assetReader: RendererAuthorizedAssetReader?
    let externalActivationPolicy: RendererExternalActivationPolicy
    let hostNavigationTargetKinds: Set<RendererHostNavigationTargetKind>
    let hostNavigationRouting: RendererHostNavigationRouting

    init(
        identity: InstalledRendererWebViewIdentity,
        reservation: RendererPackageReservation,
        resourceProvider: any RendererPackageResourceProviding,
        failureRecorder: RendererSessionFailureRecording?,
        inputReader: RendererAuthorizedInputReader?,
        assetReader: RendererAuthorizedAssetReader? = nil,
        externalActivationPolicy: RendererExternalActivationPolicy,
        hostNavigationTargetKinds: Set<RendererHostNavigationTargetKind> = [],
        hostNavigationRouting: RendererHostNavigationRouting = .unavailable
    ) {
        self.identity = identity
        self.reservation = reservation
        self.resourceProvider = resourceProvider
        self.failureRecorder = failureRecorder
        self.inputReader = inputReader
        self.assetReader = assetReader
        self.externalActivationPolicy = externalActivationPolicy
        self.hostNavigationTargetKinds = hostNavigationTargetKinds
        self.hostNavigationRouting = hostNavigationRouting
    }
}

/// The app-side seam for package-backed renderers. This is intentionally a peer
/// of `BuiltInRendererFactoryMap`: built-ins remain a closed native-view map.
@MainActor
struct InstalledRendererFactory {
    typealias SessionFactory = @MainActor (
        InstalledRendererWebViewIdentity,
        @escaping @MainActor (RendererSessionFailure) -> Void,
        InstalledRendererSessionConfiguration
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
        for descriptor: RendererDescriptor,
        inputs: Inputs,
        inputReader: RendererAuthorizedInputReader?,
        assetReader: RendererAuthorizedAssetReader? = nil,
        onFailure: @escaping @MainActor (RendererSessionFailure) -> Void
    ) -> AnyView? {
        guard case let .webPackage(entryPoint) = descriptor.implementation,
              let inputReader,
              let configuration = inputs.configuration(for: descriptor, entryPoint: entryPoint),
              configuration.identity.rendererReference == descriptor.reference,
              configuration.reservation.packageID == descriptor.reference.packageID,
              configuration.reservation.version == descriptor.reference.version,
              entryURLMatches(entryPoint: entryPoint, identity: configuration.identity)
        else { return nil }

        let admissionMaximumInputByteCount = min(
            descriptor.sizeLimits.maximumInputByteCount,
            WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount)
        let admissionMaximumDecodedByteCount = min(
            descriptor.sizeLimits.maximumDecodedByteCount,
            WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount)
        do {
            try inputReader.validateInput(
                maximumInputByteCount: admissionMaximumInputByteCount,
                maximumDecodedByteCount: admissionMaximumDecodedByteCount)
        } catch {
            DebugLog.reader("Installed renderer input was unavailable or exceeded its declared bound; using Source fallback.")
            return nil
        }

        let sessionConfiguration = InstalledRendererSessionConfiguration(
            identity: configuration.identity,
            reservation: configuration.reservation,
            resourceProvider: configuration.resourceProvider,
            failureRecorder: configuration.failureRecorder,
            inputReader: inputReader,
            assetReader: assetReader,
            externalActivationPolicy: descriptor.linkPolicy == .userActivatedExternal ? .enabled : .disabled,
            hostNavigationTargetKinds: descriptor.hostNavigation?.allowedTargetKinds ?? [],
            hostNavigationRouting: inputs.hostNavigationRouting)

        return AnyView(WikiAppWebView(
            identity: configuration.identity,
            makeSession: { identity, reportFailure in
                makeSession(identity, reportFailure, sessionConfiguration)
            },
            onFailure: onFailure))
    }

    private static func makeLiveSession(
        identity: InstalledRendererWebViewIdentity,
        reportFailure: @escaping @MainActor (RendererSessionFailure) -> Void,
        configuration: InstalledRendererSessionConfiguration
    ) -> any WikiAppWebViewSessionControlling {
        WikiAppWebViewSession(
            entryURL: identity.entryURL,
            resourceProvider: configuration.resourceProvider,
            installedPackage: configuration.reservation,
            failureRecorder: configuration.failureRecorder,
            lifecycleFailureHandler: reportFailure,
            bridgeFactory: configuration.inputReader.map { inputReader in
                { sessionID in
                    RendererContentWorldBroker(
                        sessionID: sessionID,
                        capability: .init(rawValue: UUID().uuidString),
                        inputReader: inputReader,
                        assetReader: configuration.assetReader,
                        allowedNavigationTargetKinds: configuration.hostNavigationTargetKinds,
                        routeNavigation: configuration.hostNavigationRouting.route,
                        expectedOrigin: identity.entryURL)
                }
            },
            externalActivationPolicy: configuration.externalActivationPolicy)
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
        let enabledDescriptors: [RendererDescriptor]
        let hostNavigationRouting: RendererHostNavigationRouting
        private let resolveConfiguration: ConfigurationResolver

        init(
            enabledDescriptors: [RendererDescriptor] = [],
            hostNavigationRouting: RendererHostNavigationRouting = .unavailable,
            resolveConfiguration: @escaping ConfigurationResolver
        ) {
            self.enabledDescriptors = enabledDescriptors
            self.hostNavigationRouting = hostNavigationRouting
            self.resolveConfiguration = resolveConfiguration
        }

        static let unavailable = Self(resolveConfiguration: { _, _ in nil })

        func withHostNavigationRouting(_ routing: RendererHostNavigationRouting) -> Self {
            Self(
                enabledDescriptors: enabledDescriptors,
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
