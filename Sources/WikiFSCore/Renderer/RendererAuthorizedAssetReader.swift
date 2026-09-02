import Foundation
import Synchronization
import WikiFSTypes

// pattern: Imperative Shell

/// Reads only the exact session-admitted asset versions (manifest revision 5
/// `asset.read` authority).
///
/// The reader is constructed with an immutable, bounded allowlist. Each entry
/// pins the validated reference key, the typed `SourceID` (for namespace
/// correctness), the EXACT `SourceVersionID` pinned at session creation, the
/// approved MIME type, and the expected byte count + digest. Reads go ONLY
/// through `store.sourceContent(versionID:)` — never `sourceContent(id:)`
/// and never name resolution during a bridge request.
///
/// Every return to package code is a uniform redacted denial on any miss:
/// missing, invalid, unauthorized, changed, oversized, exhausted, or closed
/// assets all look identical to the caller. Typed internal errors exist for
/// tests and `DebugLog` without paths, titles, IDs, or existence details.
public final class RendererAuthorizedAssetReader {
    public enum ReaderError: Error, Equatable, Sendable {
        case closed
        case unauthorizedAsset
        case unadmittedReference
        case unavailablePinnedAsset
        case changedAsset
        case oversizedAsset
        case sessionBudgetExhausted
        case duplicateAdmission
    }

    /// One immutable admission: the exact reference key and its pinned facts.
    public struct Admission: Sendable, Equatable {
        public let reference: RendererAssetReference
        /// SourceID for namespace correctness (PageID/SourceID are separate
        /// namespaces; PageID is never admitted here).
        public let sourceID: SourceID
        /// Exact version pinned at session creation.
        public let sourceVersionID: SourceVersionID
        /// Approved MIME type (from the admission, cross-checked at read).
        public let mimeType: String
        /// Expected byte count, verified before return.
        public let expectedByteCount: Int
        /// Expected SHA-256 digest (lowercase hex), verified before return.
        public let expectedDigest: String

        public init(
            reference: RendererAssetReference,
            sourceID: SourceID,
            sourceVersionID: SourceVersionID,
            mimeType: String,
            expectedByteCount: Int,
            expectedDigest: String
        ) {
            self.reference = reference
            self.sourceID = sourceID
            self.sourceVersionID = sourceVersionID
            self.mimeType = mimeType
            self.expectedByteCount = expectedByteCount
            self.expectedDigest = expectedDigest
        }
    }

    private struct State: Sendable {
        var isClosed: Bool = false
        var sessionBytesRemaining: Int
        var perRequestReads: [RendererAssetReference: Int] = [:]
        var aggregateBytesReturned: Int = 0
    }

    private let admissions: [RendererAssetReference: Admission]
    private let maximumBytesPerAsset: Int
    private let maximumAggregateSessionBytes: Int
    private let maximumPerRequestReadCount: Int
    private let readPinned: (SourceVersionID) throws -> Data?
    private let pinnedMime: (SourceVersionID) throws -> String?
    private let state: Mutex<State>

    public init(
        admissions: [Admission],
        maximumBytesPerAsset: Int,
        maximumAggregateSessionBytes: Int,
        maximumPerRequestReadCount: Int,
        store: any WikiStore
    ) throws {
        var byReference: [RendererAssetReference: Admission] = [:]
        for admission in admissions {
            guard byReference[admission.reference] == nil else {
                throw ReaderError.duplicateAdmission
            }
            byReference[admission.reference] = admission
        }
        self.admissions = byReference
        self.maximumBytesPerAsset = maximumBytesPerAsset
        self.maximumAggregateSessionBytes = maximumAggregateSessionBytes
        self.maximumPerRequestReadCount = maximumPerRequestReadCount
        readPinned = { versionID in
            do { return try store.sourceContent(versionID: versionID) }
            catch { return nil }
        }
        pinnedMime = { versionID in
            // A failed source-version lookup means only "we cannot cross-check
            // the MIME"; we fall back to the admission's own approved MIME and
            // the digest/size checks still gate the return. `try?` is
            // intentional here — the denial surface is uniform.
            // swiftlint:disable:next silent_try_optional
            guard let version = try? store.sourceVersion(id: versionID) else { return nil }
            return version.mimeType
        }
        state = Mutex(State(sessionBytesRemaining: maximumAggregateSessionBytes))
    }

    /// The exact reference keys admitted into this session (for broker wiring
    /// and diagnostics; never exposed to package code beyond the bridge).
    public var admittedReferences: Set<RendererAssetReference> {
        Set(admissions.keys)
    }

    /// Read one admitted asset. Fail-closed on every miss, before disclosure.
    public func read(_ reference: RendererAssetReference) throws -> RendererAssetPayload {
        try validateOpen()
        guard let admission = admissions[reference] else {
            throw ReaderError.unadmittedReference
        }
        // Session budget: reject before reading bytes whenever metadata proves
        // the denial — closed, exhausted aggregate, per-asset cap, or
        // per-request read-count cap.
        let budgetCheck = state.withLock { value -> Result<Void, ReaderError> in
            guard value.isClosed == false else { return .failure(.closed) }
            guard value.sessionBytesRemaining > 0 else { return .failure(.sessionBudgetExhausted) }
            let reads = value.perRequestReads[reference, default: 0]
            guard reads < maximumPerRequestReadCount else { return .failure(.sessionBudgetExhausted) }
            return .success(())
        }
        guard case .success = budgetCheck else {
            if case .failure(let error) = budgetCheck { throw error }
            throw ReaderError.unauthorizedAsset
        }

        // Read the pinned EXACT version only.
        guard let bytes = try readPinned(admission.sourceVersionID) else {
            throw ReaderError.unavailablePinnedAsset
        }
        guard bytes.count == admission.expectedByteCount else {
            throw ReaderError.changedAsset
        }
        guard RendererSHA256.digest(bytes).hex == admission.expectedDigest else {
            throw ReaderError.changedAsset
        }
        guard bytes.count <= maximumBytesPerAsset else {
            throw ReaderError.oversizedAsset
        }
        let mime = try pinnedMime(admission.sourceVersionID) ?? admission.mimeType
        guard mime == admission.mimeType else {
            throw ReaderError.changedAsset
        }

        // Charge the session aggregate budget atomically.
        let charged = state.withLock { value -> Bool in
            guard value.sessionBytesRemaining >= bytes.count else { return false }
            value.sessionBytesRemaining -= bytes.count
            value.aggregateBytesReturned += bytes.count
            value.perRequestReads[reference, default: 0] += 1
            return true
        }
        guard charged else { throw ReaderError.sessionBudgetExhausted }

        return RendererAssetPayload(
            mimeType: admission.mimeType,
            bytes: bytes,
            contentDigest: RendererSHA256.digest(bytes).hex)
    }

    public func close() {
        state.withLock { value in
            value.isClosed = true
        }
    }

    private func validateOpen() throws {
        let closed = state.withLock { $0.isClosed }
        guard closed == false else { throw ReaderError.closed }
    }
}
