#if os(macOS)
import Foundation
import Observation
import WikiFSCore
import WikiFSTypes

// pattern: Imperative Shell

/// App-scoped composition root for installed renderer sessions.
///
/// The machine index is authoritative. A package only enters the host snapshot
/// after its installed root has been revalidated and a provider has been built;
/// any failure leaves that package on the existing Source fallback path.
@MainActor
@Observable
final class InstalledRendererHost {
    private let machineStore: RendererMachineIndexStore?
    private let layout: RendererPackageStoreLayout?

    private(set) var machineIndex: RendererMachineIndex?
    private(set) var factory: InstalledRendererFactory = .unavailable
    private(set) var inputs: InstalledRendererFactory.Inputs = .unavailable

    init(
        machineStore: RendererMachineIndexStore?,
        layout: RendererPackageStoreLayout?
    ) {
        self.machineStore = machineStore
        self.layout = layout
    }

    static func production() -> Self {
        do {
            let layout = try RendererPackageStoreLayout.production()
            return Self(machineStore: RendererMachineIndexStore(layout: layout), layout: layout)
        } catch {
            DebugLog.store("Installed renderer host could not resolve its machine store; using Source fallback.")
            return Self(machineStore: nil, layout: nil)
        }
    }

    /// Loads and validates the current machine snapshot without blocking app
    /// launch. This is idempotent and safe to call after package activation or
    /// safe-mode recovery.
    func refresh() async {
        guard let machineStore else {
            apply(nil)
            return
        }
        do {
            apply(try await machineStore.read())
        } catch {
            DebugLog.store("Installed renderer host could not read its machine index; using Source fallback.")
            apply(nil)
        }
    }

    /// Re-enables exactly one installed package version and refreshes the
    /// renderer snapshot. The return value is false when recovery was rejected
    /// or the machine store is unavailable.
    @discardableResult
    func resetInstalledRendererSafeMode(
        packageID: RendererPackageID,
        version: RendererPackageVersion
    ) async -> Bool {
        guard let machineStore else { return false }
        do {
            let next = try await machineStore.resetInstalledRendererSafeMode(
                packageID: packageID,
                version: version)
            apply(next)
            return true
        } catch {
            DebugLog.store("Installed renderer safe-mode recovery was rejected.")
            return false
        }
    }

    /// Convenience for a UI action bound to a selected installed registration;
    /// the package/version identity comes from the typed renderer reference.
    @discardableResult
    func resetInstalledRendererSafeMode(for reference: RendererReference) async -> Bool {
        await resetInstalledRendererSafeMode(
            packageID: reference.packageID,
            version: reference.version)
    }

    private func apply(_ index: RendererMachineIndex?) {
        machineIndex = index
        guard let index, let layout else {
            factory = .unavailable
            inputs = .unavailable
            return
        }

        let providerByReservation = makeProviders(index: index, layout: layout)
        let descriptors = index.availableDescriptorProjection.filter {
            providerByReservation[RendererPackageReservation(
                packageID: $0.reference.packageID,
                version: $0.reference.version)] != nil
        }
        let failureRecorder = machineStore?.sessionFailureRecorder()

        factory = InstalledRendererFactory()
        inputs = InstalledRendererFactory.Inputs(
            enabledDescriptors: descriptors,
            resolveConfiguration: { descriptor, entryPoint in
                let reservation = RendererPackageReservation(
                    packageID: descriptor.reference.packageID,
                    version: descriptor.reference.version)
                guard let provider = providerByReservation[reservation] else { return nil }
                let entryURL = RendererPackageScheme.url(
                    packageID: reservation.packageID,
                    version: reservation.version,
                    path: entryPoint.path)
                return InstalledRendererSessionConfiguration(
                    identity: InstalledRendererWebViewIdentity(
                        rendererReference: descriptor.reference,
                        entryURL: entryURL),
                    reservation: reservation,
                    resourceProvider: provider,
                    failureRecorder: failureRecorder,
                    inputReader: nil,
                    externalActivationPolicy: .disabled)
            })
    }

    private func makeProviders(
        index: RendererMachineIndex,
        layout: RendererPackageStoreLayout
    ) -> [RendererPackageReservation: ValidatedRendererPackageResourceProvider] {
        var providers: [RendererPackageReservation: ValidatedRendererPackageResourceProvider] = [:]
        let validator = RendererPackageValidator(
            packageRoot: layout.root,
            stagingRoot: layout.stagingRoot)
        for record in index.records where record.state == .validated && record.isSafeModeSuppressed == false {
            let reservation = RendererPackageReservation(packageID: record.packageID, version: record.version)
            do {
                let provider = try ValidatedRendererPackageResourceProvider(
                    packageID: record.packageID,
                    version: record.version,
                    expectedPackageHash: record.expectedPackageHash,
                    installedRoot: layout.packageURL(
                        packageID: record.packageID,
                        version: record.version),
                    validator: validator)
                providers[reservation] = provider
            } catch {
                DebugLog.store("Installed renderer package failed host revalidation; keeping Source fallback.")
            }
        }
        return providers
    }
}
#endif
