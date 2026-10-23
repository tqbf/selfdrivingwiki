import Foundation
import WikiFSTypes
import WikiFSLinks

/// One exact ranged repair (REQ-52): half-open AUTHORED UTF-8 byte bounds,
/// the exact expected text at that range, the replacement text, and the
/// short validity reason the hunk carries (REQ-07). A hunk's defect class
/// travels beside it (`PagePatch.defectClasses`, parallel arrays).
///
/// No fuzzy application: the bytes at `body[startByte..<endByte]` must equal
/// `oldText` exactly, or the patch rejects.
public struct PagePatchHunk: Equatable, Sendable, Codable {
    /// Half-open lower bound in the authored body's UTF-8 bytes.
    public let startByte: Int
    /// Half-open upper bound in the authored body's UTF-8 bytes.
    public let endByte: Int
    /// The exact text the patcher must find at the range.
    public let oldText: String
    /// The replacement text (may be empty — a deletion).
    public let newText: String
    /// The short validity reason (REQ-07).
    public let reason: String

    public init(startByte: Int, endByte: Int, oldText: String, newText: String, reason: String) {
        self.startByte = startByte
        self.endByte = endByte
        self.oldText = oldText
        self.newText = newText
        self.reason = reason
    }
}

/// One exact patch write (REQ-52): the target page, the CAS head the hunks
/// were composed against, and the hunk/class pairs. Untouched bytes are
/// preserved by construction — the store's exact-body mode writes ONLY these
/// ranges and never canonicalizes or cosmetically fixes anything else.
public struct PagePatch: Equatable, Sendable {
    public let pageID: PageID
    public let expectHead: PageVersionID
    /// Hunks, in submission order.
    public let hunks: [PagePatchHunk]
    /// Defect classes — MUST be parallel to `hunks` (one class per hunk).
    public let defectClasses: [LintDefectClass]

    public init(pageID: PageID, expectHead: PageVersionID, hunks: [PagePatchHunk], defectClasses: [LintDefectClass]) {
        self.pageID = pageID
        self.expectHead = expectHead
        self.hunks = hunks
        self.defectClasses = defectClasses
    }

    /// The patch payload byte budget (JSON forms included). A repair is a
    /// bounded local edit, not a body rewrite; oversize rejects.
    public static let maxPayloadBytes = 2_000_000

    /// Total authored bytes the hunks would carry.
    public var payloadByteCount: Int {
        hunks.reduce(0) { $0 + $1.oldText.utf8.count + $1.newText.utf8.count + $1.reason.utf8.count }
    }
}

/// The shell-safe `--hunk-file` form: a versioned JSON document carrying the
/// same hunk fields with each hunk's defect class. The inline
/// `--hunk <json> --defect <class>` pairs and this file are mutually
/// exclusive (the parser rejects combining them).
public struct PagePatchHunkFile: Equatable, Sendable, Codable {
    public static let version = 1

    public let version: Int
    public let hunks: [Entry]

    public struct Entry: Equatable, Sendable, Codable {
        public let defect: String
        public let startByte: Int
        public let endByte: Int
        public let oldText: String
        public let newText: String
        public let reason: String

        public init(defect: String, startByte: Int, endByte: Int, oldText: String, newText: String, reason: String) {
            self.defect = defect
            self.startByte = startByte
            self.endByte = endByte
            self.oldText = oldText
            self.newText = newText
            self.reason = reason
        }
    }

    public init(version: Int = PagePatchHunkFile.version, hunks: [Entry]) {
        self.version = version
        self.hunks = hunks
    }
}

/// Why a patch rejected. Typed so the CLI, the daemon, and the evaluation
/// artifacts name the same failure (a rejected patch creates NO version and
/// emits NO event).
public enum PagePatchValidationError: Error, Equatable, CustomStringConvertible {
    /// No hunks (an empty request) or a class count that does not match the
    /// hunk count.
    case emptyOrUnpaired(defectCount: Int, hunkCount: Int)
    /// A class cannot authorize a patch in v1 (report-only / out-of-scope).
    case unsupportedClass(LintDefectClass)
    /// `startByte >= endByte`, a negative bound, or a bound past the body.
    case invalidRange(startByte: Int, endByte: Int, bodyBytes: Int)
    /// A bound does not land on a UTF-8 character boundary.
    case invalidUTF8Boundary(offset: Int)
    /// The exact expected text does not match the authored bytes.
    case oldTextMismatch(startByte: Int, expected: String, actual: String)
    /// Two hunks' ranges overlap (including two insertions at one offset).
    case overlappingRanges(first: PagePatchHunk, second: PagePatchHunk)
    /// The payload exceeds ``PagePatch/maxPayloadBytes``.
    case oversizedPayload(bytes: Int)

    public var description: String {
        switch self {
        case .emptyOrUnpaired(let defectCount, let hunkCount):
            return "patch has \(hunkCount) hunk(s) but \(defectCount) defect class(es) — one class per hunk"
        case .unsupportedClass(let defectClass):
            return "defect class \(defectClass.rawValue) cannot authorize a patch (policy: \(defectClass.repairPolicy.rawValue))"
        case .invalidRange(let startByte, let endByte, let bodyBytes):
            return "hunk range \(startByte)..<\(endByte) is invalid for a body of \(bodyBytes) bytes"
        case .invalidUTF8Boundary(let offset):
            return "hunk bound \(offset) does not land on a UTF-8 character boundary"
        case .oldTextMismatch(let startByte, let expected, let actual):
            return "hunk at byte \(startByte): expected text does not match the stored body — re-read the page (expected \(expected.debugDescription), found \(actual.debugDescription))"
        case .overlappingRanges:
            return "hunk ranges overlap; apply one repair per location"
        case .oversizedPayload(let bytes):
            return "patch payload is \(bytes) bytes; the budget is \(PagePatch.maxPayloadBytes)"
        }
    }
}

/// Pure patch validation + composition — no store, no I/O (REQ-39: detectors
/// and repairs never silently rewrite; the STORE applies this under its own
/// transaction and CAS check).
public enum PagePatchValidator {

    /// Validate `patch` against `body` and return the composed replacement
    /// body. All hunks apply against ONE original snapshot, in reverse range
    /// order, so an earlier hunk can never shift a later range.
    public static func composedBody(applying patch: PagePatch, to body: String) throws -> String {
        guard !patch.hunks.isEmpty, patch.hunks.count == patch.defectClasses.count else {
            throw PagePatchValidationError.emptyOrUnpaired(
                defectCount: patch.defectClasses.count, hunkCount: patch.hunks.count)
        }
        for defectClass in patch.defectClasses where defectClass.repairPolicy != .repairable {
            throw PagePatchValidationError.unsupportedClass(defectClass)
        }
        let byteCount = body.utf8.count
        guard patch.payloadByteCount <= PagePatch.maxPayloadBytes else {
            throw PagePatchValidationError.oversizedPayload(bytes: patch.payloadByteCount)
        }

        let utf8 = Array(body.utf8)
        // Validate every hunk against the ORIGINAL snapshot.
        var ordered = patch.hunks.enumerated().map { ($0.offset, $0.element) }
        ordered.sort { $0.1.startByte < $1.1.startByte }
        var previous: PagePatchHunk?
        for (_, hunk) in ordered {
            guard hunk.startByte >= 0, hunk.endByte >= hunk.startByte, hunk.endByte <= byteCount else {
                throw PagePatchValidationError.invalidRange(
                    startByte: hunk.startByte, endByte: hunk.endByte, bodyBytes: byteCount)
            }
            for bound in [hunk.startByte, hunk.endByte] where bound > 0 && bound < byteCount {
                guard utf8[bound] & 0xC0 != 0x80 else {
                    throw PagePatchValidationError.invalidUTF8Boundary(offset: bound)
                }
            }
            let actual = String(decoding: utf8[hunk.startByte..<hunk.endByte], as: UTF8.self)
            guard actual == hunk.oldText else {
                throw PagePatchValidationError.oldTextMismatch(
                    startByte: hunk.startByte, expected: hunk.oldText, actual: actual)
            }
            if let previous {
                // Overlap (a zero-length hunk at the SAME offset as another
                // insertion also rejects — repeated insertion positions).
                if hunk.startByte < previous.endByte
                    || (hunk.startByte == previous.startByte && hunk.endByte == previous.endByte) {
                    throw PagePatchValidationError.overlappingRanges(first: previous, second: hunk)
                }
            }
            previous = hunk
        }

        // Apply in reverse range order over the original snapshot.
        var composed = body
        for hunk in patch.hunks.sorted(by: { $0.startByte > $1.startByte }) {
            let start = composed.utf8.index(composed.utf8.startIndex, offsetBy: hunk.startByte)
            let end = composed.utf8.index(composed.utf8.startIndex, offsetBy: hunk.endByte)
            composed.replaceSubrange(start..<end, with: hunk.newText)
        }
        return composed
    }

    /// Source citations the patch ADDS or CHANGES: the source targets in the
    /// composed body whose (target, fragment, pin, embed) form was not
    /// present in the original. Integrity checks (REQ-54) run over exactly
    /// these.
    public static func addedSourceCitations(original: String, composed: String) -> [ParsedLink] {
        var before = multiset(of: WikiLinkParser.parse(original).filter { $0.linkType == .source })
        var added: [ParsedLink] = []
        for link in WikiLinkParser.parse(composed) where link.linkType == .source {
            let key = key(for: link)
            if let count = before[key], count > 0 {
                before[key] = count - 1
            } else {
                added.append(link)
            }
        }
        return added
    }

    /// `ParsedLink` is `Equatable` but not `Hashable`; key the multiset on
    /// its full field tuple instead of adding conformances to a shared type.
    private static func multiset(of links: [ParsedLink]) -> [[String]: Int] {
        var counts: [[String]: Int] = [:]
        for link in links { counts[key(for: link), default: 0] += 1 }
        return counts
    }

    private static func key(for link: ParsedLink) -> [String] {
        [link.linkType.rawValue, link.target, link.fragment ?? "", link.linkText,
         link.isEmbed ? "1" : "0", link.versionPin ?? ""]
    }
}
