#if os(macOS)
import Foundation
import WikiFSCore

// pattern: Imperative Shell

/// Host-owned private staging for one speech job's acquired audio.
///
/// The fetcher's bytes land here transiently — never as a source blob — and
/// are removed on success, error, and cancellation. Safety properties:
///
/// - The stage root is owner-private (0700); staged files are 0600.
/// - One stage directory is keyed by queue item and attempt.
/// - An `flock` lease file is held for the whole analysis: a live host keeps
///   its stage; a crashed host's lease dies with the process.
/// - Startup sweeps ONLY unlocked stages whose mtime proves abandonment;
///   active or unknown-owner stages are kept, and symlinks or paths leaving
///   the root are rejected rather than followed.
public struct SpeechStageManager: Sendable {
    /// The owner-private stage root (created 0700).
    public let root: URL
    /// A stage older than this, with NO live lease, is proven abandoned.
    public static let abandonmentThreshold: Duration = .seconds(6 * 60 * 60)
    /// Preflight margin: the fetcher holds up to 120 MiB resident while the
    /// stage write persists a second copy; disk must hold both plus margin.
    public static let minimumFreeBytes: Int64 = 2 * 120 * 1024 * 1024 + 256 * 1024 * 1024

    public init(root: URL) {
        self.root = root
    }

    /// Errors raised by staging. Fixed redacted text.
    public enum StageError: Error, Equatable, LocalizedError {
        case outOfDisk
        case tooLarge
        case unsafePath
        case writeFailed

        public var errorDescription: String? {
            switch self {
            case .outOfDisk: return "Not enough free disk space for this transcription."
            case .tooLarge: return "The acquired audio exceeds the supported size."
            case .unsafePath: return "The staging location is not safe to use."
            case .writeFailed: return "The staging directory could not be written."
            }
        }
    }

    /// One staged acquisition: the audio file plus the lease handle.
    public struct StagedAudio: Sendable {
        public let audioURL: URL
        /// The open lease descriptor. Call `release()` when analysis ends —
        /// success, error, or cancellation — before removal.
        public let lease: Lease

        public func discard() {
            lease.release()
        // Best-effort cleanup on every exit path: a failed removal leaves a stage the next startup sweep reclaims once the lease dies.
        // swiftlint:disable:next silent_try_optional
            try? FileManager.default.removeItem(at: audioURL.deletingLastPathComponent())
        }
    }

    /// An `flock`-held lease over one stage directory. `@unchecked Sendable`
    /// is safe: the only mutable state is `released`, an idempotent close
    /// flag; the descriptor itself is only ever closed once and never
    /// re-read after release (the flock lives in the kernel, not the struct).
    // swiftlint:disable:next unchecked_sendable
    public final class Lease: @unchecked Sendable {
        let fileDescriptor: Int32
        let url: URL
        private(set) var released = false

        init(fileDescriptor: Int32, url: URL) {
            self.fileDescriptor = fileDescriptor
            self.url = url
        }

        deinit {
            release()
        }

        public func release() {
            guard !released else { return }
            released = true
            close(fileDescriptor)
        }

        var isHeld: Bool { !released }
    }

    // MARK: - Staging

    /// Preflights disk, writes `bytes` atomically into a fresh keyed stage,
    /// and acquires the lease. The bytes are written from the fetcher's
    /// resident `Data` without a second full in-memory copy (direct buffer
    /// write).
    public func stage(
        bytes: Data,
        wikiID: WikiID,
        itemID: QueueItem.ID,
        attempt: Int
    ) throws -> StagedAudio {
        try Self.ensureOwnerPrivateRoot(root)
        guard Self.freeDiskBytes(at: root) >= Self.minimumFreeBytes else {
            throw StageError.outOfDisk
        }
        guard bytes.count <= Self.maximumStagedBytes else {
            throw StageError.tooLarge
        }
        let stageDirectory = Self.stageDirectory(
            root: root, wikiID: wikiID, itemID: itemID, attempt: attempt)
        guard Self.isSafeStagePath(stageDirectory, inside: root) else {
            throw StageError.unsafePath
        }
        // A stage directory for the SAME item+attempt is a retry: its
        // previous dispatch cannot be analyzing concurrently (one dispatch
        // per item). Remove it only when no lease is held; a held lease
        // means an unknown host still owns the location — refuse.
        if FileManager.default.fileExists(atPath: stageDirectory.path) {
            guard Self.leaseIsFree(in: stageDirectory) else {
                throw StageError.unsafePath
            }
            // Ignoring the removal error is correct: a leftover directory is
            // recreated below either way (createDirectory with
            // intermediates tolerates it); the failure would only mean a
            // stale file remains, which the write path overwrites.
            // swiftlint:disable:next silent_try_optional
            try? FileManager.default.removeItem(at: stageDirectory)
        }
        try FileManager.default.createDirectory(
            at: stageDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let lease = try Self.acquireLease(in: stageDirectory)
        do {
            let audioURL = stageDirectory.appendingPathComponent("audio.m4a")
            try Self.writeAtomically(bytes, to: audioURL)
            return StagedAudio(audioURL: audioURL, lease: lease)
        } catch {
            lease.release()
        // A stale retry directory is recreated below either way; a failed removal only leaves a file the write path overwrites.
        // swiftlint:disable:next silent_try_optional
            try? FileManager.default.removeItem(at: stageDirectory)
            throw StageError.writeFailed
        }
    }

    /// The upper bound on one staged file: the fetcher's declared cap.
    public static let maximumStagedBytes = 120 * 1024 * 1024

    static func stageDirectory(
        root: URL, wikiID: WikiID, itemID: QueueItem.ID, attempt: Int
    ) -> URL {
        // Wiki and item IDs are typed ULID strings; the attempt is a
        // non-negative integer. No free-form path component ever enters.
        root
            .appendingPathComponent(wikiID.rawValue, isDirectory: true)
            .appendingPathComponent("\(itemID.rawValue)-\(attempt)", isDirectory: true)
    }

    /// Only paths structurally inside the root are ever touched. The
    /// directory name is typed-ID-shaped; this re-checks the resolved path.
    static func isSafeStagePath(_ url: URL, inside root: URL) -> Bool {
        let standardized = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        guard standardized.hasPrefix(rootPath + "/") else { return false }
        // Reject symlinked components at construction: every component of
        // the RELATIVE path must be a plain name.
        let relative = String(standardized.dropFirst(rootPath.count + 1))
        return relative.split(separator: "/").allSatisfy { component in
            component != "." && component != ".."
                && !component.hasPrefix(".")
                && component.contains("/") == false
        }
    }

    static func ensureOwnerPrivateRoot(_ root: URL) throws {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var status = stat()
        guard lstat(root.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == getuid() else {
            throw StageError.unsafePath
        }
        // Tighten like the shared cache roots: a pre-existing root keeps its
        // old mode; ownership makes the chmod safe.
        guard chmod(root.path, 0o700) == 0 else {
            throw StageError.unsafePath
        }
    }

    static func freeDiskBytes(at url: URL) -> Int64 {
        // Best-effort cleanup: a failure here loses nothing and is reclaimed on the next sweep.
        // swiftlint:disable:next silent_try_optional
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let capacity = values?.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        return Int64.max
    }

    /// Writes via a temporary sibling then renames, with 0600 on the file.
    /// The caller's `Data` is written directly — no second resident copy.
    static func writeAtomically(_ bytes: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(destination.lastPathComponent + ".partial")
        // O_EXCL refuses to clobber a leftover partial from an earlier crash;
        // a stale partial is removed first so this write can proceed.
        if FileManager.default.fileExists(atPath: temporary.path) {
            // A stale partial from a crashed attempt: removal must succeed
            // for O_EXCL below, and its failure surfaces as the write error.
            // swiftlint:disable:next silent_try_optional
            try? FileManager.default.removeItem(at: temporary)
        }
        let descriptor = open(
            temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw StageError.writeFailed }
        defer { close(descriptor) }
        let written = bytes.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            var total = 0
            while total < raw.count {
                let n = write(descriptor, base.advanced(by: total), raw.count - total)
                if n <= 0 { return -1 }
                total += n
            }
            return total
        }
        guard written == bytes.count else {
            // The partial is already a failure artifact; its removal error
            // is never the interesting one.
            // swiftlint:disable:next silent_try_optional
            try? FileManager.default.removeItem(at: temporary)
            throw StageError.writeFailed
        }
        guard rename(temporary.path, destination.path) == 0 else {
            // Same: the partial's removal failure is not the reported error.
            // swiftlint:disable:next silent_try_optional
            try? FileManager.default.removeItem(at: temporary)
            throw StageError.writeFailed
        }
    }

    // MARK: - Lease

    static func acquireLease(in directory: URL) throws -> Lease {
        let leaseURL = directory.appendingPathComponent("lease")
        let descriptor = open(leaseURL.path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { throw StageError.unsafePath }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw StageError.unsafePath
        }
        return Lease(fileDescriptor: descriptor, url: leaseURL)
    }

    /// True when the stage directory's lease can be taken right now — no
    /// live host holds it.
    static func leaseIsFree(in directory: URL) -> Bool {
        let leaseURL = directory.appendingPathComponent("lease")
        let descriptor = open(leaseURL.path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }

    // MARK: - Recovery

    /// Removes ONLY unlocked, proven-abandoned stages. A stage with a live
    /// lease (this or another process) is active and kept; a stage whose
    /// mtime is inside the abandonment window is kept even when unlocked
    /// (its host may have just crashed and not yet restarted). Symlinks and
    /// anything outside the root are rejected, never followed.
    @discardableResult
    public func sweepAbandoned(now: Date = Date()) -> [String] {
        var swept: [String] = []
        // Best-effort cleanup: a failure here loses nothing and is reclaimed on the next sweep.
        // swiftlint:disable:next silent_try_optional
        guard let wikis = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: []) else {
            return swept
        }
        for wikiDirectory in wikis {
            guard Self.isSafeStagePath(wikiDirectory, inside: root),
                  Self.isDirectory(wikiDirectory) else { continue }
        // Best-effort cleanup: a failure here loses nothing and is reclaimed on the next sweep.
        // swiftlint:disable:next silent_try_optional
            let items = (try? FileManager.default.contentsOfDirectory(
                at: wikiDirectory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
                options: [])) ?? []
            for stage in items {
                guard Self.isSafeStagePath(stage, inside: root),
                      Self.isDirectory(stage) else { continue }
                guard Self.leaseIsFree(in: stage) else { continue }
        // Best-effort cleanup: a failure here loses nothing and is reclaimed on the next sweep.
        // swiftlint:disable:next silent_try_optional
                let modified = (try? stage.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .now
                guard now.timeIntervalSince(modified)
                    >= Double(Self.abandonmentThreshold.components.seconds) else { continue }
                // Sweep removal is best-effort by design: a locked or
                // vanished stage simply survives to the next sweep.
                // swiftlint:disable:next silent_try_optional
                if (try? FileManager.default.removeItem(at: stage)) != nil {
                    swept.append(stage.lastPathComponent)
                }
            }
            // Prune an emptied wiki directory.
        // Best-effort cleanup: a failure here loses nothing and is reclaimed on the next sweep.
        // swiftlint:disable:next silent_try_optional
            let remaining = (try? FileManager.default.contentsOfDirectory(
                at: wikiDirectory, includingPropertiesForKeys: nil, options: [])) ?? []
            if remaining.isEmpty {
                // Best-effort empty-wiki pruning in a recovery sweep: a
                // failure leaves an empty directory for the next sweep and
                // loses nothing.
                // swiftlint:disable:next silent_try_optional
                try? FileManager.default.removeItem(at: wikiDirectory)
            }
        }
        return swept
    }

    static func isDirectory(_ url: URL) -> Bool {
        var status = stat()
        // lstat: a symlink is NOT a directory for our purposes.
        guard lstat(url.path, &status) == 0 else { return false }
        return status.st_mode & S_IFMT == S_IFDIR
    }
}
#endif
