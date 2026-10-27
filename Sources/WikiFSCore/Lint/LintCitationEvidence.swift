import Foundation
import WikiFSLinks

// MARK: - Version pins

/// A positive 1-based ordinal selecting one derived source-markdown version
/// (`@vN`, oldest = v1 — the product's `@vN` contract, resolved by the
/// store's `resolveVersionPin`). Zero and negative ordinals are not
/// expressible; decoding rejects them so a malformed pin never masquerades
/// as `v0`.
public struct LintSourceVersionPin: Hashable, Codable, Sendable {
    public let ordinal: UInt

    public init?(ordinal: UInt) {
        guard ordinal >= 1 else { return nil }
        self.ordinal = ordinal
    }

    /// Decode a pin literal (`splitVersionPin`'s digits string) at the syntax
    /// boundary. `nil` for empty, non-digit, or zero text.
    public init?(decoding literal: String) {
        guard !literal.isEmpty, literal.allSatisfy(\.isWholeNumber),
              let value = UInt(literal), value >= 1 else { return nil }
        self.ordinal = value
    }

    public var rawValue: String { String(ordinal) }
}

/// How one citation occurrence requests its source version. `.active` is the
/// UNPINNED form: whatever the reader's head lookup resolves (the
/// `source-derived` ref, else the newest ULID). `.pinned` is an explicit
/// `@vN`. They are distinct cases so lint can never treat an unpinned
/// citation as "pinned to whatever happens to be newest". `.invalidPin`
/// preserves an authored-but-undecodable pin (`@v0`, `@v-1`) so the check
/// reports it instead of silently loading the active version.
public enum LintSourceVersionRequest: Hashable, Sendable {
    case active
    case pinned(LintSourceVersionPin)
    case invalidPin(literal: String)

    /// The decoded pin when explicitly and validly pinned, else nil.
    public var pin: LintSourceVersionPin? {
        if case .pinned(let pin) = self { return pin }
        return nil
    }
}

// MARK: - Capture limits

/// The named capture budgets. Every clamp in the store's lint capture names
/// one of these; the typed notices cite them by name.
public enum LintCaptureLimits {
    /// Distinct source-version targets captured per run.
    public static let maxSourceVersionTargets = 32
    /// Bytes of processed-markdown text retained per source-version record.
    public static let maxBytesPerSourceVersion = 512 * 1024
    /// Aggregate bytes of captured source text per run.
    public static let maxAggregateSourceBytes = 4 * 1024 * 1024
    /// Bytes of parent (previous page version) body text retained.
    public static let maxParentBodyBytes = 512 * 1024
    /// Cap on recorded citation occurrences per run (a page citing more than
    /// this many occurrences has the remainder dropped with a notice).
    public static let maxCitationOccurrences = 512

    /// Clip `text` to at most `limit` UTF-8 bytes WITHOUT splitting a Unicode
    /// scalar: the cut point backs off any continuation bytes so the result
    /// decodes cleanly. Returns the (possibly complete) text and the
    /// ORIGINAL byte count.
    public static func clipped(_ text: String, byteLimit limit: Int) -> (text: String, originalByteCount: Int) {
        let view = text.utf8
        let original = view.count
        guard original > limit else { return (text, original) }
        var end = view.index(view.startIndex, offsetBy: limit)
        // 0b10xxxxxx continuation byte → inside a multi-byte scalar; back off.
        while end > view.startIndex, view[end] & 0xC0 == 0x80 {
            view.formIndex(before: &end)
        }
        return (String(decoding: view[..<end], as: UTF8.self), original)
    }
}

// MARK: - Completeness

/// Whether retained text is the whole version or only a byte-bounded prefix.
/// `prefix` always carries the original byte count so callers can state how
/// much was not read.
public enum LintEvidenceCompleteness: Hashable, Sendable {
    case complete
    case prefix(originalByteCount: Int)

    /// True when the retained text is the whole content.
    public var isComplete: Bool {
        if case .complete = self { return true }
        return false
    }
}

// MARK: - Citation occurrences

/// One authored citation occurrence (`[[source:…]]` link, never an embed)
/// with its identity, version request, and exact authored range.
///
/// Parsed through `WikiLinkSpan` + the `syntaxNodes` overlay, so fenced,
/// inline-code, locally-code-wrapped, and escaped occurrences are already
/// excluded, and alias-free links, aliases, canonical IDs, names, `@vN`
/// pins, quote fragments, and heading fragments are all supported. This is
/// NOT the retired alias-required regex contract.
public struct LintCitationOccurrence: Hashable, Sendable {
    /// Canonical source id when the target is a ULID (uppercased).
    public let canonicalSourceID: String?
    /// The authored bare target when it is a NAME (not a canonical ULID).
    public let sourceName: String?
    /// The version request: unpinned-active or a decoded `@vN` pin.
    public let request: LintSourceVersionRequest
    /// The quote text when the fragment is a quote anchor (`#"…"`): the
    /// reader's quote — boundary `"` characters trimmed, verbatim otherwise.
    public let quote: String?
    /// The heading fragment when the fragment is NOT a quote anchor.
    public let headingFragment: String?
    /// The authored alias (readable text), when present.
    public let alias: String?
    /// Validated UTF-8 byte range of the whole `[[…]]` span in the body.
    public let range: LintSourceRange
    /// The exact authored span text.
    public let authoredLiteral: String
    /// 1-based first-authored order across the page.
    public let order: Int
}

// MARK: - Source capture status

/// Why one source-version record does or does not carry text. Each case is
/// explicit — a missing dictionary entry is never read as "broken".
public enum LintSourceCaptureStatus: Hashable, Sendable {
    /// The requested version was read; `text` holds the (possibly prefix-
    /// clamped) content.
    case present
    /// No source row with that id exists.
    case missingTarget
    /// The source exists but the requested pin resolves to no version
    /// (`@vN` past the end of the derived chain).
    case missingVersion
    /// The source exists but has no processed markdown at all (no ref, no
    /// versions) — the extraction leg of capture is unavailable.
    case unavailableExtraction
    /// The database read itself failed.
    case readFailed
    /// A capture budget was exhausted before this target was read.
    case budgetOmitted
}

/// One source-version capture record: identity, requested pin, resolved
/// version, captured text, and completeness. Present-complete,
/// present-prefix, missing target, missing version, unavailable extraction,
/// read failure, and budget omission are all represented explicitly.
public struct LintCapturedSourceVersion: Hashable, Sendable {
    public let sourceID: SourceID
    public let request: LintSourceVersionRequest
    /// The concrete derived-markdown version id when one resolved.
    public let resolvedVersionID: SourceMarkdownVersionID?
    public let status: LintSourceCaptureStatus
    /// The captured text when `status == .present` (complete or prefix).
    public let text: String?
    public let completeness: LintEvidenceCompleteness?
    /// SHA-256 hex over the captured text's UTF-8 bytes (nil unless text).
    public let digest: String?
    /// The ORIGINAL version byte count when text was clamped to a prefix.
    public let originalByteCount: Int?

    public init(
        sourceID: SourceID,
        request: LintSourceVersionRequest,
        resolvedVersionID: SourceMarkdownVersionID?,
        status: LintSourceCaptureStatus,
        text: String?,
        completeness: LintEvidenceCompleteness?,
        digest: String?,
        originalByteCount: Int?
    ) {
        self.sourceID = sourceID
        self.request = request
        self.resolvedVersionID = resolvedVersionID
        self.status = status
        self.text = text
        self.completeness = completeness
        self.digest = digest
        self.originalByteCount = originalByteCount
    }

    public var isPresent: Bool {
        if case .present = status { return true }
        return false
    }

    /// True when the captured text is the complete version content.
    public var isComplete: Bool {
        guard case .present = status else { return false }
        return completeness == .complete
    }
}

// MARK: - Parent (history) capture

/// The status of the captured page's parent version (the head's `parent_id`).
public enum LintParentCaptureStatus: Hashable, Sendable {
    /// The parent row was read; `text` holds the (possibly clamped) body.
    case captured
    /// The head is the first version — history comparison is not applicable.
    case firstVersion
    /// The head declares a parent id but the row (or its blob) is gone —
    /// unavailable history, never an empty parent.
    case unavailable
    /// The parent read failed.
    case readFailed
    /// A capture budget was exhausted before the parent was read.
    case budgetOmitted
}

/// The captured parent of the page's head version. Retains the parent id,
/// body digest, bounded body text, and completeness. Comparison verdicts
/// stay with the checks; capture only records facts.
public struct LintCapturedParentVersion: Hashable, Sendable {
    public let status: LintParentCaptureStatus
    public let parentVersionID: PageVersionID?
    /// SHA-256 hex over the FULL parent body's UTF-8 bytes when the parent
    /// body was read (digest is over the unclamped content).
    public let bodyDigest: String?
    /// The bounded parent body text when captured.
    public let text: String?
    public let completeness: LintEvidenceCompleteness?

    public init(
        status: LintParentCaptureStatus,
        parentVersionID: PageVersionID?,
        bodyDigest: String?,
        text: String?,
        completeness: LintEvidenceCompleteness?
    ) {
        self.status = status
        self.parentVersionID = parentVersionID
        self.bodyDigest = bodyDigest
        self.text = text
        self.completeness = completeness
    }
}

// MARK: - Capture notices

/// A typed, user-visible limitation of the capture. Surfaced in the lint
/// window — never folded into findings and never silently dropped.
public struct LintCaptureNotice: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        case sourceVersionTargetLimit
        case aggregateSourceTextLimit
        case parentTextLimit
        case citationOccurrenceLimit
    }

    public let id: String
    public let kind: Kind
    public let message: String

    public init(kind: Kind, message: String) {
        self.id = "\(kind.rawValue)-\(message.hashValue)"
        self.kind = kind
        self.message = message
    }
}

// MARK: - Source name index

/// One source row's identity facts, in the store's newest-first order.
public struct LintSourceIdentity: Hashable, Sendable {
    public let id: SourceID
    /// `COALESCE(display_name, filename)` — the store's effective name.
    public let effectiveName: String
    public let filename: String

    public init(id: SourceID, effectiveName: String, filename: String) {
        self.id = id
        self.effectiveName = effectiveName
        self.filename = filename
    }
}

/// The outcome of resolving an authored source NAME through the index.
/// Ambiguity is a distinct outcome carrying the candidate ids — the check
/// never collapses duplicates into a Boolean or picks arbitrarily.
public enum LintSourceNameResolution: Equatable, Sendable {
    case resolved(SourceID)
    /// The name tier matched multiple distinct sources (candidates listed).
    case ambiguous([SourceID])
    case missing
}

/// Normalized-name-to-`[SourceID]` multiplicity index over captured source
/// rows. Resolution mirrors the store's actual `resolveSourceByName`
/// precedence (exact → legacy projection → extension-stripped → loose-key
/// unique) but EXPOSES ambiguity at a tier with multiple candidates instead
/// of silently keeping the newest row. Pure — no database access.
public struct LintSourceNameIndex: Hashable, Sendable {
    /// The captured identities (newest-first, matching the resolver's
    /// `ORDER BY updated_at DESC` precedence).
    public let identities: [LintSourceIdentity]
    public let isAvailable: Bool

    public init(identities: [LintSourceIdentity], isAvailable: Bool = true) {
        self.identities = identities
        self.isAvailable = isAvailable
    }

    public static let unavailable = LintSourceNameIndex(identities: [], isAvailable: false)

    private static func exactKey(_ name: String) -> String { name.lowercased() }

    /// Resolve an authored name through the same precedence the store's
    /// resolver applies, reporting ambiguity when a tier matches several
    /// distinct ids.
    public func resolve(name: String) -> LintSourceNameResolution {
        guard isAvailable, !identities.isEmpty else { return .missing }
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .missing }

        // Pass 1: exact effective-name (or filename) match, NOCASE. The
        // store keeps the newest; here multiple distinct ids in the tier are
        // ambiguity, a single id resolves.
        let exactMatches = identities.filter {
            Self.exactKey($0.effectiveName) == Self.exactKey(query)
                || Self.exactKey($0.filename) == Self.exactKey(query)
        }
        if exactMatches.count == 1 { return .resolved(exactMatches[0].id) }
        if exactMatches.count > 1 { return .ambiguous(Self.uniqueIDs(exactMatches)) }

        // Legacy pre-short-ID projection form: `<filename>–<full-id>.md`
        // resolves by its embedded id when that row exists.
        if let projected = WikiLinkResolver.legacySourceProjectionID(from: query) {
            let upper = projected.rawValue.uppercased()
            if let match = identities.first(where: { $0.id.rawValue.uppercased() == upper }) {
                return .resolved(match.id)
            }
        }

        // Pass 2: extension-stripped match (immediate, newest first).
        let queryStem = (query as NSString).deletingPathExtension
        for identity in identities {
            let stem = (identity.effectiveName as NSString).deletingPathExtension
            if stem.caseInsensitiveCompare(queryStem) == .orderedSame {
                return .resolved(identity.id)
            }
        }

        // Pass 3: loose-key match, unique-only. Several loose hits are
        // ambiguity at this tier (the store resolver returns nil; lint
        // reports the candidates instead).
        let queryKey = WikiNameRules.looseMatchKey(query)
        guard !queryKey.isEmpty else { return .missing }
        let loose = identities.filter {
            WikiNameRules.looseMatchKey($0.effectiveName) == queryKey
        }
        if loose.count == 1 { return .resolved(loose[0].id) }
        if loose.count > 1 { return .ambiguous(Self.uniqueIDs(loose)) }
        return .missing
    }

    private static func uniqueIDs(_ identities: [LintSourceIdentity]) -> [SourceID] {
        var seen = Set<String>()
        var ids: [SourceID] = []
        for identity in identities where seen.insert(identity.id.rawValue.uppercased()).inserted {
            ids.append(identity.id)
        }
        return ids
    }
}

// MARK: - Citation evidence

/// The complete bounded citation evidence for one run: every authored
/// occurrence (with its range), the deduplicated source-version records in
/// first-authored order, the source-name index, and typed budget notices.
/// Immutable after capture — checks and repair read this same evidence.
public struct LintCitationEvidence: Sendable, Equatable {
    /// Authored occurrences in document order (capped with a notice).
    public let occurrences: [LintCitationOccurrence]
    /// One record per distinct (source id, version request) pair, in first
    /// authored occurrence order.
    public let sourceVersions: [LintCapturedSourceVersion]
    public let nameIndex: LintSourceNameIndex
    public let notices: [LintCaptureNotice]
    /// True when the citation capture leg ran at all (a store without the
    /// capture never claims availability).
    public let isAvailable: Bool

    public static let empty = LintCitationEvidence(
        occurrences: [], sourceVersions: [], nameIndex: .unavailable,
        notices: [], isAvailable: false)

    public init(
        occurrences: [LintCitationOccurrence],
        sourceVersions: [LintCapturedSourceVersion],
        nameIndex: LintSourceNameIndex,
        notices: [LintCaptureNotice],
        isAvailable: Bool
    ) {
        self.occurrences = occurrences
        self.sourceVersions = sourceVersions
        self.nameIndex = nameIndex
        self.notices = notices
        self.isAvailable = isAvailable
    }

    /// The record for an occurrence's target, when one was captured.
    /// Canonical ids match directly; named occurrences match through the
    /// name index's resolution (nil when the name is missing or ambiguous).
    public func record(for occurrence: LintCitationOccurrence) -> LintCapturedSourceVersion? {
        guard let id = occurrenceTargetID(occurrence) else { return nil }
        return sourceVersions.first {
            $0.sourceID.rawValue.uppercased() == id && $0.request == occurrence.request
        }
    }

    /// The uppercased source id an occurrence's target denotes, or nil when
    /// the occurrence names no resolvable single source.
    public func occurrenceTargetID(_ occurrence: LintCitationOccurrence) -> String? {
        if let canonical = occurrence.canonicalSourceID {
            return canonical.uppercased()
        }
        guard let name = occurrence.sourceName,
              case .resolved(let id) = nameIndex.resolve(name: name) else {
            return nil
        }
        return id.rawValue.uppercased()
    }
}

// MARK: - Occurrence parsing

public extension LintCitationOccurrence {
    /// Parse every citation occurrence in `body` through the shared
    /// span/syntax APIs. Embeds (`![[source:…]]`) are excluded — they are
    /// transclusions, not citations. Fenced and inline-code content is
    /// excluded by the shared protected-range logic.
    static func parseAll(in body: String) -> [LintCitationOccurrence] {
        let nodes = WikiLinkParser.syntaxNodes(in: body)
        var occurrences: [LintCitationOccurrence] = []
        var order = 0
        for node in nodes {
            guard case .link(let link) = node else { continue } // embeds excluded
            guard link.target.namespace == .source else { continue }
            order += 1

            let quote: String?
            let heading: String?
            if let fragment = link.target.fragment {
                if let decoded = quoteText(fromFragment: fragment) {
                    quote = decoded.isEmpty ? nil : decoded
                    heading = nil
                } else {
                    quote = nil
                    heading = fragment
                }
            } else {
                quote = nil
                heading = nil
            }

            let request: LintSourceVersionRequest
            switch link.target.sourceVersionPin {
            case .none:
                request = .active
            case .some(let ordinal) where ordinal >= 1:
                if let decoded = LintSourceVersionPin(ordinal: UInt(ordinal)) {
                    request = .pinned(decoded)
                } else {
                    request = .invalidPin(literal: String(ordinal))
                }
            case .some(let ordinal):
                // Authored as a pin but not a positive ordinal (`@v0`):
                // preserved so the check reports it — never silently loads
                // the active version.
                request = .invalidPin(literal: String(ordinal))
            }

            // An occurrence whose range cannot locate real text is dropped
            // with a logged reason (never a fabricated anchor).
            let range: LintSourceRange
            do {
                range = try LintSourceRange(
                    lowerBound: link.sourceRange.lowerBound,
                    upperBound: link.sourceRange.upperBound,
                    expectedText: link.authoredLiteral,
                    in: body)
            } catch {
                DebugLog.lint("LintCitationEvidence: dropping unlocatable citation occurrence: \(error)")
                continue
            }

            occurrences.append(LintCitationOccurrence(
                canonicalSourceID: link.target.canonicalID,
                sourceName: link.target.canonicalID == nil ? link.target.literal : nil,
                request: request,
                quote: quote,
                headingFragment: heading,
                alias: link.alias,
                range: range,
                authoredLiteral: link.authoredLiteral,
                order: order))
        }
        return occurrences
    }

    /// The quote text a fragment carries: boundary `"` characters are the
    /// anchor delimiter and are trimmed (matching the reader's
    /// `resolveScrollTarget` trimming); inner quotes survive. A fragment
    /// that is not a quote anchor (no leading `"`) returns nil — it is a
    /// heading fragment.
    static func quoteText(fromFragment fragment: String) -> String? {
        guard fragment.hasPrefix("\"") else { return nil }
        var s = fragment
        s = s.drop(while: { $0 == "\"" }).description
        while s.hasSuffix("\"") { s.removeLast() }
        return s
    }
}
