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

        let installedRecords: [ExtractorPackageCatalogRecord]
        do {
            installedRecords = try await writer.read().records
        } catch {
            DebugLog.extraction(
                "extractor bootstrap: catalog unreadable after publish; grant seeding skipped")
            installedRecords = []
        }
        await seedReviewedCredentialGrants(
            appGroupContainerRoot: appGroupContainerRoot,
            installed: installedRecords)
    }

    /// Seeds the reviewed Zotero credential binding. No UI ships in this
    /// cycle, so the app writes one idempotent authorization record binding
    /// `(org.selfdrivingwiki.zotero, zotero-api-key)` to the legacy
    /// `.zoteroAPIKey()` Keychain reference, pinned to the exact requirement
    /// fingerprint the installed manifest declares. App-only (the writer's
    /// role gate enforces it), best-effort, and a no-op when the grant
    /// already matches this contract — a revocation by a future UI cycle is
    /// never silently resurrected unless the contract changed. With the
    /// binding in place, per-operation resolution flows through the standard
    /// credential-file path; an unset Keychain value surfaces as the typed
    /// missing-credential state, never as a value leak.
    private static func seedReviewedCredentialGrants(
        appGroupContainerRoot: URL,
        installed: [ExtractorPackageCatalogRecord]
    ) async {
        let reviewed = ReviewedExtractorPackages.zotero
        guard let record = installed.first(where: { $0.revision == reviewed.revision }),
              let registration = record.registrations.first(where: { registration in
                  registration.credentialRequirements.contains {
                      $0.id.rawValue == "zotero-api-key"
                  }
              }),
              let requirement = registration.credentialRequirements.first(where: {
                  $0.id.rawValue == "zotero-api-key"
              })
        else { return }

        let layout = ExtractorCredentialAuthorizationStoreLayout(
            appGroupContainerRoot: appGroupContainerRoot)
        let snapshot = ExtractorCredentialAuthorizationReader(layout: layout).snapshot()
        let authorizationID = ExtractorCredentialAuthorizationID(
            packageID: reviewed.packageID, requirementID: requirement.id)
        let fingerprint = ExtractorCredentialRequirementFingerprint.compute(
            packageID: reviewed.packageID.rawValue,
            registrationID: registration.id.rawValue,
            kinds: registration.kinds.map(\.rawValue),
            mimeTypes: registration.mimeTypes.map(\.rawValue),
            requirement: requirement)
        if let existing = snapshot?.record(for: authorizationID),
           existing.fingerprint == fingerprint {
            return
        }
        do {
            let writer = try ExtractorCredentialAuthorizationWriter(
                layout: layout,
                processRole: .app)
            _ = try await writer.grant(
                packageID: reviewed.packageID,
                registrationID: registration.id,
                kinds: registration.kinds.map(\.rawValue),
                mimeTypes: registration.mimeTypes.map(\.rawValue),
                requirement: requirement,
                credentialReference: .zoteroAPIKey())
        } catch {
            DebugLog.extraction(
                "extractor bootstrap: reviewed credential grant could not be seeded")
        }
    }
}
#endif
