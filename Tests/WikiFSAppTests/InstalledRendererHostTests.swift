#if os(macOS)
import Testing
import WikiFSCore
@testable import WikiFS

@Suite("Installed renderer host")
@MainActor
struct InstalledRendererHostTests {
    @Test("an unavailable machine store preserves the Source fallback")
    func unavailableMachineStorePreservesSourceFallback() async throws {
        let host = InstalledRendererHost(machineStore: nil, layout: nil)
        let packageID = try RendererPackageID(validating: "org.example.host")
        let version = try RendererPackageVersion(validating: "1.0.0")

        await host.refresh()

        #expect(host.machineIndex == nil)
        #expect(host.inputs.enabledDescriptors.isEmpty)
        let resetSucceeded = await host.resetInstalledRendererSafeMode(
            packageID: packageID,
            version: version)
        #expect(resetSucceeded == false)
    }

    @Test("host recovery is scoped by the typed renderer reference")
    func recoveryUsesTypedReference() async throws {
        let host = InstalledRendererHost(machineStore: nil, layout: nil)
        let reference = RendererReference(
            packageID: try RendererPackageID(validating: "org.example.host"),
            version: try RendererPackageVersion(validating: "1.0.0"),
            registrationID: try RendererRegistrationID(validating: "installed"))

        #expect(await host.resetInstalledRendererSafeMode(for: reference) == false)
    }
}
#endif
