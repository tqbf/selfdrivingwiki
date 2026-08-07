#if os(macOS)
import Foundation
import SwiftUI
import WikiFSCore
import WikiFSTypes

// pattern: Imperative Shell

/// Version-pinned inputs needed to mount one validated installed renderer.
/// The package resource provider exposes bytes only, never its local file URL.
@MainActor
struct InstalledRendererSessionConfiguration {
    let identity: InstalledRendererWebViewIdentity
    let reservation: RendererPackageReservation
    let resourceProvider: any RendererPackageResourceProviding
    let failureRecorder: RendererSessionFailureRecording?
    let inputReader: RendererAuthorizedInputReader?
    let externalActivationPolicy: RendererExternalActivationPolicy
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

        do {
            try inputReader.validateInput(maximumByteCount: descriptor.sizeLimits.maximumInputByteCount)
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
            externalActivationPolicy: descriptor.linkPolicy == .userActivatedExternal ? .enabled : .disabled)

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
        private let resolveConfiguration: ConfigurationResolver

        init(
            enabledDescriptors: [RendererDescriptor] = [],
            resolveConfiguration: @escaping ConfigurationResolver
        ) {
            self.enabledDescriptors = enabledDescriptors
            self.resolveConfiguration = resolveConfiguration
        }

        static let unavailable = Self(resolveConfiguration: { _, _ in nil })

        func configuration(
            for descriptor: RendererDescriptor,
            entryPoint: RendererWebEntryPoint
        ) -> InstalledRendererSessionConfiguration? {
            resolveConfiguration(descriptor, entryPoint)
        }
    }
}
#endif
