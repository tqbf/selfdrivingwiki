import Foundation
import WikiFSCore
import WikiFSTypes
#if canImport(WikiFSEngine)
import WikiFSEngine
#endif

/// `wikictl extractor sync <package> [--force]` — create one byteless source
/// per configured acquisition item of `<package>` and enqueue its durable
/// extraction job. The CLI seam of the extractor-package acquisition API,
/// fully generic: syncable packages are DISCOVERED from the machine catalog
/// (durable records ∪ this process's reviewed overlay) by their declared
/// sync surface, so a second syncable package needs zero host-code changes.
///
/// The command is ENQUEUE-ONLY: it writes the `.extraction` queue item
/// through the injected closure (production wires `QueueStore.enqueue`, the
/// same immediate durable store write `QueueEngine.enqueue` performs). It
/// never constructs a `QueueEngine` (that needs a `workerFactory` whose
/// provider implementations live in targets `WikiCtlCore` cannot link) and
/// never waits for completion (waiters are per-engine in-memory; a
/// daemon-side completion could never resume a CLI waiter). The app or the
/// wikid daemon rehydrates and drains the persisted items on its next
/// dispatch scan / launch.
///
/// Hard failures exit nonzero with a typed message: an unknown package
/// name, an unconfigured required config field, an empty item list, an
/// unbound or absent required credential (a describe-only presence check —
/// the value is never read here). A credential this process cannot READ (no
/// shared-keychain entitlement) defers the check to the draining host
/// instead of failing.
public enum ExtractorSyncCommand {

    /// The family's operations. One case per leaf (`sync` today).
    public enum Action: Equatable, Sendable {
        /// The positional package name stays a raw string here: which names
        /// are valid is catalog data, resolved at execution — never a
        /// compiled set.
        case sync(packageName: String, force: Bool)
    }

    /// One typed hard failure with a caller-facing message.
    public enum Failure: Error, Equatable, LocalizedError {
        /// The named package has no discovered sync declaration. The
        /// discovered names ride along so the message can list them.
        case unknownPackage(String, discovered: [String])
        /// The name matches more than one declared sync surface (two
        /// packages whose short names collide, or one package with two
        /// sync-bearing registrations). Candidates are `packageID#registrationID`.
        case ambiguousPackage(String, candidates: [String])
        /// The registration's required credential has no compiled binding —
        /// reviewed packages only.
        case requiredCredentialUnavailable(packageName: String, requirementID: String)
        /// The bound required credential is absent (as opposed to
        /// unreadable, which defers instead of failing).
        case requiredCredentialNotConfigured(label: String)

        public var errorDescription: String? {
            switch self {
            case .unknownPackage(let name, let discovered):
                if discovered.isEmpty {
                    return "Unknown extraction package '\(name)'. No syncable packages are installed; launch the app once so reviewed packages publish, then retry."
                }
                return "Unknown extraction package '\(name)'. Syncable: \(discovered.joined(separator: ", "))."
            case .ambiguousPackage(let name, let candidates):
                return "The package name '\(name)' is ambiguous; it matches \(candidates.joined(separator: ", "))."
            case .requiredCredentialUnavailable(let name, let requirementID):
                return "The sync for '\(name)' requires credential '\(requirementID)', which has no reviewed binding in this build."
            case .requiredCredentialNotConfigured(let label):
                return "The \(label) is not configured. Set it in the app's extraction package settings and sync again."
            }
        }
    }

    /// One discovered syncable surface: one registration of one record.
    public struct DiscoveredSyncPackage {
        let record: ExtractorPackageCatalogRecord
        let registration: ExtractorRegistration
        let sync: ExtractorSyncDeclaration
        let shortName: String

        init?(
            record: ExtractorPackageCatalogRecord,
            registration: ExtractorRegistration
        ) {
            guard let sync = registration.sync else { return nil }
            self.record = record
            self.registration = registration
            self.sync = sync
            self.shortName = Self.shortName(of: record.revision.packageID)
        }

        /// `org.example.attachment` → `attachment`.
        static func shortName(of packageID: ExtractorPackageID) -> String {
            packageID.rawValue.split(separator: ".").last.map(String.init) ?? packageID.rawValue
        }

        /// The ambiguity identity: `packageID#registrationID`.
        var candidateID: String {
            "\(record.revision.packageID.rawValue)#\(registration.id.rawValue)"
        }
    }

    /// Resolves the newest record per package lineage, keeping one entry per
    /// sync-bearing registration of the newest revision, deterministically
    /// ordered.
    public static func discoverSyncablePackages(
        in catalog: ExtractorPackageCatalog
    ) -> [DiscoveredSyncPackage] {
        var newest: [ExtractorPackageID: ExtractorPackageCatalogRecord] = [:]
        for record in catalog.records {
            if let current = newest[record.revision.packageID] {
                if record.revision.version > current.revision.version {
                    newest[record.revision.packageID] = record
                }
            } else {
                newest[record.revision.packageID] = record
            }
        }
        return newest.values.flatMap { record in
            record.registrations.compactMap { registration in
                DiscoveredSyncPackage(record: record, registration: registration)
            }
        }.sorted {
            $0.shortName == $1.shortName
                ? $0.candidateID < $1.candidateID
                : $0.shortName < $1.shortName
        }
    }

    /// The reviewed overlay root for a command-line host: the staged
    /// `ExtractorPackages/` tree beside the binary. `Bundle.main.bundleURL`
    /// of a bare Mach-O is the directory containing it, and the build stages
    /// the tree under that directory's `ExtractorPackages/` — exactly what
    /// `ReviewedExtractorPackages.bundledRoot(explicitRoot:)` probes.
    public static func reviewedPackageRoot(for bundle: Bundle = .main) -> URL {
        bundle.bundleURL.appendingPathComponent(
            ReviewedExtractorPackages.resourceDirectoryName, isDirectory: true)
    }

    /// Production discovery for a command-line host: the durable machine
    /// catalog unioned with this process's reviewed overlay. The overlay
    /// covers the window before the app publishes a reviewed revision (and
    /// CLI-only machines, where the durable catalog never carries it); the
    /// durable catalog wins for any revision the machine has installed.
    ///
    /// `reviewedPackageRoot` is the directory containing the staged
    /// `ExtractorPackages/` tree (beside the binary in build layouts). When
    /// it does not resolve — an app-bundled helper has no such tree beside
    /// it — discovery still works through the durable catalog the app
    /// published at launch.
    public static func productionCatalogReader(
        containerDirectory: URL,
        reviewedPackageRoot: URL? = nil
    ) throws -> any ExtractorPackageCatalogReading {
        let layout = try ExtractorPackageStoreLayout(
            appGroupContainerRoot: containerDirectory,
            processRole: .commandLine)
        let overlay = ReviewedExtractorPackageOverlay.resolve(
            layout: layout, explicitRoot: reviewedPackageRoot)
        for notice in overlay.diagnostics {
            DebugLog.extraction("extractor sync: \(notice)")
        }
        return ReviewedOverlayCatalogReader(
            durable: ExtractorPackageCatalogReader(layout: layout),
            overlay: overlay)
    }

    public static func run(
        packageName: String,
        force: Bool,
        in store: GRDBWikiStore,
        containerDirectory: URL,
        catalog: any ExtractorPackageCatalogReading,
        credentials: any CredentialDescribing = KeychainCredentialService(),
        enqueue: (SourceID) async throws -> Void
    ) async throws -> String {
        // Discovery at execution time: the catalog says what is syncable.
        let syncable = discoverSyncablePackages(in: try catalog.read())
        let matches = syncable.filter { $0.shortName == packageName }
        guard matches.isEmpty == false else {
            // Sorted input, so an adjacent-unique pass dedupes names that
            // carry multiple declared surfaces.
            let discovered = syncable.map(\.shortName)
                .reduce(into: [String]()) { names, name in
                    if names.last != name { names.append(name) }
                }
            throw Failure.unknownPackage(packageName, discovered: discovered)
        }
        // A name that matches more than one declared surface is a typed
        // ambiguity failure, never an arbitrary pick: two packages whose
        // short names collide, or one package with two sync-bearing
        // registrations.
        guard matches.count == 1, let package = matches.first else {
            throw Failure.ambiguousPackage(
                packageName, candidates: matches.map(\.candidateID))
        }
        let declaration = package.sync

        // The required-credential gate. Manifest validation guarantees at
        // most one required requirement on a sync declaration; zero means
        // the package syncs without a gate (the second-package contract).
        // The gate is describe-only — the value is never read here — but
        // "absent" and "unreadable here" are different outcomes. A bare CLI
        // Mach-O cannot carry keychain-access-groups (AMFI SIGKILLs any
        // that claim them without an embedded profile — see build.sh), so
        // on a configured machine EVERY shared-keychain read in this
        // process fails, and describe surfaces that as verificationFailed,
        // not as "unset". Failing the sync there would block the documented
        // flow even though the entitled host draining this job (app /
        // wikid.xpc) resolves the same key fine. Absent → hard typed
        // failure; unreadable → defer, and say so in the output.
        var credentialCheckDeferred = false
        let requiredRequirement = package.registration.credentialRequirements
            .first { $0.isOptional == false }
        if let requiredRequirement {
            guard let binding = ReviewedExtractorCredentialBindings.binding(
                packageID: package.record.revision.packageID.rawValue,
                requirementID: requiredRequirement.id.rawValue) else {
                throw Failure.requiredCredentialUnavailable(
                    packageName: packageName, requirementID: requiredRequirement.id.rawValue)
            }
            let info = credentials.describe(binding.reference)
            if info.isConfigured == false {
                if info.verificationFailed {
                    credentialCheckDeferred = true
                } else {
                    throw Failure.requiredCredentialNotConfigured(
                        label: requiredRequirement.label)
                }
            }
        }

        // The declared config sidecar. A missing or corrupt file loads as no
        // values, so validation names the first required field — the same
        // fresh-install failure the config gate always had.
        let config = try ExtractorSyncSidecar.load(
            declaration: declaration, from: containerDirectory)

        // The byteless source MIME: the declaration's explicit MIME, or the
        // registration's single declared MIME (manifest validation makes the
        // fallback total).
        guard let sourceMIMEType = declaration.sourceMIMEType
            ?? package.registration.mimeTypes.sorted().first else {
            throw Failure.unknownPackage(packageName, discovered: [])
        }

        let outcomes = try await ExtractorPackageSync.syncItems(
            store: store,
            declaration: declaration,
            packageIdentity: ExtractorSyncPackageIdentity(
                packageID: package.record.revision.packageID,
                displayName: package.record.displayName),
            config: config,
            sourceMIMEType: sourceMIMEType,
            enqueue: enqueue,
            force: force)

        var lines: [String] = []
        lines.append("\(package.record.displayName) sync: \(outcomes.count) item(s)")
        for outcome in outcomes {
            switch outcome.action {
            case .created:
                lines.append(
                    "  created  \(outcome.itemKey) → source \(outcome.sourceID.rawValue) (extraction enqueued)")
            case .reenqueued:
                lines.append(
                    "  re-enqueued  \(outcome.itemKey) → source \(outcome.sourceID.rawValue)")
            case .skipped:
                lines.append(
                    "  skipped  \(outcome.itemKey) → source \(outcome.sourceID.rawValue) already synced (use --force to re-extract)")
            }
        }
        lines.append(
            "Enqueued items drain when the app or the wikid daemon next runs its dispatch scan.")
        if credentialCheckDeferred {
            lines.append(
                "Note: the \(requiredRequirement?.label ?? "required credential") could not be verified from this process; the host that drains these jobs will check it before downloading.")
        }
        return lines.joined(separator: "\n")
    }
}
