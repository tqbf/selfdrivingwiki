import Foundation
import WikiFSTypes

// pattern: Functional Core — builds the exact per-session asset allowlist.

/// Builds the immutable per-session asset admission allowlist for the
/// revision-5 `assetRead` authority, from the reference-extractor records and
/// the page/source's established sibling/File Provider projection.
///
/// This is renderer-neutral: it never tests for a JSON Canvas identity,
/// MIME, extension, node type, or package ID. It only resolves validated
/// relative references against the sibling context, requires a UNIQUE match,
/// and pins each to its typed `SourceID` and the EXACT active
/// `SourceVersionID` (plus MIME, byte count, and digest) before any session
/// exists.
public enum RendererAssetAdmissionBuilder {
    public enum BuildError: Error, Equatable, Sendable {
        case ambiguousReference(String)
        case unsupportedReferenceMIME(String)
        case oversizedReference
        case duplicateReference
    }

    /// The admission input the host resolves before session creation: one row
    /// per extractor record, with the resolved typed source facts.
    public struct AdmissionRow: Sendable, Equatable {
        public let reference: RendererAssetReference
        public let sourceID: SourceID
        public let sourceVersionID: SourceVersionID
        public let mimeType: String
        public let expectedByteCount: Int
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

    /// Resolve every unique extractor record against the sibling context.
    ///
    /// - Parameters:
    ///   - records: ordered extractor records (`{role, reference}`), already
    ///     validated for shape and count.
    ///   - resolveSourceFacts: host seam that converts a unique sibling match
    ///     into the typed SourceID and pins its active version's MIME, byte
    ///     count, and digest. Returns nil when the source cannot be resolved
    ///     or its active version is unavailable; such references fall back
    ///     (they are skipped, not fatal).
    ///   - allowedRoles: the declared asset roles for this session.
    ///   - maximumBytesPerAsset: the declared per-asset byte cap.
    public static func buildAdmissions(
        records: [RendererAssetReferenceExtractorClient.ExtractedRecord],
        resolveSourceFacts: (String) throws -> (sourceID: SourceID, sourceVersionID: SourceVersionID, mimeType: String, byteCount: Int, digest: String)?,
        allowedRoles: Set<RendererAssetRole>,
        maximumBytesPerAsset: Int
    ) throws -> [RendererAuthorizedAssetReader.Admission] {
        var admissions: [RendererAuthorizedAssetReader.Admission] = []
        var seen = Set<RendererAssetReference>()
        for record in records {
            // Role gating: the host stores no format knowledge; the declared
            // role set from the manifest is the only gate.
            guard allowedRoles.contains(record.role) else { continue }
            let reference: RendererAssetReference
            do {
                reference = try RendererAssetReference(validating: record.reference)
            } catch {
                throw BuildError.unsupportedReferenceMIME(record.reference)
            }
            guard seen.insert(reference).inserted else {
                throw BuildError.duplicateReference
            }
            // A reference not present in the sibling context falls back
            // (the image is unavailable) rather than broadening authority or
            // failing the whole canvas.
            guard let facts = try resolveSourceFacts(record.reference) else { continue }
            guard facts.byteCount >= 0, facts.byteCount <= maximumBytesPerAsset else {
                throw BuildError.oversizedReference
            }
            admissions.append(RendererAuthorizedAssetReader.Admission(
                reference: reference,
                sourceID: facts.sourceID,
                sourceVersionID: facts.sourceVersionID,
                mimeType: facts.mimeType,
                expectedByteCount: facts.byteCount,
                expectedDigest: facts.digest))
        }
        return admissions
    }
}
