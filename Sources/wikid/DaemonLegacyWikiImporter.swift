#if canImport(WikiFSCore)
import Foundation
import WikiFSCore

// Phase 3 slice 2 (plans/daemon-only-access.md 3.3): the legacy v0 import is
// DAEMON-OWNED. This is the port of the app's
// `WikiRegistryClient.migrateLegacyWikiIfNeeded` into the daemon: at daemon
// start, when the daemon's registry view is empty AND a legacy `WikiFS.sqlite`
// exists in the container, it is renamed to its ULID-keyed name and registered
// as wiki #1 — under the daemon's own serialization (every caller runs it on
// the daemon queue), so no client ever performs it.
//
// Idempotence (mirrors the client's guards, which stay in force locally):
// - The caller gates on an EMPTY registry (strictly first-run).
// - Belt-and-suspenders here: no-op unless (a) the legacy file exists AND
//   (b) its ULID target is absent. A re-run after a completed import finds no
//   legacy file; a re-run after a partial move finds the target and no-ops,
//   leaving state as-is for the next launch.
enum DaemonLegacyWikiImporter {
    /// The migrated wiki's display name — identical to the app's import so a
    /// pre-P3 local import and a daemon import produce indistinguishable rows.
    static let legacyImportDisplayName = "Self Driving Wiki"

    /// Move the legacy `WikiFS.sqlite` (plus `-wal`/`-shm` sidecars) to its
    /// ULID-keyed name and register it. The caller must have checked the
    /// empty-registry gate and run this on the daemon's serialized boundary.
    static func migrateLegacyWikiIfNeeded(
        into registry: inout WikiRegistry, containerDirectory: URL
    ) {
        let fm = FileManager.default
        let legacy = containerDirectory.appendingPathComponent(
            DatabaseLocation.legacyDatabaseFileName, isDirectory: false)
        guard fm.fileExists(atPath: legacy.path) else { return }

        // Mint the descriptor for the migrated wiki and move the file to its
        // ULID-keyed name. If the move fails, leave everything as-is (the
        // daemon can retry next start).
        let descriptor = WikiDescriptor.make(displayName: legacyImportDisplayName)
        let target = containerDirectory.appendingPathComponent(
            "\(descriptor.id.rawValue).sqlite", isDirectory: false)
        guard !fm.fileExists(atPath: target.path) else { return }

        do {
            try fm.moveItem(at: legacy, to: target)
            // Move the WAL sidecars too so no committed-but-uncheckpointed data
            // is stranded. Missing sidecars are fine (already checkpointed).
            for suffix in ["-wal", "-shm"] {
                let from = URL(fileURLWithPath: legacy.path + suffix)
                let to = URL(fileURLWithPath: target.path + suffix)
                if fm.fileExists(atPath: from.path) {
                    DebugLog.trying("importLegacyWiki move sidecar", operation: { try fm.moveItem(at: from, to: to) })
                }
            }
            registry.add(descriptor)
            DebugLog.trying("importLegacyWiki save", operation: { try registry.save(to: containerDirectory) })
            DebugLog.store(
                "wikid: legacy v0 import landed \(descriptor.id.rawValue) "
                    + "('\(legacyImportDisplayName)') into the registry")
        } catch {
            DebugLog.store("wikid: legacy migration failed: \(error)")
        }
    }
}
#endif
