#if os(macOS)
import Foundation
import WikiFSCore
import WikiFSTypes

// pattern: Imperative Shell

/// Where the exact bytes of one revision live for this process.
public struct ExtractorPackageSourceLocation: Sendable, Hashable {
    public let root: URL
    /// The root the source must sit beneath. Containment is checked against it.
    public let containingRoot: URL

    public init(root: URL, containingRoot: URL) {
        self.root = root
        self.containingRoot = containingRoot
    }
}

/// Resolves the source location of one exact revision.
///
/// Installed revisions resolve to the durable package root. Reviewed bundled
/// revisions resolve to the process-owned admitted copy, because a reader
/// process never installs bundled bytes.
public protocol ExtractorPackageSourceLocating: Sendable {
    func location(for revision: ExtractorPackageRevisionID) -> ExtractorPackageSourceLocation
}

/// Store-only resolution. Every revision is expected in the durable package root.
public struct InstalledExtractorPackageSourceLocator: ExtractorPackageSourceLocating {
    let layout: ExtractorPackageStoreLayout

    public init(layout: ExtractorPackageStoreLayout) {
        self.layout = layout
    }

    public func location(for revision: ExtractorPackageRevisionID) -> ExtractorPackageSourceLocation {
        ExtractorPackageSourceLocation(
            root: layout.packageURL(revision.packageID, version: revision.version),
            containingRoot: layout.packagesRoot)
    }
}

/// Prefers the installed copy and falls back to the reviewed bundled copy.
///
/// The durable catalog stays authoritative: once the application publishes a
/// reviewed revision, every process runs the installed bytes. The overlay only
/// covers the window before publication, or a process that cannot publish.
public struct ReviewedOverlaySourceLocator: ExtractorPackageSourceLocating {
    let layout: ExtractorPackageStoreLayout
    let overlay: ReviewedExtractorPackageOverlay
    let durable: any ExtractorPackageCatalogReading

    public init(
        layout: ExtractorPackageStoreLayout,
        overlay: ReviewedExtractorPackageOverlay,
        durable: any ExtractorPackageCatalogReading
    ) {
        self.layout = layout
        self.overlay = overlay
        self.durable = durable
    }

    public func location(for revision: ExtractorPackageRevisionID) -> ExtractorPackageSourceLocation {
        let installed = ExtractorPackageSourceLocation(
            root: layout.packageURL(revision.packageID, version: revision.version),
            containingRoot: layout.packagesRoot)
        guard let reviewedRoot = overlay.roots[revision] else { return installed }
        // The installed copy wins whenever the durable catalog has this exact
        // revision. An unreadable catalog keeps the reviewed copy usable.
        do {
            let catalog = try durable.read()
            if catalog.records.contains(where: { $0.revision == revision }) {
                return installed
            }
        } catch {
            DebugLog.extraction(
                "extractor source locator: durable catalog unreadable; using reviewed copy")
        }
        return ExtractorPackageSourceLocation(
            root: reviewedRoot,
            containingRoot: layout.processOperationsRoot)
    }
}

/// Presents the durable catalog plus the reviewed revisions this process can
/// run but the machine has not installed.
///
/// The durable generation is reported unchanged. A process overlay is fixed for
/// the process lifetime, so one generation always maps to one desired set, and
/// publishing reviewed packages increments the durable generation anyway.
public struct ReviewedOverlayCatalogReader: ExtractorPackageCatalogReading {
    let durable: any ExtractorPackageCatalogReading
    let overlay: ReviewedExtractorPackageOverlay

    public init(
        durable: any ExtractorPackageCatalogReading,
        overlay: ReviewedExtractorPackageOverlay
    ) {
        self.durable = durable
        self.overlay = overlay
    }

    public func read() throws -> ExtractorPackageCatalog {
        let base = try durable.read()
        guard overlay.records.isEmpty == false else { return base }

        let installed = Set(base.records.map(\.revision).map(Self.reservation))
        var reserved: [ExtractorPackageReservation: ExtractorPackageDigest] = [:]
        for record in base.reservations { reserved[record.reservation] = record.digest }

        let additions = overlay.records.filter { record in
            let reservation = Self.reservation(record.revision)
            // The machine already owns this identity: durable bytes win.
            if installed.contains(reservation) { return false }
            // A reservation with another digest means the machine reserved this
            // identity for different bytes. Adding it would be a conflict.
            if let digest = reserved[reservation], digest != record.revision.digest {
                return false
            }
            return true
        }
        guard additions.isEmpty == false else { return base }

        do {
            return try ExtractorPackageCatalog(
                generation: base.generation,
                records: base.records + additions,
                reservations: base.reservations)
        } catch {
            // Never fail the read: a rejected overlay leaves the durable
            // catalog intact rather than removing working installed packages.
            return base
        }
    }

    private static func reservation(
        _ revision: ExtractorPackageRevisionID
    ) -> ExtractorPackageReservation {
        ExtractorPackageReservation(
            packageID: revision.packageID,
            version: revision.version)
    }
}
#endif
