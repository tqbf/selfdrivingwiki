import Foundation
import Synchronization
import WikiFSTypes

// Provider environment secrets (issue #1159, plans/credential-service.md).
// `AgentProvider.env` (persisted in `agent-providers.json`) has ALWAYS had a
// no-secret contract, but the file historically accepted plaintext API-key
// variables. This module closes that hole:
//
// - `ProviderSecretEnvironmentVariable` — the CLOSED set of known secret
//   environment variable names, so classification is exhaustive and
//   compiler-checked;
// - `CredentialReference.providerSecret(providerID:variable:)` — the typed
//   provider-scoped reference for each (new credentials live under the shared
//   `org.sockpuppet.WikiFS.credentials` service);
// - `ProviderSecretEnvironment` — decode/write-boundary stripping and the
//   trusted-host spawn-secret resolution.

/// The known API-key environment variables that must never persist as
/// plaintext sidecar data. Closed: a new provider key requirement extends
/// this enum, and every boundary below picks it up automatically.
public enum ProviderSecretEnvironmentVariable: String, CaseIterable, Codable,
    Sendable, Hashable {
    case anthropic = "ANTHROPIC_API_KEY"
    case gemini = "GEMINI_API_KEY"
    case openAI = "OPENAI_API_KEY"

    /// The known secret variable with this exact name, or `nil` for any
    /// non-secret name (including case variants — matching is exact, the
    /// same way shells match env keys).
    public static func knownSecret(named name: String) -> ProviderSecretEnvironmentVariable? {
        allCases.first { $0.rawValue == name }
    }

    /// Whether this exact environment variable name carries a secret.
    public static func isKnownSecret(_ name: String) -> Bool {
        knownSecret(named: name) != nil
    }

    /// The canonical reference key for this variable — the lowercased kebab
    /// form (`ANTHROPIC_API_KEY` → `anthropic-api-key`), which satisfies the
    /// `CredentialReference` label grammar by construction.
    public var referenceKey: String {
        rawValue.lowercased().replacing("_", with: "-")
    }
}

extension CredentialReference {

    /// The provider-scoped credential reference for one known secret
    /// variable: `provider.<providerID>.<referenceKey>`. Returns `nil` when
    /// the provider id cannot form a valid reference label; such a provider
    /// keeps its plaintext sidecar value (the migration records a bounded
    /// failure rather than losing or misplacing the credential).
    public static func providerSecret(
        providerID: ProviderID,
        variable: ProviderSecretEnvironmentVariable
    ) -> CredentialReference? {
        CredentialReference(validatingLabels: [
            "provider", providerID.rawValue, variable.referenceKey,
        ])
    }
}

/// Boundary helpers keeping plaintext secrets out of `AgentProvider.env`.
public enum ProviderSecretEnvironment {

    /// Strip every known secret variable from one provider's env map.
    /// Returns the cleaned map (non-secret entries unchanged). PURE.
    public static func strippingSecrets(
        from env: [String: String]
    ) -> [String: String] {
        env.filter { !ProviderSecretEnvironmentVariable.isKnownSecret($0.key) }
    }

    /// Strip known secret variables from every provider in the list, returning
    /// the cleaned providers plus the stripped KEY NAMES (never values) for a
    /// bounded diagnostic. PURE.
    public static func strippingSecrets(
        from providers: [AgentProvider]
    ) -> (providers: [AgentProvider], strippedKeyNames: [String]) {
        var strippedNames: [String] = []
        let cleaned = providers.map { provider in
            var updated = provider
            let before = Set(updated.env.keys)
            updated.env = strippingSecrets(from: updated.env)
            for key in before.subtracting(updated.env.keys).sorted() {
                strippedNames.append("\(provider.id.rawValue).\(key)")
            }
            return updated
        }
        return (cleaned, strippedNames)
    }

    /// Resolve a provider's known secret environment variables from the
    /// credential service — the TRUSTED HOST spawn path (plan item 18). The
    /// result carries only configured values for the closed variable set; it
    /// is merged into the provider's private spawn hints immediately before
    /// preparation and never persisted anywhere. A missing credential is
    /// omitted (the provider runs without it, exactly like a missing env var
    /// today); a real read failure is logged value-free.
    public static func resolvedSpawnSecrets(
        for providerID: ProviderID,
        resolving: CredentialResolving
    ) -> [String: String] {
        var resolved: [String: String] = [:]
        for variable in ProviderSecretEnvironmentVariable.allCases {
            guard let reference = CredentialReference.providerSecret(
                providerID: providerID, variable: variable)
            else { continue }
            do {
                resolved[variable.rawValue] = try resolving.resolve(reference).value
            } catch CredentialStoreError.notConfigured {
                continue
            } catch {
                DebugLog.config(
                    "Provider credential resolve failed for \(reference.rawValue): \(error)")
                continue
            }
        }
        return resolved
    }
}

// MARK: - One-shot sidecar → Keychain migration

/// One entry in a migration report: which provider/variable the entry is
/// about. Names only — never a value.
public struct AgentProviderCredentialMigrationEntry: Hashable, Sendable,
    CustomStringConvertible {
    public let providerID: String
    public let variable: ProviderSecretEnvironmentVariable

    public init(providerID: String, variable: ProviderSecretEnvironmentVariable) {
        self.providerID = providerID
        self.variable = variable
    }

    public var description: String { "\(providerID).\(variable.rawValue)" }
}

/// The bounded, value-free outcome of one migration pass.
public struct AgentProviderCredentialMigrationReport: Equatable, Sendable {
    /// Plaintext values that were written to Keychain and removed from the
    /// sidecar.
    public var migrated: [AgentProviderCredentialMigrationEntry] = []
    /// Plaintext duplicates removed because Keychain already held the SAME
    /// value.
    public var removedDuplicates: [AgentProviderCredentialMigrationEntry] = []
    /// Keychain holds a DIFFERENT value: the plaintext entry is preserved and
    /// NEITHER value was overwritten. The user resolves the conflict (Risk 13).
    public var conflicts: [AgentProviderCredentialMigrationEntry] = []
    /// The Keychain write failed: the plaintext entry is preserved so the
    /// credential is never lost.
    public var failures: [AgentProviderCredentialMigrationEntry] = []
    /// The provider id / variable could not form a typed reference; plaintext
    /// preserved untouched.
    public var unmappable: [AgentProviderCredentialMigrationEntry] = []
    /// The locked sidecar persist failed after resolutions succeeded: the
    /// file was NOT rewritten, so plaintext remains and the next launch
    /// retries. The Keychain writes already succeeded (they become duplicate
    /// removals on retry), but the migration must not report a clean state
    /// until the removal is durable (PR 1 review, MEDIUM).
    public var commitFailed: Bool = false

    public init() {}

    /// True when the migration needs operator attention. Successful
    /// migrations/duplicate-removals are clean; conflicts, failures,
    /// unmappable entries, and commit failures are not.
    public var isClean: Bool {
        conflicts.isEmpty && failures.isEmpty && unmappable.isEmpty && !commitFailed
    }
}

/// The one app-owned, lock-safe migration of legacy plaintext provider API
/// keys from `agent-providers.json` into the shared credential service
/// (Keychain). Deterministic conflict semantics (plan step 17):
///
/// - Keychain ABSENT → write the plaintext value, and only after the write
///   succeeds remove the sidecar entry;
/// - Keychain SAME value → remove the duplicate plaintext;
/// - Keychain DIFFERENT value → preserve the plaintext, overwrite nothing,
///   surface a bounded conflict status.
///
/// # Why the scan reads RAW file bytes
/// `AgentProvidersConfig`'s decode boundary (#1159) strips known secret
/// variables, so a DECODED config can never show the legacy plaintext. The
/// migrator therefore scans the raw JSON for known secret keys, resolves the
/// values into the service, and only then lets the normal config pipeline
/// persist the secret-free sidecar (any encode of a decoded config is already
/// secret-free). The sidecar is rewritten ONLY when every discovered entry
/// resolved (migrated or duplicate-removed) — a conflicted or failed entry is
/// preserved untouched and retried on the next launch, so a credential is
/// never lost.
///
/// The persist runs inside `AgentProvidersConfigStore.mutate` (in-process +
/// cross-process file lock). Idempotent: a sidecar without plaintext secrets
/// is detected up front and never rewritten.
///
/// Called from the app's launch path (WikiFSApp); the daemon and CLI never
/// invoke it. THE APP IS THE ONLY WRITER of credentials into Keychain via
/// this migration.
public enum AgentProviderCredentialMigrator {

    /// One plaintext entry found in the raw sidecar bytes. Names + value;
    /// the value exists only inside this pass and never enters `report`.
    struct RawSidecarEntry {
        let providerID: String
        let variable: ProviderSecretEnvironmentVariable
        let value: String
    }

    /// Scan the RAW `agent-providers.json` for known secret variables with
    /// non-empty values.
    static func rawPlaintextEntries(at directory: URL) -> [RawSidecarEntry] {
        let url = directory.appendingPathComponent(
            AgentProvidersConfig.fileName, isDirectory: false)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return []  // missing/unreadable sidecar: nothing to migrate
        }
        let parsedObject: Any?
        do {
            parsedObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            DebugLog.store(
                "AgentProvider credential migration: sidecar JSON scan failed: \(error)")
            return []
        }
        guard let object = parsedObject as? [String: Any],
              let providers = object["providers"] as? [[String: Any]]
        else {
            DebugLog.store(
                "AgentProvider credential migration: sidecar is not parseable JSON; skipping")
            return []
        }
        var entries: [RawSidecarEntry] = []
        for provider in providers {
            guard let id = provider["id"] as? String,
                  let env = provider["env"] as? [String: Any] else { continue }
            for variable in ProviderSecretEnvironmentVariable.allCases {
                if let value = env[variable.rawValue] as? String,
                   CredentialValue.normalized(value) != nil {
                    entries.append(
                        RawSidecarEntry(
                            providerID: id, variable: variable, value: value))
                }
            }
        }
        return entries
    }

    /// Scan + migrate (see the type's doc comment for the full contract).
    ///
    /// The ENTIRE cycle — raw-byte scan, Keychain writes, and the secret-
    /// stripping persist — runs inside `store.mutate`'s lock (security review
    /// follow-up, PR 1 HIGH): scanning outside the lock allowed a plaintext
    /// entry added between scan and persist to be stripped by the decoded
    /// write without ever being migrated. Keychain operations inside the
    /// lock are bounded (single-digit ms per item). When any entry cannot be
    /// resolved (conflict/failure/unmappable), the mutation THROWS a private
    /// sentinel so `mutate` does not write — the sidecar keeps every
    /// plaintext byte and the next launch retries.
    public static func migrateIfNeeded(
        directory: URL,
        store: AgentProvidersConfigStore,
        credentials: CredentialDescribing & CredentialWriting & CredentialResolving
    ) async -> AgentProviderCredentialMigrationReport {
        // Fast pre-scan purely to skip the common clean case without taking
        // the sidecar lock or bumping its generation.
        guard !rawPlaintextEntries(at: directory).isEmpty else {
            return AgentProviderCredentialMigrationReport()
        }

        let reportBox = Mutex<AgentProviderCredentialMigrationReport?>(nil)
        do {
            // The mutation body is @Sendable and must return a config; the
            // report crosses back through a locked box (Synchronization.Mutex
            // — no @unchecked Sendable needed).
            _ = try await store.mutate { config in
                // INSIDE the lock: re-scan the raw bytes of the file this
                // mutation will replace. The decode→write pair strips known
                // secret variables, so every plaintext entry present at this
                // instant must be resolved (migrated) before that write may
                // happen — otherwise it is preserved by aborting.
                let entries = rawPlaintextEntries(at: directory)
                guard !entries.isEmpty else { return config }
                let outcome = migrateEntries(
                    entries: entries, credentials: credentials)
                reportBox.withLock { $0 = outcome.report }
                if outcome.anyChange, outcome.allResolved {
                    // The decoded config has already dropped the secrets, so
                    // this write is exactly "the removal", still under lock.
                    return config
                }
                // Conflicts/failures/unmappable: abort the write so the
                // sidecar keeps every plaintext byte untouched.
                throw MigrationDeferred()
            }
        } catch is MigrationDeferred {
            // Expected for conflicted/failed entries: the file is preserved.
        } catch {
            // The locked mutation failed (e.g. lock timeout or write error):
            // the sidecar is untouched, every plaintext entry is preserved,
            // and the next launch retries. Value-free diagnostic. The report
            // records the commit failure so `isClean` stays false (PR 1
            // review, MEDIUM).
            DebugLog.store(
                "AgentProvider credential migration: locked mutation failed: \(error)")
            reportBox.withLock { report in
                report?.commitFailed = true
            }
        }
        return reportBox.withLock { $0 } ?? AgentProviderCredentialMigrationReport()
    }

    /// Thrown inside the locked mutation to abort the persist while keeping
    /// the sidecar byte-identical. Never escapes `migrateIfNeeded`.
    private struct MigrationDeferred: Error {}

    /// The locked migration decisions over one raw entry batch.
    private static func migrateEntries(
        entries: [RawSidecarEntry],
        credentials: CredentialDescribing & CredentialWriting & CredentialResolving
    ) -> (report: AgentProviderCredentialMigrationReport, anyChange: Bool, allResolved: Bool) {
        var report = AgentProviderCredentialMigrationReport()
        var anyChange = false
        var allResolved = true
        for entry in entries {
            let item = AgentProviderCredentialMigrationEntry(
                providerID: entry.providerID, variable: entry.variable)
            guard let reference = CredentialReference.providerSecret(
                providerID: ProviderID(rawValue: entry.providerID),
                variable: entry.variable)
            else {
                report.unmappable.append(item)
                allResolved = false
                continue
            }
            let configuredInfo = credentials.describe(reference)
            if !configuredInfo.isConfigured {
                // Absent → write BEFORE removing the sidecar entry; a failed
                // write preserves the plaintext (never lose a key).
                do {
                    try credentials.set(entry.value, for: reference)
                } catch {
                    report.failures.append(item)
                    allResolved = false
                    continue
                }
                report.migrated.append(item)
                anyChange = true
                continue
            }
            // Configured → same value removes the duplicate plaintext; a
            // different value preserves BOTH and records the conflict.
            do {
                let existing = try credentials.resolve(reference)
                if existing.value == entry.value {
                    report.removedDuplicates.append(item)
                    anyChange = true
                } else {
                    report.conflicts.append(item)
                    allResolved = false
                }
            } catch {
                report.failures.append(item)
                allResolved = false
            }
        }
        return (report, anyChange, allResolved)
    }
}
