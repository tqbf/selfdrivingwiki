#if os(macOS)
import Foundation
import WikiFSCore
import WikiFSEngine
import WikiFSExtractorStore
import WikiFSTypes

// pattern: Imperative Shell

/// Publishes the reviewed bundled extractor revisions into the durable machine
/// catalog at application startup.
///
/// Only the application is a catalog writer, so only the application passes
/// this routine into its process input. The daemon and the CLI never publish:
/// they run the same revisions through the reviewed overlay until publication
/// succeeds.
///
/// Bootstrap is idempotent and best-effort. A revision the machine already has
/// is left untouched, and any failure logs one redacted diagnostic and returns:
/// the bundled revisions stay usable through the overlay, so a failed bootstrap
/// must never block startup.
enum ReviewedExtractorBootstrap {
    static func publishBundledPackages(
        appGroupContainerRoot: URL,
        bundle: Bundle = .main
    ) async {
        let writer: ExtractorPackageCatalogWriter
        do {
            writer = try ExtractorPackageCatalogWriter(
                appGroupContainerRoot: appGroupContainerRoot)
        } catch {
            DebugLog.extraction(
                "extractor bootstrap: catalog writer unavailable; bundled revisions stay in use")
            return
        }

        let installed: Set<ExtractorPackageRevisionID>
        do {
            installed = Set(try await writer.read().records.map(\.revision))
        } catch {
            DebugLog.extraction(
                "extractor bootstrap: catalog unreadable; bundled revisions stay in use")
            return
        }

        let timestamp = RFC3339Timestamp(date: Date())
        for package in ReviewedExtractorPackages.all {
            guard installed.contains(package.revision) == false else { continue }
            guard let source = ReviewedExtractorPackages.bundledRoot(
                for: package, bundle: bundle) else {
                DebugLog.extraction(
                    "extractor bootstrap: reviewed package is not bundled")
                continue
            }
            do {
                _ = try await writer.importDirectory(source, installedAt: timestamp)
            } catch {
                // One redacted diagnostic per package. The store rejects an
                // identity replacement, so a conflicting machine record keeps
                // its installed bytes and the overlay stays unused for it.
                DebugLog.extraction(
                    "extractor bootstrap: reviewed package failed admission; bundled revision stays in use")
            }
        }
    }
}
#endif
