import Foundation
import Testing
@testable import WikiFSTypes

/// Registry-side claim resolution: the alias → assignment map, deterministic
/// tie-breaking, and suppression/removal semantics (claimants that drop out of
/// the enabled set take their claims with them).
struct PackageFenceClaimRegistryTests {
    private func claimingDescriptor(
        packageID: String = "org.example.viewer",
        registrationID: String,
        alias: String = "d2",
        mime: String = "text/plain",
        priority: Int = 0
    ) throws -> RendererDescriptor {
        try RendererFixtures.webDescriptor(
            packageID: RendererPackageID(rawValue: packageID)!,
            registrationID: RendererRegistrationID(rawValue: registrationID)!,
            embeddingRoles: [.disclosureRow],
            fenceClaims: [RendererFixtures.fenceClaim(alias: alias, mime: mime)],
            priority: priority)
    }

    @Test func snapshotExposesClaimAssignments() throws {
        let descriptor = try claimingDescriptor(registrationID: "viewer")
        let snapshot = try RendererRegistrySnapshot(
            builtInDescriptors: [],
            enabledInstalledDescriptors: [descriptor])
        let alias = try #require(RendererFenceAlias(rawValue: "d2"))
        let claim = try #require(snapshot.fenceClaim(for: alias))
        #expect(claim.reference == descriptor.reference)
        #expect(claim.inlineMIMEType.rawValue == "text/plain")
        #expect(claim.displayName == descriptor.displayName)
    }

    @Test func claimlessSnapshotsCarryAnEmptyMap() throws {
        let snapshot = try RendererRegistrySnapshot(
            builtInDescriptors: [try RendererFixtures.nativeDescriptor()])
        #expect(snapshot.fenceClaims.isEmpty)
    }

    @Test func tieBreakPrefersHigherPriorityThenReferenceOrder() throws {
        let lowPriority = try claimingDescriptor(
            packageID: "org.example.a", registrationID: "viewer", priority: 0)
        let highPriority = try claimingDescriptor(
            packageID: "org.example.b", registrationID: "viewer", priority: 10)
        let alias = try #require(RendererFenceAlias(rawValue: "d2"))

        // Order of construction inputs must not matter.
        let forward = try RendererRegistrySnapshot(
            builtInDescriptors: [],
            enabledInstalledDescriptors: [lowPriority, highPriority])
        let reverse = try RendererRegistrySnapshot(
            builtInDescriptors: [],
            enabledInstalledDescriptors: [highPriority, lowPriority])
        #expect(forward.fenceClaim(for: alias)?.reference == highPriority.reference)
        #expect(reverse.fenceClaim(for: alias)?.reference == highPriority.reference)

        // Equal priorities break by reference ascending.
        let first = try claimingDescriptor(packageID: "org.example.a", registrationID: "viewer")
        let second = try claimingDescriptor(packageID: "org.example.b", registrationID: "viewer")
        let equalPriority = try RendererRegistrySnapshot(
            builtInDescriptors: [],
            enabledInstalledDescriptors: [second, first])
        #expect(equalPriority.fenceClaim(for: alias)?.reference == first.reference)
    }

    @Test func resolverMatchesSnapshotConstruction() throws {
        let builtIn = try claimingDescriptor(registrationID: "viewer")
        let installed = try claimingDescriptor(
            packageID: "org.example.installed",
            registrationID: "other",
            alias: "graph")
        let snapshot = try RendererRegistrySnapshot(
            builtInDescriptors: [],
            enabledInstalledDescriptors: [builtIn, installed])
        #expect(snapshot.fenceClaims == RendererFenceClaimResolver.resolve(
            builtInDescriptors: [],
            enabledInstalledDescriptors: [builtIn, installed]))
    }

    @Test func removedOrSuppressedClaimantsDropTheirClaims() throws {
        // Suppression is modeled by the caller: a suppressed package never
        // enters the enabled descriptor list, so its claims vanish with it and
        // reappear exactly when it returns.
        let alias = try #require(RendererFenceAlias(rawValue: "d2"))
        let claimant = try claimingDescriptor(
            packageID: "org.example.installed", registrationID: "viewer")

        let present = try RendererRegistrySnapshot(
            builtInDescriptors: [],
            enabledInstalledDescriptors: [claimant])
        #expect(present.fenceClaim(for: alias) != nil)

        let suppressed = try RendererRegistrySnapshot(
            builtInDescriptors: [],
            enabledInstalledDescriptors: [])
        #expect(suppressed.fenceClaim(for: alias) == nil)
    }
}
