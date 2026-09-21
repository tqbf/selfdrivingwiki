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

    /// The seeded subset of the reviewed credential bindings: packages whose
    /// host credential the user already manages in a Settings account pane,
    /// so a publish-time grant is the reviewed default. Adding acquisition
    /// package #2 with a default credential is one row here — never a new
    /// seeding branch. Docling Serve is deliberately absent: its token is
    /// opt-in and authorized explicitly in Settings.
    private static let reviewedCredentialSeeds: [ReviewedExtractorCredentialBinding] = [
        ReviewedExtractorCredentialBindings.zoteroAPIKey,
    ]

    /// Seeds the reviewed packages' default credential bindings. No UI ships
    /// in this cycle, so the app writes idempotent authorization records
    /// binding each `(package, requirementID)` to its credential reference,
    /// pinned to the exact requirement fingerprint the installed manifest
    /// declares. App-only (the writer's role gate enforces it) and
    /// best-effort.
    ///
    /// Revocation safety: revocation deletes the authorization record, so
    /// record absence cannot distinguish "never seeded" from "revoked". A
    /// seed-marker file records the fingerprint this host last seeded; the
    /// grant is written ONLY when that marker's fingerprint differs from
    /// the current contract (a real contract change) or no marker exists
    /// yet. A revocation followed by an unchanged contract therefore stays
    /// revoked — the seeder never resurrects it. The standard
    /// Authorize/Revoke UI arrives with the later UI cycle.
    private static func seedReviewedCredentialGrants(
        appGroupContainerRoot: URL,
        installed: [ExtractorPackageCatalogRecord]
    ) async {
        for seed in reviewedCredentialSeeds {
            await seedCredentialGrant(
                package: seed.package,
                requirementID: seed.requirementID,
                reference: seed.reference,
                appGroupContainerRoot: appGroupContainerRoot,
                installed: installed)
        }
    }

    /// The per-package seeding step: fingerprint from the installed record,
    /// marker check, grant, marker write (in that order — the marker persists
    /// only after a successful grant, so a failed write retries next launch).
    private static func seedCredentialGrant(
        package: ReviewedExtractorPackage,
        requirementID: ExtractorCredentialRequirementID,
        reference: CredentialReference,
        appGroupContainerRoot: URL,
        installed: [ExtractorPackageCatalogRecord]
    ) async {
        guard let record = installed.first(where: { $0.revision == package.revision }),
              let (registration, requirement) = Self.matchingRequirement(
                registrations: record.registrations,
                requirementID: requirementID)
        else { return }

        let layout = ExtractorCredentialAuthorizationStoreLayout(
            appGroupContainerRoot: appGroupContainerRoot)
        let fingerprint = ExtractorCredentialRequirementFingerprint.compute(
            packageID: package.packageID.rawValue,
            registrationID: registration.id.rawValue,
            kinds: registration.kinds.map(\.rawValue),
            mimeTypes: registration.mimeTypes.map(\.rawValue),
            requirement: requirement)
        let markerKey = "\(package.packageID.rawValue)/\(requirement.id.rawValue)"

        // The seed-marker decides: grant only on a contract change (or a
        // first seed). Record presence is deliberately NOT consulted — a
        // revoked record looks exactly like an absent one.
        var markers = Self.loadSeedMarkers(layout: layout)
        if markers[markerKey] == fingerprint.value {
            return
        }
        do {
            let writer = try ExtractorCredentialAuthorizationWriter(
                layout: layout,
                processRole: .app)
            _ = try await writer.grant(
                packageID: package.packageID,
                registrationID: registration.id,
                kinds: registration.kinds.map(\.rawValue),
                mimeTypes: registration.mimeTypes.map(\.rawValue),
                requirement: requirement,
                credentialReference: reference)
        } catch {
            DebugLog.extraction(
                "extractor bootstrap: reviewed credential grant could not be seeded")
            return
        }
        // Persist the marker only after a successful grant, so a failed
        // write retries on the next launch.
        markers[markerKey] = fingerprint.value
        Self.saveSeedMarkers(markers, layout: layout)
    }

    /// The first `(registration, requirement)` pair declaring
    /// `requirementID`, found in one pass — the requirement is looked up once,
    /// not probed with `contains` and then re-scanned. Nil when no
    /// registration declares it.
    private static func matchingRequirement(
        registrations: [ExtractorRegistration],
        requirementID: ExtractorCredentialRequirementID
    ) -> (registration: ExtractorRegistration, requirement: ExtractorCredentialRequirement)? {
        for registration in registrations {
            guard let requirement = registration.credentialRequirements.first(where: {
                $0.id == requirementID
            }) else { continue }
            return (registration, requirement)
        }
        return nil
    }

    /// Last-seeded fingerprints by `"<packageID>/<requirementID>"`. Beside
    /// the authorization store in the credentials root; a missing or
    /// corrupt file degrades to "nothing seeded yet" (a first seed).
    private static func loadSeedMarkers(
        layout: ExtractorCredentialAuthorizationStoreLayout
    ) -> [String: String] {
        // swiftlint:disable:next silent_try_optional
        guard let data = try? Data(contentsOf: layout.credentialsRoot
            .appendingPathComponent("extractor-credential-seeds.json")) else {
            return [:]
        }
        // swiftlint:disable:next silent_try_optional
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private static func saveSeedMarkers(
        _ markers: [String: String],
        layout: ExtractorCredentialAuthorizationStoreLayout
    ) {
        do {
            try FileManager.default.createDirectory(
                at: layout.credentialsRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(markers)
            try data.write(
                to: layout.credentialsRoot
                    .appendingPathComponent("extractor-credential-seeds.json"),
                options: [.atomic])
        } catch {
            // A marker write failure means the next launch re-grants — the
            // same posture as "never seeded". One redacted diagnostic.
            DebugLog.extraction(
                "extractor bootstrap: credential seed marker could not be written")
        }
    }
}
#endif
