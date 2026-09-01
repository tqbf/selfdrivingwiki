#if os(macOS)
import Foundation
import Observation
import WikiFSCore
import WikiFSEngine
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
    private let services: any RendererServices

    private(set) var machineIndex: RendererMachineIndex?
    private(set) var factory: InstalledRendererFactory = .unavailable
    private(set) var inputs: InstalledRendererFactory.Inputs = .unavailable

    init(services: any RendererServices) {
        self.services = services
    }

    /// Loads one immutable renderer preparation. A failed refresh clears the
    /// installed snapshot so Source fallback remains authoritative.
    func refresh() async {
        do { apply(try await services.prepareCurrentRegistry()) }
        catch {
            DebugLog.store("Installed renderer host could not prepare its machine index; using Source fallback.")
            applyUnavailable()
        }
    }

    @discardableResult
    func installRendererDirectory(_ directory: URL) async -> Bool {
        do {
            apply(try await services.installLocalDirectory(directory))
            return true
        } catch {
            DebugLog.store("Installed renderer directory was rejected; keeping the current renderer snapshot.")
            return false
        }
    }

    @discardableResult
    func removeRenderer(packageID: RendererPackageID, version: RendererPackageVersion) async -> Bool {
        do {
            apply(try await services.removePackage(packageID: packageID, version: version))
            return true
        } catch {
            DebugLog.store("Installed renderer removal could not complete; keeping the current machine record.")
            return false
        }
    }

    @discardableResult
    func resetInstalledRendererSafeMode(
        packageID: RendererPackageID,
        version: RendererPackageVersion
    ) async -> Bool {
        do {
            apply(try await services.resetSafeMode(packageID: packageID, version: version))
            return true
        } catch {
            DebugLog.store("Installed renderer safe-mode recovery was rejected.")
            return false
        }
    }

    @discardableResult
    func resetInstalledRendererSafeMode(for reference: RendererReference) async -> Bool {
        await resetInstalledRendererSafeMode(
            packageID: reference.packageID,
            version: reference.version)
    }

    func apply(_ preparation: RendererPreparation) {
        machineIndex = preparation.machineIndex
        factory = InstalledRendererFactory()
        inputs = InstalledRendererFactory.Inputs(
            enabledDescriptors: preparation.enabledDescriptors,
            resolveConfiguration: { descriptor, entryPoint in
                let reservation = RendererPackageReservation(
                    packageID: descriptor.reference.packageID,
                    version: descriptor.reference.version)
                guard let provider = preparation.provider(for: reservation) else { return nil }
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
                    failureRecorder: preparation.failureRecorder,
                    inputReader: nil,
                    externalActivationPolicy: .disabled)
            })
    }

    private func applyUnavailable() {
        machineIndex = nil
        factory = .unavailable
        inputs = .unavailable
    }
}
#endif
