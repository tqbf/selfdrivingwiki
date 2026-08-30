#if os(macOS)
import Foundation
import Testing
import WikiFSCore
import WikiFSTypes
@testable import WikiFSEngine

/// The reviewed overlay lets the application and the daemon run the reviewed
/// Defuddle and pdf2md packages before the application publishes them into the
/// durable machine catalog.
///
/// These tests run the real committed payload through the real admission path,
/// so a regenerated package, a stale compiled identity, or a tampered bundle
/// fails here rather than on a user's Mac.
@Suite("Reviewed extractor overlay", .serialized, .timeLimit(.minutes(5)))
struct ReviewedExtractorOverlayTests {
    /// The compiled identities are golden constants. Validation recomputes the
    /// revision from the committed bytes, so a regenerated package whose digest
    /// changed fails here with the value to compile in.
    @Test func compiledIdentitiesMatchTheCommittedPayload() throws {
        let environment = try Environment.make()
        defer { environment.cleanup() }

        let overlay = ReviewedExtractorPackageOverlay.resolve(
            layout: environment.layout,
            explicitRoot: Environment.reviewedPackagesRoot)

        #expect(overlay.diagnostics.isEmpty)
        #expect(overlay.records.count == ReviewedExtractorPackages.all.count)
        for package in ReviewedExtractorPackages.all {
            #expect(
                overlay.roots[package.revision] != nil,
                """
                Reviewed package \(package.packageID.rawValue) did not reproduce its \
                compiled revision. Regenerate with scripts/sync-extractor-packages.sh, \
                then update ReviewedExtractorPackages with the validated digest.
                """)
        }
    }

    /// The daemon-before-bootstrap case: nothing is installed, yet both reviewed
    /// extractors are available.
    @Test func reviewedPackagesRunWithAnEmptyDurableCatalog() async throws {
        let environment = try Environment.make()
        defer { environment.cleanup() }

        let context = try await ProcessExtractionContext.assemble(
            layout: environment.layout,
            reviewedPackageRoot: Environment.reviewedPackagesRoot)
        _ = await context.reconcileNow()

        for package in ReviewedExtractorPackages.all {
            #expect(await context.registry.containsRevision(package.revision))
        }
        await context.shutdown()
    }

    /// Settings projects reviewed choices from the validated overlay before
    /// activation. The host catalog contributes no package choices.
    @Test func reviewedOverlayProvidesPreActivationRouteChoices() async throws {
        let environment = try Environment.make()
        defer { environment.cleanup() }

        let context = try await ProcessExtractionContext.assemble(
            layout: environment.layout,
            reviewedPackageRoot: Environment.reviewedPackagesRoot)
        let snapshots = context.availableRegistrationSnapshots()
        await context.shutdown()

        #expect(snapshots.count == ReviewedExtractorPackages.all.count)
        #expect(snapshots.allSatisfy { $0.sourceCategory == .reviewedPackage })
        #expect(Set(snapshots.map(\.reference.revision)) == Set(ReviewedExtractorPackages.all.map(\.revision)))
        #expect(
            ExtractorRouteHostCatalog.choices(for: .canonicalPDF)
                .contains { $0.category == .reviewedPackage } == false)
        #expect(
            ExtractorRouteHostCatalog.choices(for: .canonicalHTML)
                .contains { $0.category == .reviewedPackage } == false)
    }

    /// Running reviewed packages must not make a reader process a catalog
    /// writer. The durable catalog stays empty.
    @Test func reviewedOverlayNeverWritesTheDurableCatalog() async throws {
        let environment = try Environment.make()
        defer { environment.cleanup() }

        let durable = ExtractorPackageCatalogReader(layout: environment.layout)
        let before = try durable.read()

        let context = try await ProcessExtractionContext.assemble(
            layout: environment.layout,
            reviewedPackageRoot: Environment.reviewedPackagesRoot)
        _ = await context.reconcileNow()
        let after = try durable.read()
        await context.shutdown()

        #expect(after.generation == before.generation)
        #expect(after.records.isEmpty)
    }

    /// Bundled bytes are trusted only through their compiled identity. A changed
    /// payload produces a different digest and is refused.
    @Test func tamperedBundledPayloadIsRejected() throws {
        let environment = try Environment.make()
        defer { environment.cleanup() }

        let tamperedRoot = environment.root
            .appendingPathComponent("tampered", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tamperedRoot, withIntermediateDirectories: true)
        let source = Environment.reviewedPackagesRoot
            .appendingPathComponent("Defuddle", isDirectory: true)
        let copy = tamperedRoot.appendingPathComponent("Defuddle", isDirectory: true)
        try FileManager.default.copyItem(at: source, to: copy)

        let entry = copy.appendingPathComponent("bin/defuddle-extractor.js")
        let original = try Data(contentsOf: entry)
        try (original + Data("\n// tampered\n".utf8)).write(to: entry)

        let overlay = ReviewedExtractorPackageOverlay.resolve(
            layout: environment.layout,
            explicitRoot: tamperedRoot,
            packages: [ReviewedExtractorPackages.defuddle])

        #expect(overlay.roots.isEmpty)
        #expect(overlay.records.isEmpty)
        #expect(overlay.diagnostics.count == 1)
    }

    /// One unusable reviewed package never blocks the other.
    @Test func oneMissingReviewedPackageLeavesTheOtherAvailable() throws {
        let environment = try Environment.make()
        defer { environment.cleanup() }

        let partialRoot = environment.root
            .appendingPathComponent("partial", isDirectory: true)
        try FileManager.default.createDirectory(
            at: partialRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: Environment.reviewedPackagesRoot
                .appendingPathComponent("Pdf2md", isDirectory: true),
            to: partialRoot.appendingPathComponent("Pdf2md", isDirectory: true))

        let overlay = ReviewedExtractorPackageOverlay.resolve(
            layout: environment.layout,
            explicitRoot: partialRoot)

        #expect(overlay.roots[ReviewedExtractorPackages.pdf2md.revision] != nil)
        #expect(overlay.roots[ReviewedExtractorPackages.defuddle.revision] == nil)
        // Four reviewed packages ship; three are absent from the partial root.
        #expect(overlay.diagnostics.count == 3)
    }

    /// Once the machine installs a revision, the durable bytes are used. The
    /// overlay covers only the window before publication.
    @Test func installedRevisionWinsOverTheBundledCopy() throws {
        let environment = try Environment.make()
        defer { environment.cleanup() }

        let overlay = ReviewedExtractorPackageOverlay.resolve(
            layout: environment.layout,
            explicitRoot: Environment.reviewedPackagesRoot,
            packages: [ReviewedExtractorPackages.defuddle])
        let revision = ReviewedExtractorPackages.defuddle.revision

        let empty = StubCatalogReader(records: [])
        let bundled = ReviewedOverlaySourceLocator(
            layout: environment.layout, overlay: overlay, durable: empty)
        #expect(bundled.location(for: revision).root == overlay.roots[revision])

        let installed = StubCatalogReader(records: overlay.records)
        let stored = ReviewedOverlaySourceLocator(
            layout: environment.layout, overlay: overlay, durable: installed)
        #expect(stored.location(for: revision).containingRoot == environment.layout.packagesRoot)
    }

    // MARK: - Support

    private struct StubCatalogReader: ExtractorPackageCatalogReading {
        let records: [ExtractorPackageCatalogRecord]

        func read() throws -> ExtractorPackageCatalog {
            try ExtractorPackageCatalog(generation: 1, records: records)
        }
    }

    private struct Environment {
        let root: URL
        let layout: ExtractorPackageStoreLayout

        static var reviewedPackagesRoot: URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("ExtractorPackages", isDirectory: true)
        }

        static func make() throws -> Environment {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("reviewed-overlay-\(UUID().uuidString)", isDirectory: true)
            return Environment(
                root: root,
                layout: try ExtractorPackageStoreLayout(
                    appGroupContainerRoot: root,
                    processRole: .test))
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
#endif
