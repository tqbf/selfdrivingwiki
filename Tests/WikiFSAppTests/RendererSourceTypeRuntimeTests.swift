#if os(macOS)
import Foundation
import Testing
import WikiFSTypes
@testable import WikiFSCore
@testable import WikiFS

/// AC.2: the active renderer runtime projects only validated, compatible,
/// provider-backed, non-suppressed source-type claims. Install, removal,
/// safe-mode suppression, and reset change the catalog without touching wiki
/// data.
@Suite("Renderer source-type runtime", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct RendererSourceTypeRuntimeTests {
    @Test func activeDescriptorsProjectClaims() async throws {
        let fixture = try Fixture(name: "project")
        defer { fixture.cleanup() }
        let handle = try await fixture.assembly.assemble()
        defer { Task { try? await handle.dispose() } }

        let preparation = try await handle.services.installLocalDirectory(
            mermaidPackageDirectory)
        let catalog = preparation.registeredSourceTypes
        #expect(catalog.isEmpty == false)
        let claim = try #require(catalog.claims.first { $0.reference.packageID.rawValue == "org.selfdrivingwiki.mermaid-readonly" })
        #expect(claim.canonicalMIMEType.rawValue == "text/vnd.mermaid")
        #expect(claim.displayName == "Mermaid")
        #expect(claim.filenameExtensions.contains(try .init(validating: "mmd")))
        #expect(claim.mimeAliases.contains(try .init(validating: "application/vnd.chipnuts.karaoke-mmd")))
    }

    @Test func suppressionAndRemovalDropClaims() async throws {
        let fixture = try Fixture(name: "drop")
        defer { fixture.cleanup() }
        let handle = try await fixture.assembly.assemble()
        defer { Task { try? await handle.dispose() } }

        _ = try await handle.services.installLocalDirectory(mermaidPackageDirectory)
        let mermaidMIME = try RendererMIMEType(validating: "text/vnd.mermaid")

        // Safe-mode suppression drops the claim from preparation.
        try await fixture.suppressMermaid()
        let afterSuppression = try await handle.services.prepareCurrentRegistry()
        #expect(afterSuppression.registeredSourceTypes.containsDeclaredMIME(mermaidMIME) == false)

        // Reset restores it.
        _ = try await handle.services.resetSafeMode(
            packageID: .init(validating: "org.selfdrivingwiki.mermaid-readonly"),
            version: .init(validating: "1.1.0"))
        let afterReset = try await handle.services.prepareCurrentRegistry()
        #expect(afterReset.registeredSourceTypes.containsDeclaredMIME(mermaidMIME))

        // Removal drops it again.
        _ = try await handle.services.removePackage(
            packageID: .init(validating: "org.selfdrivingwiki.mermaid-readonly"),
            version: .init(validating: "1.1.0"))
        let afterRemoval = try await handle.services.prepareCurrentRegistry()
        #expect(afterRemoval.registeredSourceTypes.isEmpty)
    }

    @Test func resetRestoresClaims() async throws {
        let fixture = try Fixture(name: "reset")
        defer { fixture.cleanup() }
        let handle = try await fixture.assembly.assemble()
        defer { Task { try? await handle.dispose() } }

        _ = try await handle.services.installLocalDirectory(mermaidPackageDirectory)
        try await fixture.suppressMermaid()
        _ = try await handle.services.resetSafeMode(
            packageID: .init(validating: "org.selfdrivingwiki.mermaid-readonly"),
            version: .init(validating: "1.1.0"))
        let preparation = try await handle.services.prepareCurrentRegistry()
        #expect(preparation.registeredSourceTypes.containsDeclaredMIME(
            try .init(validating: "text/vnd.mermaid")))
    }

    @Test func lifecycleDoesNotWriteWikiStore() async throws {
        let fixture = try Fixture(name: "lifecycle")
        defer { fixture.cleanup() }
        let handle = try await fixture.assembly.assemble()
        defer { Task { try? await handle.dispose() } }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("source-type-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try GRDBWikiStore(databaseURL: directory.appendingPathComponent("WikiFS.sqlite"))
        let source = try store.addSource(filename: "diagram.mmd", data: Data("graph TD\n A-->B".utf8))
        let before = try store.getSource(id: source.id)

        // Install and removal preparations must not touch wiki data.
        _ = try await handle.services.installLocalDirectory(mermaidPackageDirectory)
        let preparation = try await handle.services.prepareCurrentRegistry()
        let host = InstalledRendererHost(services: handle.services)
        host.apply(preparation)
        let afterInstall = try store.getSource(id: source.id)
        _ = try await handle.services.removePackage(
            packageID: .init(validating: "org.selfdrivingwiki.mermaid-readonly"),
            version: .init(validating: "1.1.0"))
        let afterRemoval = try store.getSource(id: source.id)

        #expect(before.mimeType == "text/plain")
        #expect(afterInstall.mimeType == before.mimeType)
        #expect(afterRemoval.mimeType == before.mimeType)
        #expect(afterRemoval.byteSize == before.byteSize)
    }

    // MARK: - Fixtures

    private var mermaidPackageDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("RendererPackages/Mermaid", isDirectory: true)
    }

    private struct Fixture: Sendable {
        let root: URL
        let assembly: RendererRuntimeFactory
        let layout: RendererPackageStoreLayout

        init(name: String) throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("renderer-source-type-runtime-\(name)-\(UUID().uuidString)",
                    isDirectory: true)
            layout = try RendererPackageStoreLayout(appGroupContainerRoot: root)
            assembly = RendererRuntimeFactory(layout: layout)
        }

        /// Flips safe-mode suppression on the installed Mermaid record
        /// through the machine index's generation-CAS mutation.
        func suppressMermaid() async throws {
            let machineStore = RendererMachineIndexStore(
                layout: layout,
                reservedFenceAliases: BuiltInRendererDescriptors.reservedFenceAliases)
            let index = try await machineStore.read()
            _ = try await machineStore.mutate(expectedGeneration: index.generation) { records, _ in
                for position in records.indices
                where records[position].packageID.rawValue == "org.selfdrivingwiki.mermaid-readonly" {
                    let record = records[position]
                    records[position] = try RendererPackageInstallRecord(
                        packageID: record.packageID,
                        version: record.version,
                        expectedPackageHash: record.expectedPackageHash,
                        state: record.state,
                        reservedAt: record.reservedAt,
                        updatedAt: record.updatedAt,
                        diagnostic: record.diagnostic,
                        rollbackCandidate: record.rollbackCandidate,
                        isSafeModeSuppressed: true,
                        validatedDescriptors: record.validatedDescriptors)
                }
            }
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
#endif
