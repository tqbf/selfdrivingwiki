#if os(macOS)
import Foundation
import WikiFSTypes

// pattern: Imperative Shell

/// One reviewed extractor package that ships inside the application bundle and
/// inside the daemon service bundle.
///
/// The identity is compiled in. A bundled directory is used only when its bytes
/// reproduce this exact revision, so a tampered or stale bundle payload is
/// rejected instead of executed.
public struct ReviewedExtractorPackage: Sendable, Hashable {
    /// Directory name inside the `ExtractorPackages` resource folder.
    public let directoryName: String
    public let revision: ExtractorPackageRevisionID

    public var packageID: ExtractorPackageID { revision.packageID }
    public var version: ExtractorPackageVersion { revision.version }
}

/// Compiled reviewed package identities.
///
/// These are golden constants, not derived values. `ReviewedExtractorPackageTests`
/// validates the committed `ExtractorPackages/` payload and asserts that the
/// resulting revision equals the constant here, so a regenerated package whose
/// digest changed fails the gate with the value to use. The digest cannot be
/// computed by the sync script, because the canonical package digest is defined
/// by the Swift manifest code, and the sync gate must run before the build.
public enum ReviewedExtractorPackages {
    public static let resourceDirectoryName = "ExtractorPackages"

    public static let defuddle = make(
        directoryName: "Defuddle",
        packageID: "org.selfdrivingwiki.defuddle",
        version: "0.19.1",
        digest: "81513cfd85dad9ce4bfc4dc2732ef9caa099d75ce5e62ae5384362453048baf2")

    public static let pdf2md = make(
        directoryName: "Pdf2md",
        packageID: "org.selfdrivingwiki.pdf2md",
        version: "1.0.0",
        digest: "126a7d20f2381e90f8d44811b73ee933a43c948f1bbcb53e45b413fcceff3079")

    public static let doclingServe = make(
        directoryName: "DoclingServe",
        packageID: "org.selfdrivingwiki.docling-serve",
        version: "1.0.0",
        digest: "8e3ad795a1f1dd2a1750a425e9f16df221078d065a07dbe71818b7603521d113")

    public static let all: [ReviewedExtractorPackage] = [defuddle, pdf2md, doclingServe]

    /// Locates the reviewed payload. `Bundle.main` resolves in both hosts:
    /// `build.sh` copies the same tree into the application resources and into
    /// the `wikid.xpc` resources. The source checkout is not a runtime input, so
    /// tests and command-line hosts pass an explicit root instead.
    public static func bundledRoot(
        for package: ReviewedExtractorPackage,
        explicitRoot: URL? = nil,
        bundle: Bundle = .main
    ) -> URL? {
        if let explicitRoot {
            let candidate = explicitRoot.appendingPathComponent(
                package.directoryName, isDirectory: true)
            return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        }
        return bundle.url(
            forResource: package.directoryName,
            withExtension: nil,
            subdirectory: resourceDirectoryName)
    }

    private static func make(
        directoryName: String,
        packageID: String,
        version: String,
        digest: String
    ) -> ReviewedExtractorPackage {
        do {
            guard let version = ExtractorPackageVersion(rawValue: version) else {
                throw ExtractorValidationError.invalidIdentifier(
                    kind: "reviewed extractor version", value: version)
            }
            return ReviewedExtractorPackage(
                directoryName: directoryName,
                revision: ExtractorPackageRevisionID(
                    packageID: try ExtractorPackageID(validating: packageID),
                    version: version,
                    digest: try ExtractorPackageDigest(hex: digest)))
        } catch {
            preconditionFailure("Invalid compiled reviewed extractor identity: \(error)")
        }
    }
}

/// The host-owned reviewed overlay for one process.
///
/// Reviewed revisions are admitted into this process's own operation root, so
/// both the application and the daemon can run them before the application
/// publishes them into the durable machine catalog. Admission writes nothing
/// shared, so it does not make a reader process a catalog writer.
public struct ReviewedExtractorPackageOverlay: Sendable {
    /// Validated bundled roots by exact revision.
    public let roots: [ExtractorPackageRevisionID: URL]
    /// Synthesized records for the reviewed revisions this process can run.
    public let records: [ExtractorPackageCatalogRecord]
    /// Bounded redacted notices for reviewed packages that failed admission.
    public let diagnostics: [String]

    public static let empty = ReviewedExtractorPackageOverlay(
        roots: [:], records: [], diagnostics: [])

    /// Fixed timestamp so repeated reads of the same process overlay produce
    /// equal records. Reviewed revisions are not installed, so they have no
    /// meaningful install time.
    static let reviewedInstalledAt = RFC3339Timestamp(date: Date(timeIntervalSince1970: 0))

    /// Admits every reviewed package that resolves and validates. One failed
    /// reviewed package never blocks the other.
    public static func resolve(
        layout: ExtractorPackageStoreLayout,
        explicitRoot: URL? = nil,
        packages: [ReviewedExtractorPackage] = ReviewedExtractorPackages.all
    ) -> ReviewedExtractorPackageOverlay {
        var roots: [ExtractorPackageRevisionID: URL] = [:]
        var records: [ExtractorPackageCatalogRecord] = []
        var diagnostics: [String] = []
        for package in packages {
            guard let source = ReviewedExtractorPackages.bundledRoot(
                for: package, explicitRoot: explicitRoot) else {
                diagnostics.append("reviewed package \(package.packageID.rawValue) is not bundled")
                continue
            }
            do {
                let validated = try ExtractorDirectoryValidator.admitReviewedBundle(
                    source: source,
                    expectedRevision: package.revision,
                    layout: layout)
                let record = try ExtractorPackageCatalogRecord(
                    validatedManifest: validated.validated.manifest,
                    revision: package.revision,
                    installedAt: reviewedInstalledAt)
                roots[package.revision] = validated.root
                records.append(record)
            } catch {
                diagnostics.append(
                    "reviewed package \(package.packageID.rawValue) failed admission")
            }
        }
        return ReviewedExtractorPackageOverlay(
            roots: roots, records: records, diagnostics: diagnostics)
    }
}
#endif
