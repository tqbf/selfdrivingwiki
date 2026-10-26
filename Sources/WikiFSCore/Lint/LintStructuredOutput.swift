import Foundation

// MARK: - Check envelope (wire shape)

/// The wire shape a model check step or script check returns: ONE JSON
/// object. Coordinates are UTF-8 byte offsets (the external JSON boundary);
/// every range is re-validated against the snapshot body on decode.
public struct LintCheckEnvelope: Equatable, Sendable {
    public let run: String
    public let page: String
    public let findings: [WireFinding]

    public struct WireFinding: Equatable, Sendable {
        public let id: String
        public let severity: String
        public let message: String
        public let evidence: String?
        public let scope: String
        public let ranges: [WireRange]
        public let rule: String?
        public let recipes: [String]
    }

    public struct WireRange: Equatable, Sendable {
        public let start: Int
        public let end: Int
        public let expected: String
    }
}

/// The wire shape a repair producer returns: ONE JSON object.
public struct LintRepairEnvelope: Equatable, Sendable {
    public let run: String
    public let page: String
    public let finding: String
    public let option: String
    public let recipe: String
    public let replacements: [WireReplacement]

    public struct WireReplacement: Equatable, Sendable {
        public let start: Int
        public let end: Int
        public let expected: String
        public let text: String
    }
}

// MARK: - Decoding errors

/// Why a step's structured output was rejected. A rejection fails the step
/// visibly — it never converts into "zero findings" or "clean page".
public enum LintEnvelopeError: Error, Equatable, Sendable, LocalizedError {
    /// The response was not one complete JSON object (partial JSON, arbitrary
    /// prose, or an empty body). A single wrapping Markdown fence is accepted.
    case notOneJSONObject
    case oversizedOutput(bytes: Int, limit: Int)
    case wrongRunIdentity(expected: String, got: String)
    case wrongPageIdentity(expected: String, got: String)
    case unknownRecipe(referenced: String)
    case invalidFindingID
    case invalidSeverity(String)
    case invalidScope(String)
    case invalidLocation(finding: String, detail: String)
    case tooManyFindings(count: Int, limit: Int)
    case unknownField(name: String)
    case missingIdentityField(name: String)
    case decodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notOneJSONObject:
            return "Step output was not one complete JSON object."
        case .oversizedOutput(let bytes, let limit):
            return "Step output exceeded the size limit (\(bytes) > \(limit) bytes)."
        case .wrongRunIdentity(let expected, let got):
            return "Step output names a different run (got '\(got)', expected '\(expected)')."
        case .wrongPageIdentity(let expected, let got):
            return "Step output names a different page (got '\(got)', expected '\(expected)')."
        case .unknownRecipe(let referenced):
            return "Step output references repair recipe '\(referenced)', which is not configured."
        case .invalidFindingID:
            return "Step output has an empty or duplicate finding id."
        case .invalidSeverity(let s):
            return "Step output uses unknown severity '\(s)'."
        case .invalidScope(let s):
            return "Step output uses unknown scope '\(s)'."
        case .invalidLocation(let finding, let detail):
            return "Finding '\(finding)' has an invalid passage location: \(detail)."
        case .tooManyFindings(let count, let limit):
            return "Step reported \(count) findings, over the limit of \(limit)."
        case .unknownField(let name):
            return "Step output contains unknown field '\(name)'."
        case .missingIdentityField(let name):
            return "Step output is missing identity field '\(name)'."
        case .decodeFailed(let detail):
            return "Step output JSON failed to decode: \(detail)"
        }
    }
}

// MARK: - Decoder

/// Decodes and validates one step output against its run context. Strict:
/// unknown fields, wrong identities, invalid locations, and unauthorized
/// recipe references all fail the step.
public enum LintEnvelopeDecoder {

    /// Strip one wrapping Markdown fence when the entire response is fenced
    /// JSON. Prose around or between fences is NOT scraped — the response
    /// must still be exactly one JSON object after unwrapping.
    static func unwrappingFence(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        var body = trimmed
        // Drop the opening fence line (```json / ```).
        if let firstNewline = body.firstIndex(of: "\n") {
            let opening = body[body.startIndex..<firstNewline]
                .trimmingCharacters(in: .whitespaces)
            guard opening == "```" || opening.hasPrefix("```json") else { return trimmed }
            body = String(body[body.index(after: firstNewline)...])
        } else {
            return trimmed
        }
        guard body.hasSuffix("```") else { return trimmed }
        body = String(body.dropLast(3))
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decode a check response. Throws `LintEnvelopeError` on any rejection;
    /// never returns an empty result for malformed output.
    public static func decodeCheck(
        _ raw: String, outputLimit: Int,
        runID: LintRunID, snapshot: LintPageSnapshot,
        configuredRecipes: Set<String>
    ) throws -> LintCheckEnvelope {
        let byteCount = raw.utf8.count
        guard byteCount <= outputLimit else {
            throw LintEnvelopeError.oversizedOutput(bytes: byteCount, limit: outputLimit)
        }
        let jsonText = unwrappingFence(raw)
        let envelope: LintCheckEnvelope
        do {
            guard let data = jsonText.data(using: .utf8) else {
                throw LintEnvelopeError.notOneJSONObject
            }
            // JSONSerialization.parse is the "is this ONE JSON object" probe;
            // a parse failure IS the typed notOneJSONObject outcome.
            let parsed = try JSONSerialization.jsonObject(with: data)
            guard let dict = parsed as? [String: Any] else {
                throw LintEnvelopeError.notOneJSONObject
            }
            // Unknown-field rejection: decode via strict Codable on the raw JSON
            // and compare key sets.
            try rejectUnknownFields(
                object: dict, allowed: ["run", "page", "findings"],
                findingKey: "findings", findingAllowed: [
                    "id", "severity", "message", "evidence", "scope", "ranges", "rule", "recipes",
                ],
                rangeAllowed: ["start", "end", "expected"])
            envelope = try JSONDecoder().decode(LintCheckEnvelope.self, from: data)
        } catch let error as LintEnvelopeError {
            throw error
        } catch {
            throw LintEnvelopeError.decodeFailed(String(describing: error))
        }
        guard envelope.run == runID.rawValue else {
            throw LintEnvelopeError.wrongRunIdentity(expected: runID.rawValue, got: envelope.run)
        }
        guard envelope.page == snapshot.pageID.rawValue else {
            throw LintEnvelopeError.wrongPageIdentity(
                expected: snapshot.pageID.rawValue, got: envelope.page)
        }
        guard envelope.findings.count <= LintExecutionLimits.maxFindingsPerStep else {
            throw LintEnvelopeError.tooManyFindings(
                count: envelope.findings.count, limit: LintExecutionLimits.maxFindingsPerStep)
        }
        var seenIDs = Set<String>()
        for finding in envelope.findings {
            guard !finding.id.isEmpty, seenIDs.insert(finding.id).inserted else {
                throw LintEnvelopeError.invalidFindingID
            }
            guard LintSeverity(rawValue: finding.severity) != nil else {
                throw LintEnvelopeError.invalidSeverity(finding.severity)
            }
            switch finding.scope {
            case "page":
                // Page findings carry no ranges — a fabricated one is invalid.
                if !finding.ranges.isEmpty {
                    throw LintEnvelopeError.invalidLocation(
                        finding: finding.id, detail: "page finding carries ranges")
                }
            case "passage":
                if finding.ranges.isEmpty {
                    throw LintEnvelopeError.invalidLocation(
                        finding: finding.id, detail: "passage finding has no ranges")
                }
                for range in finding.ranges {
                    do {
                        try LintLocationAdapter.validateRange(
                            range.start..<range.end, expectedText: range.expected,
                            in: snapshot.body)
                    } catch {
                        throw LintEnvelopeError.invalidLocation(
                            finding: finding.id, detail: String(describing: error))
                    }
                }
            default:
                throw LintEnvelopeError.invalidScope(finding.scope)
            }
            for recipe in finding.recipes where !configuredRecipes.contains(recipe) {
                throw LintEnvelopeError.unknownRecipe(referenced: recipe)
            }
        }
        return envelope
    }

    /// Decode a repair response and bind it to the selected finding/option.
    public static func decodeRepair(
        _ raw: String, outputLimit: Int,
        runID: LintRunID, snapshot: LintPageSnapshot,
        selectedFinding: LintFinding, selectedOption: LintRepairOption
    ) throws -> LintRepairEnvelope {
        let byteCount = raw.utf8.count
        guard byteCount <= outputLimit else {
            throw LintEnvelopeError.oversizedOutput(bytes: byteCount, limit: outputLimit)
        }
        let jsonText = unwrappingFence(raw)
        let envelope: LintRepairEnvelope
        do {
            guard let data = jsonText.data(using: .utf8) else {
                throw LintEnvelopeError.notOneJSONObject
            }
            // Same one-object probe as the check envelope.
            let parsed = try JSONSerialization.jsonObject(with: data)
            guard let dict = parsed as? [String: Any] else {
                throw LintEnvelopeError.notOneJSONObject
            }
            try rejectUnknownFields(
                object: dict, allowed: ["run", "page", "finding", "option", "recipe", "replacements"],
                findingKey: "replacements", findingAllowed: ["start", "end", "expected", "text"],
                rangeAllowed: nil)
            envelope = try JSONDecoder().decode(LintRepairEnvelope.self, from: data)
        } catch let error as LintEnvelopeError {
            throw error
        } catch {
            throw LintEnvelopeError.decodeFailed(String(describing: error))
        }
        guard envelope.run == runID.rawValue else {
            throw LintEnvelopeError.wrongRunIdentity(expected: runID.rawValue, got: envelope.run)
        }
        guard envelope.page == snapshot.pageID.rawValue else {
            throw LintEnvelopeError.wrongPageIdentity(
                expected: snapshot.pageID.rawValue, got: envelope.page)
        }
        guard envelope.finding == selectedFinding.id.rawValue else {
            throw LintEnvelopeError.missingIdentityField("finding")
        }
        guard envelope.option == selectedOption.id.rawValue else {
            throw LintEnvelopeError.missingIdentityField("option")
        }
        guard envelope.recipe == selectedOption.recipeID.rawValue else {
            throw LintEnvelopeError.unknownRecipe(referenced: envelope.recipe)
        }
        for replacement in envelope.replacements {
            do {
                try LintLocationAdapter.validateRange(
                    replacement.start..<replacement.end,
                    expectedText: replacement.expected, in: snapshot.body)
            } catch {
                throw LintEnvelopeError.invalidLocation(
                    finding: selectedFinding.id.rawValue,
                    detail: String(describing: error))
            }
        }
        return envelope
    }

    /// Reject any key outside the allowed set, at the top level and inside
    /// the finding/range arrays. Decoding is deliberately strict: unknown
    /// fields indicate a contract mismatch, not harmless extra data.
    static func rejectUnknownFields(
        object: [String: Any], allowed: Set<String>,
        findingKey: String?, findingAllowed: Set<String>?, rangeAllowed: Set<String>?
    ) throws {
        for key in object.keys where !allowed.contains(key) {
            throw LintEnvelopeError.unknownField(name: key)
        }
        guard let findingKey, let findingAllowed else { return }
        guard let findings = object[findingKey] as? [[String: Any]] else { return }
        for finding in findings {
            for key in finding.keys where !findingAllowed.contains(key) {
                throw LintEnvelopeError.unknownField(name: "\(findingKey).\(key)")
            }
            if let rangeAllowed,
               let ranges = finding["ranges"] as? [[String: Any]] {
                for range in ranges {
                    for key in range.keys where !rangeAllowed.contains(key) {
                        throw LintEnvelopeError.unknownField(name: "ranges.\(key)")
                    }
                }
            }
        }
    }
}

// MARK: - Proposal builder

/// Turns a validated repair envelope into a bound `LintRepairProposal`.
public enum LintProposalBuilder {

    /// Build + validate a proposal from producer output. Validation covers:
    /// identity binding, nonoverlap, expected old text, boundary validity,
    /// passage-scope containment, candidate size, and the unchanged-candidate
    /// rejection.
    public static func build(
        replacements: [LintSourceReplacement],
        snapshot: LintPageSnapshot,
        finding: LintFinding,
        option: LintRepairOption,
        candidateLimitBytes: Int
    ) throws -> LintRepairProposal {
        // Disjoint ranges.
        let sorted = replacements.sorted { $0.range.lowerBound < $1.range.lowerBound }
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            if a.range.upperBound > b.range.lowerBound {
                throw LintProposalError.overlappingReplacements
            }
        }
        // Passage scope containment: a passage repair may change text only
        // inside the finding's approved ranges. A page-scoped finding has no
        // passage constraint (it remains one explicit option).
        if case .passage(let approved) = finding.scope {
            for replacement in replacements {
                let contained = approved.contains {
                    $0.lowerBound <= replacement.range.lowerBound
                        && replacement.range.upperBound <= $0.upperBound
                }
                guard contained else {
                    throw LintProposalError.passageScopeEscape
                }
            }
        }
        // Candidate size + unchanged rejection.
        let candidate = try applyOrThrow(replacements, to: snapshot.body)
        let candidateBytes = candidate.utf8.count
        guard candidateBytes <= candidateLimitBytes else {
            throw LintProposalError.candidateTooLarge(
                bytes: candidateBytes, limit: candidateLimitBytes)
        }
        guard candidate != snapshot.body else {
            throw LintProposalError.unchangedCandidate
        }
        return LintRepairProposal(
            snapshotDigest: snapshot.bodyDigest,
            pageID: snapshot.pageID,
            findingID: finding.id,
            optionID: option.id,
            recipeID: option.recipeID,
            replacements: replacements)
    }

    /// Apply replacements or surface the precise failure (never partial).
    public static func applyOrThrow(
        _ replacements: [LintSourceReplacement], to body: String
    ) throws -> String {
        var sorted = replacements
        sorted.sort { $0.range.lowerBound > $1.range.lowerBound }
        var bytes = Array(body.utf8)
        for replacement in sorted {
            let bounds = replacement.range.bounds
            guard bounds.upperBound <= bytes.count else {
                throw LintProposalError.invalidReplacement(offset: bounds.upperBound)
            }
            let actual = String(
                decoding: bytes[bounds.lowerBound..<bounds.upperBound], as: UTF8.self)
            guard actual == replacement.range.expectedText else {
                throw LintProposalError.invalidReplacement(offset: bounds.lowerBound)
            }
            bytes.replaceSubrange(bounds, with: Array(replacement.newText.utf8))
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
