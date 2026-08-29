import Foundation
import Darwin
import WikiFSTypes

// Durable extractor credential authorization (issue #1159, PR 2 —
// plans/credential-service.md §"Authorization store").
//
// The APP is the only writer; the app and the daemon read the same durable
// bindings and resolve values independently in their own processes (AC.9).
// The store is a machine-scoped, secret-free JSON file under a credentials
// root in the App Group container, separate from wiki databases and the
// extractor package catalog. Removal of a package never deletes a record:
// grants stay attached to their lineage so a reinstall can show — and revoke
// — the stale grant (plan step 16). Records never transfer across package
// IDs: the authorization ID embeds the exact lineage.

/// File layout for the machine-scoped authorization store.
public struct ExtractorCredentialAuthorizationStoreLayout: Sendable {
    /// `<appGroup>/credentials`
    public let credentialsRoot: URL
    /// `<appGroup>/credentials/extractor-credential-authorizations.json`
    public let fileURL: URL

    public init(appGroupContainerRoot: URL) {
        credentialsRoot = appGroupContainerRoot.appendingPathComponent(
            "credentials", isDirectory: true)
        fileURL = credentialsRoot.appendingPathComponent(
            "extractor-credential-authorizations.json", isDirectory: false)
    }
}

public enum ExtractorCredentialAuthorizationStoreError: Error, Equatable, Sendable {
    case roleMayNotMutate(ExtractorPackageProcessRole)
    case lockAcquisitionTimedOut
    case generationConflict(current: UInt64, expected: UInt64)
    case writeFailed
}

/// Read-only view over the durable authorization snapshot. Safe for the app,
/// the daemon, and the CLI — reading mutates nothing.
public struct ExtractorCredentialAuthorizationReader: Sendable {
    private let fileURL: URL

    public init(layout: ExtractorCredentialAuthorizationStoreLayout) {
        fileURL = layout.fileURL
    }

    /// Load the newest complete snapshot. `nil` when the store is absent
    /// (nothing ever authorized) or unreadable/corrupt (a value-free
    /// diagnostic is logged; callers treat it as "no grants").
    public func snapshot() -> ExtractorCredentialAuthorizationSnapshot? {
        // A missing file is the "nothing ever authorized" state, not an
        // error worth logging.
        // swiftlint:disable:next silent_try_optional
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(
                ExtractorCredentialAuthorizationSnapshot.self, from: data)
        } catch {
            DebugLog.store(
                "ExtractorCredentialAuthorizationReader: unreadable store: \(error)")
            return nil
        }
    }
}

/// Serializes read-modify-write operations across processes via flock plus an
/// in-process gate. The APP process owns the only instance that mutates;
/// constructing a writer with a non-app role throws, and daemon/CLI code has
/// no path to one.
public actor ExtractorCredentialAuthorizationWriter {
    private static let inProcessGate = ExtractorAuthorizationInProcessGate()
    private static let retryBackoff: Duration = .milliseconds(25)

    private let layout: ExtractorCredentialAuthorizationStoreLayout
    private let lockTimeout: Duration
    private let now: @Sendable () -> Date

    public init(
        layout: ExtractorCredentialAuthorizationStoreLayout,
        processRole: ExtractorPackageProcessRole,
        lockTimeout: Duration = .seconds(5),
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard processRole == .app else {
            throw ExtractorCredentialAuthorizationStoreError.roleMayNotMutate(processRole)
        }
        self.layout = layout
        self.lockTimeout = lockTimeout
        self.now = now
    }

    /// Grant (or re-grant) the exact requirement contract: one lineage +
    /// requirement -> one reference, pinned to the computed fingerprint. The
    /// scope parts (registration identity + kinds + MIME types) must be the
    /// SAME values the declaring manifest carries — callers pass them through
    /// from the registration projection.
    public func grant(
        packageID: ExtractorPackageID,
        registrationID: ExtractorRegistrationID,
        kinds: [String],
        mimeTypes: [String],
        requirement: ExtractorCredentialRequirement,
        credentialReference: CredentialReference
    ) async throws -> ExtractorCredentialAuthorizationSnapshot {
        let fingerprint = ExtractorCredentialRequirementFingerprint.compute(
            packageID: packageID.rawValue,
            registrationID: registrationID.rawValue,
            kinds: kinds,
            mimeTypes: mimeTypes,
            requirement: requirement)
        let record = ExtractorCredentialAuthorizationRecord(
            authorizationID: ExtractorCredentialAuthorizationID(
                packageID: packageID, requirementID: requirement.id),
            registrationID: registrationID,
            fingerprint: fingerprint,
            credentialReference: credentialReference,
            authorizedAt: now())
        return try await mutate { snapshot in
            var records = snapshot.records
            records.removeAll { $0.authorizationID == record.authorizationID }
            records.append(record)
            return records
        }
    }

    /// Revoke one lineage + requirement. Removing an absent grant is a no-op.
    public func revoke(
        packageID: ExtractorPackageID,
        requirementID: ExtractorCredentialRequirementID
    ) async throws -> ExtractorCredentialAuthorizationSnapshot {
        let authorizationID = ExtractorCredentialAuthorizationID(
            packageID: packageID, requirementID: requirementID)
        return try await mutate { snapshot in
            snapshot.records.filter { $0.authorizationID != authorizationID }
        }
    }

    /// The locked RMW core: acquire the kernel + in-process locks, reload the
    /// newest snapshot (a corrupt or unreadable store ABORTS the mutation —
    /// it is never destructively reseeded, PR 2 review HIGH-C), apply the
    /// record mutation, publish the replacement through a temp file created
    /// O_EXCL at mode 0600 and verified via fstat before rename (PR 2 review
    /// HIGH-B: chmod-after-rename left an unguaranteed window and logged
    /// failures as successes). All under the lock.
    private func mutate(
        _ body: @Sendable (ExtractorCredentialAuthorizationSnapshot) -> [ExtractorCredentialAuthorizationRecord]
    ) async throws -> ExtractorCredentialAuthorizationSnapshot {
        let descriptor = try await acquireLock()
        defer { releaseLock(descriptor) }
        let current = try readSnapshotLocked()
            ?? ExtractorCredentialAuthorizationSnapshot.empty
        let records = body(current)
        let updated = ExtractorCredentialAuthorizationSnapshot(
            generation: current.generation &+ 1, records: records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(updated)
        } catch {
            // Deterministic encoding of a valid snapshot cannot fail; a
            // failure is a programmer error surfaced as writeFailed.
            DebugLog.store(
                "ExtractorCredentialAuthorizationWriter: encode failed: \(error)")
            throw ExtractorCredentialAuthorizationStoreError.writeFailed
        }
        try publishAtomicallyOwnerOnly(data)
        return updated
    }

    /// Writes `data` to a temp file created O_CREAT | O_EXCL | O_NOFOLLOW at
    /// mode 0600, verifies the OPENED inode via fstat (regular file, owner,
    /// exactly 0600), fsyncs, then renames over the live store. Any failure
    /// leaves the previous store untouched and throws instead of publishing.
    private func publishAtomicallyOwnerOnly(_ data: Data) throws {
        let temporaryURL = layout.fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(layout.fileURL.lastPathComponent).tmp-\(UUID().uuidString.lowercased())")
        let fd = temporaryURL.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        }
        guard fd >= 0 else {
            DebugLog.store(
                "ExtractorCredentialAuthorizationWriter: temp store creation failed: errno \(errno)")
            throw ExtractorCredentialAuthorizationStoreError.writeFailed
        }
        defer { close(fd) }
        let written: Int = data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return -1 }
            var remaining = raw.count
            var total = 0
            while remaining > 0 {
                let count = write(fd, pointer, remaining)
                if count <= 0 { return -1 }
                total += count
                pointer += count
                remaining -= count
            }
            return total
        }
        guard written == data.count else {
            DebugLog.store(
                "ExtractorCredentialAuthorizationWriter: temp store write failed.")
            throw ExtractorCredentialAuthorizationStoreError.writeFailed
        }
        var status = stat()
        guard fstat(fd, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              status.st_mode & 0o777 == 0o600 else {
            DebugLog.store(
                "ExtractorCredentialAuthorizationWriter: temp store mode verification failed.")
            throw ExtractorCredentialAuthorizationStoreError.writeFailed
        }
        guard fsync(fd) == 0 else {
            DebugLog.store(
                "ExtractorCredentialAuthorizationWriter: temp store fsync failed: errno \(errno)")
            throw ExtractorCredentialAuthorizationStoreError.writeFailed
        }
        // rename(2) atomically replaces the live file — no delete window.
        guard rename(temporaryURL.path, layout.fileURL.path) == 0 else {
            DebugLog.store(
                "ExtractorCredentialAuthorizationWriter: rename failed: errno \(errno)")
            throw ExtractorCredentialAuthorizationStoreError.writeFailed
        }
    }

    /// Locked reload. Returns `nil` ONLY for a confirmed-absent file (the
    /// never-authorized state). A read failure or malformed snapshot THROWS:
    /// treating it as empty would let the next grant destructively replace
    /// the complete authorization history (PR 2 review HIGH-C). The corrupt
    /// bytes are preserved for diagnosis.
    private func readSnapshotLocked() throws -> ExtractorCredentialAuthorizationSnapshot? {
        let data: Data
        do {
            data = try Data(contentsOf: layout.fileURL)
        } catch let error as NSError where error.code == NSFileReadNoSuchFileError {
            return nil
        } catch {
            DebugLog.store(
                "ExtractorCredentialAuthorizationWriter: store read failed; mutation aborted: \(error)")
            throw ExtractorCredentialAuthorizationStoreError.writeFailed
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(
                ExtractorCredentialAuthorizationSnapshot.self, from: data)
        } catch {
            DebugLog.store(
                "ExtractorCredentialAuthorizationWriter: corrupt store; mutation aborted (bytes preserved): \(error)")
            throw ExtractorCredentialAuthorizationStoreError.writeFailed
        }
    }

    private var lockURL: URL {
        layout.credentialsRoot.appendingPathComponent(
            "extractor-credential-authorizations.lock", isDirectory: false)
    }

    private func acquireLock() async throws -> Int32 {
        try FileManager.default.createDirectory(
            at: layout.credentialsRoot, withIntermediateDirectories: true)
        let key = lockURL.path
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: lockTimeout)
        while true {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw ExtractorCredentialAuthorizationStoreError.lockAcquisitionTimedOut
            }
            guard await Self.inProcessGate.tryAcquire(key) else {
                try await Task.sleep(for: Self.retryBackoff)
                continue
            }
            let descriptor = key.withCString {
                open($0, O_RDWR | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            }
            guard descriptor >= 0 else {
                await Self.inProcessGate.release(key)
                throw ExtractorCredentialAuthorizationStoreError.writeFailed
            }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                close(descriptor)
                await Self.inProcessGate.release(key)
                if code == EWOULDBLOCK || code == EAGAIN {
                    try await Task.sleep(for: Self.retryBackoff)
                    continue
                }
                throw ExtractorCredentialAuthorizationStoreError.writeFailed
            }
            return descriptor
        }
    }

    private func releaseLock(_ descriptor: Int32) {
        let unlockResult = flock(descriptor, LOCK_UN)
        let closeResult = close(descriptor)
        if unlockResult != 0 || closeResult != 0 {
            DebugLog.store("ExtractorCredentialAuthorizationWriter: lock release failed.")
        }
        Task { await Self.inProcessGate.release(self.lockURL.path) }
    }
}

/// Mirror of `AgentProvidersConfigInProcessGate`: same-process writers queue
/// on the lock path; cross-process writers serialize on flock.
actor ExtractorAuthorizationInProcessGate {
    private var heldPaths: Set<String> = []

    func tryAcquire(_ path: String) -> Bool { heldPaths.insert(path).inserted }
    func release(_ path: String) { heldPaths.remove(path) }
}

// MARK: - Pure resolver

/// One requirement's redacted readiness after authorization resolution.
/// The decision carries identities and states only — never a value and never
/// the reference for a blocked requirement (UI-safe by construction; PR 3's
/// privileged layer re-derives references from the store snapshot).
public struct ExtractorCredentialAuthorizationDecision: Hashable, Sendable {
    public enum State: Hashable, Sendable {
        /// Authorized AND configured: PR 3 may resolve the value.
        case authorized(CredentialReference)
        /// Not authorized (no grant, changed contract, unadmitted package).
        case unauthorized
        /// Authorized but the credential has no stored value.
        case missingCredential(CredentialReference)
    }

    public let requirement: ExtractorCredentialRequirement
    public let state: State

    public var isSatisfied: Bool {
        switch state {
        case .authorized: return true
        case .unauthorized, .missingCredential: return requirement.isOptional
        }
    }

    /// Required unsatisfied requirements BLOCK preparation (AC.10); optional
    /// ones are omitted downstream.
    public var blocksPreparation: Bool { !isSatisfied }
}

/// Pure authorization resolution for one exact registration of one exact
/// admitted revision (AC.8/AC.10/AC.16). Inputs are validated facts; the
/// resolver performs no I/O and never sees a value.
public enum ExtractorCredentialAuthorizationResolver {

    /// Resolve every declared requirement of `registration` against the
    /// current authorization snapshot + credential descriptions.
    ///
    /// - Parameters:
    ///   - package: the exact revision being prepared (lineage identity).
    ///   - manifest: the validated manifest of that exact revision — its
    ///     digest was checked by the caller; the resolver re-checks that the
    ///     revision's registration actually DECLARES each requirement, so a
    ///     stale grant for a requirement this revision no longer declares
    ///     cannot leak a decision.
    ///   - registration: the SELECTED registration for kind + MIME.
    ///   - isAdmitted: current admission state of the exact revision.
    ///   - snapshot: the durable authorization snapshot (nil = no grants).
    ///   - descriptions: UI-safe configured state per reference.
    public static func resolve(
        package packageID: ExtractorPackageID,
        manifest: ExtractorManifest,
        registration: ExtractorRegistration,
        isAdmitted: Bool,
        snapshot: ExtractorCredentialAuthorizationSnapshot?,
        descriptions: [CredentialReference: CredentialInfo]
    ) -> [ExtractorCredentialAuthorizationDecision] {
        // An unadmitted revision (removed, failed activation, superseded)
        // blocks every requirement — declared or granted.
        guard isAdmitted,
              manifest.packageID == packageID,
              let declared = manifest.registrations.first(where: { $0.id == registration.id })
        else {
            return registration.credentialRequirements.map {
                ExtractorCredentialAuthorizationDecision(
                    requirement: $0, state: .unauthorized)
            }
        }
        // The selected registration must be the manifest's own registration
        // (identity + declared requirement set match exactly).
        guard declared == registration else {
            return registration.credentialRequirements.map {
                ExtractorCredentialAuthorizationDecision(
                    requirement: $0, state: .unauthorized)
            }
        }
        return registration.credentialRequirements.map { requirement in
            let authorizationID = ExtractorCredentialAuthorizationID(
                packageID: packageID, requirementID: requirement.id)
            guard let record = snapshot?.record(for: authorizationID),
                  record.fingerprint == ExtractorCredentialRequirementFingerprint.compute(
                    packageID: packageID, registration: registration,
                    requirement: requirement)
            else {
                return ExtractorCredentialAuthorizationDecision(
                    requirement: requirement, state: .unauthorized)
            }
            let reference = record.credentialReference
            let configured = descriptions[reference]?.isConfigured ?? false
            return ExtractorCredentialAuthorizationDecision(
                requirement: requirement,
                state: configured
                    ? .authorized(reference)
                    : .missingCredential(reference))
        }
    }
}
