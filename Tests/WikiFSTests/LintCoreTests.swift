import Foundation
import Testing
import WikiFSMarkdown
@testable import WikiFSCore

/// The lint location adapter: UTF-8/UTF-16 conversion, boundary validation,
/// expected-byte checks, and the markdownlint line/column mapping — including
/// emoji, combining marks, CRLF, and the one past-end line.
struct LintLocationAdapterTests {

    @Test func utf16OffsetRoundTripsThroughEmoji() throws {
        let text = "a👍b"  // 👍 is 4 UTF-8 bytes, 2 UTF-16 units
        // Offset 1 → after 'a'.
        let u16 = try LintLocationAdapter.utf16Offset(ofUTF8Offset: 1, in: text)
        #expect(u16 == 1)
        // Offset 5 (past the emoji) → 1 + 2 = 3 UTF-16 units.
        let u16After = try LintLocationAdapter.utf16Offset(ofUTF8Offset: 5, in: text)
        #expect(u16After == 3)
        // Reverse direction.
        #expect(try LintLocationAdapter.utf8Offset(ofUTF16Offset: 3, in: text) == 5)
    }

    @Test func combiningMarksRejectMidGraphemeOffsets() throws {
        // "e" (1 byte) + combining acute (2 bytes): byte offset 2 is the
        // accent's second byte — NOT a scalar boundary.
        let text = "e\u{0301}x"
        #expect(throws: LintLocationError.notOnUnicodeBoundary(offset: 2)) {
            _ = try LintLocationAdapter.utf16Offset(ofUTF8Offset: 2, in: text)
        }
        // Boundaries 0, 1 (after "e"), 3 (after the accent) convert cleanly.
        #expect(try LintLocationAdapter.utf16Offset(ofUTF8Offset: 3, in: text) == 2)
    }

    @Test func surrogateSplitRejected() throws {
        let text = "a👍b"
        // UTF-16 offset 2 splits the surrogate pair.
        #expect(throws: LintLocationError.notOnUnicodeBoundary(offset: 2)) {
            _ = try LintLocationAdapter.utf8Offset(ofUTF16Offset: 2, in: text)
        }
    }

    @Test func outOfBoundsRejected() {
        #expect(throws: LintLocationError.outOfBounds(offset: 99, utf8Count: 3)) {
            try LintLocationAdapter.validateBoundary(99, in: "abc")
        }
    }

    @Test func expectedTextValidation() throws {
        let body = "hello world"
        try LintLocationAdapter.validateRange(0..<5, expectedText: "hello", in: body)
        #expect(throws: LintLocationError.expectedTextMismatch(offset: 0, actual: "hello", expected: "jello")) {
            try LintLocationAdapter.validateRange(0..<5, expectedText: "jello", in: body)
        }
    }

    @Test func nsRangeConversionMatchesNSString() throws {
        let text = "héllo👍wörld"  // é = 2 bytes, 👍 = 4 bytes
        let ns = text as NSString
        // Boundaries: h=0, é=1..2, l=3, l=4, o=5, 👍=6..9. "llo" is 3..<6.
        let range = 3..<6
        let nsRange = try LintLocationAdapter.nsRange(forUTF8Range: range, in: text)
        let lower16 = try LintLocationAdapter.utf16Offset(ofUTF8Offset: 3, in: text)
        let upper16 = try LintLocationAdapter.utf16Offset(ofUTF8Offset: 6, in: text)
        let expected = ns.substring(with: NSRange(
            location: lower16, length: upper16 - lower16))
        #expect(ns.substring(with: nsRange) == expected)
        #expect(expected == "llo")
    }

    @Test func lineTableMapsMarkdownlintCoordinates() throws {
        let body = "line one\nlíne two\n"  // líne has a 2-byte é
        let table = ByteLineTable(source: body)
        // Line 2 column 1 → offset of "líne".
        let offset = table.offset(line: 2, column: 1)
        #expect(offset == "line one\n".utf8.count)
        // Columns count BYTES: column 3 is the é's SECOND byte (mid-scalar —
        // the adapter's boundary check rejects such positions later); column
        // 4 is past the é.
        let mid = table.offset(line: 2, column: 3)
        #expect(mid == "line one\nl\u{00E9}".utf8.count - 1)
        let past = table.offset(line: 2, column: 4)
        #expect(past == "line one\nl\u{00E9}".utf8.count)
        // Out of range line → nil.
        #expect(table.offset(line: 4, column: 1) == nil)
    }

    @Test func pastEndLineMapsToEOF() throws {
        // No trailing newline: line 2 is the phantom past-end line → EOF.
        let table = ByteLineTable(source: "abc")
        #expect(table.offset(line: 2, column: 1) == 3)
        #expect(table.offset(line: 3, column: 1) == nil)
        // With a trailing newline the empty final line IS line 2; there is
        // no additional phantom line.
        let table2 = ByteLineTable(source: "abc\n")
        #expect(table2.offset(line: 2, column: 1) == 4)
        #expect(table2.offset(line: 3, column: 1) == nil)
    }

    @Test func zeroWidthRangesAreLegal() throws {
        let body = "abc"
        try LintLocationAdapter.validateRange(2..<2, expectedText: "", in: body)
    }
}

/// The pipeline configuration: schema round-trip, validation problems, and
/// the load semantics (missing → defaults, invalid → problems, never
/// overwritten).
struct LintPipelineConfigTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lint-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func bundledDefaultsValidateCleanly() {
        let problems = LintPipelineStore.validate(.bundledDefaults(), configurationDirectory: nil)
        #expect(problems.isEmpty)
    }

    @Test func roundTripPreservesStepsAndRecipes() throws {
        let document = LintPipelineDocument.bundledDefaults()
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(LintPipelineDocument.self, from: data)
        #expect(decoded == document)
    }

    @Test func duplicateStepIDsAreRejected() {
        var document = LintPipelineDocument.bundledDefaults()
        document.checkSteps.append(document.checkSteps[0])
        let problems = LintPipelineStore.validate(document, configurationDirectory: nil)
        #expect(problems.contains { problem in
            if case .duplicateStepID(let id) = problem { return id == document.checkSteps[0].id }
            return false
        })
    }

    @Test func decisionKindsProduceExplicitError() {
        var document = LintPipelineDocument.bundledDefaults()
        document.checkSteps[0].execution.kind = .decision
        let problems = LintPipelineStore.validate(document, configurationDirectory: nil)
        #expect(problems.contains { problem in
            if case .decisionModelsNotSupported = problem { return true }
            return false
        })
    }

    @Test func unsupportedVersionIsRejected() {
        var document = LintPipelineDocument.bundledDefaults()
        document.version = 99
        let problems = LintPipelineStore.validate(document, configurationDirectory: nil)
        #expect(problems == [.unsupportedVersion(99)])
    }

    @Test func missingPromptFileIsRejected() throws {
        var document = LintPipelineDocument.bundledDefaults()
        let modelStep = document.checkSteps.first { $0.id == "model-page-review" }!
        document.checkSteps[document.checkSteps.firstIndex { $0.id == "model-page-review" }!].execution.prompt = "does-not-exist.md"
        _ = modelStep
        let problems = LintPipelineStore.validate(
            document, configurationDirectory: try tempDir())
        #expect(problems.contains { problem in
            if case .missingPrompt = problem { return true }
            return false
        })
    }

    @Test func missingExecutableIsRejected() throws {
        var document = LintPipelineDocument.bundledDefaults()
        document.checkSteps[0].execution = LintStepExecution(
            kind: .script, executable: "missing.sh")
        let problems = LintPipelineStore.validate(
            document, configurationDirectory: try tempDir())
        #expect(problems.contains { problem in
            if case .missingExecutable = problem { return true }
            return false
        })
    }

    @Test func invalidLimitsAreRejected() {
        var document = LintPipelineDocument.bundledDefaults()
        let modelIndex = document.checkSteps.firstIndex { $0.id == "model-page-review" }!
        document.checkSteps[modelIndex].execution.timeoutSeconds = 0
        document.checkSteps[modelIndex].execution.maxOutputBytes = 1_000_000_000
        let problems = LintPipelineStore.validate(document, configurationDirectory: nil)
        #expect(problems.contains { problem in
            if case .invalidLimit(let name, _, _) = problem { return name == "timeoutSeconds" }
            return false
        })
        #expect(problems.contains { problem in
            if case .invalidLimit(let name, _, _) = problem { return name == "maxOutputBytes" }
            return false
        })
    }

    @Test func loadMissingFileYieldsBundledDefaults() throws {
        let result = LintPipelineStore.load(from: try tempDir())
        guard case .missingDefaults(let defaults) = result else {
            Issue.record("Expected missingDefaults, got \(result)")
            return
        }
        #expect(defaults == .bundledDefaults())
    }

    @Test func loadInvalidFileNeverOverwrites() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent(LintPipelineDocument.fileName)
        try Data("{\"version\": 42}".utf8).write(to: url)
        let result = LintPipelineStore.load(from: dir)
        guard case .invalid(let document, let problems) = result else {
            Issue.record("Expected invalid, got \(result)")
            return
        }
        #expect(problems.contains { $0 == .unsupportedVersion(42) })
        #expect(document?.version == 42)
        // The file is untouched.
        #expect((try Data(contentsOf: url)) == Data("{\"version\": 42}".utf8))
    }
}

/// The structured-output envelope decoder: strict rejection paths, fenced
/// JSON acceptance, identity binding, and size/count limits.
struct LintEnvelopeDecoderTests {

    private func snapshot(body: String = LintEnvelopeDecoderTests.defaultBody) -> LintPageSnapshot {
        LintPageSnapshot(
            wikiID: WikiID(rawValue: "wiki"),
            pageID: PageID(rawValue: "page-1"),
            title: "Title",
            body: body,
            headVersionID: PageVersionID(rawValue: "v1"),
            strategyRevision: nil,
            strategyContext: "# Wiki Strategy\n\nDefault",
            relatedResources: .empty)
    }

    /// The default body: "Body " occupies bytes 9..<14.
    static let defaultBody = "# Title\n\nBody text.\n"
    static let bodyRangeStart = 9
    static let bodyRangeExpected = "Body "

    private func validFindingJSON(
        run: String = "", page: String = "page-1",
        extra: String = ""
    ) -> String {
        let start = Self.bodyRangeStart
        return """
        {"run": "\(run.isEmpty ? LintRunID().rawValue : run)", "page": "\(page)"\(extra), "findings": [
          {"id": "f1", "severity": "warning", "message": "m", "evidence": null,
           "scope": "passage",
           "ranges": [{"start": \(start), "end": \(start + 5), "expected": "\(Self.bodyRangeExpected)"}],
           "rule": null, "recipes": []}
        ]}
        """
    }

    @Test func validEnvelopeDecodes() throws {
        let runID = LintRunID()
        let json = validFindingJSON(run: runID.rawValue)
        let findings = try LintEnvelopeDecoder.decodeCheck(
            json, outputLimit: 100_000, runID: runID, snapshot: snapshot(),
            configuredRecipes: [])
        #expect(findings.findings.count == 1)
        #expect(findings.findings[0].scope == "passage")
    }

    @Test func fencedJSONIsAccepted() throws {
        let runID = LintRunID()
        let json = "```json\n\(validFindingJSON(run: runID.rawValue))\n```"
        let findings = try LintEnvelopeDecoder.decodeCheck(
            json, outputLimit: 100_000, runID: runID, snapshot: snapshot(),
            configuredRecipes: [])
        #expect(findings.findings.count == 1)
    }

    @Test func proseIsRejectedNotZeroFindings() {
        #expect(throws: LintEnvelopeError.notOneJSONObject) {
            _ = try LintEnvelopeDecoder.decodeCheck(
                "I found 2 issues but here is my reasoning…",
                outputLimit: 100_000, runID: LintRunID(), snapshot: snapshot(),
                configuredRecipes: [])
        }
    }

    @Test func partialJSONIsRejected() {
        #expect(throws: LintEnvelopeError.notOneJSONObject) {
            _ = try LintEnvelopeDecoder.decodeCheck(
                "{\"run\": \"x\", \"page\": \"page-1\", \"findings\": [",
                outputLimit: 100_000, runID: LintRunID(), snapshot: snapshot(),
                configuredRecipes: [])
        }
    }

    @Test func wrongRunIdentityIsRejected() throws {
        let runID = LintRunID()
        do {
            _ = try LintEnvelopeDecoder.decodeCheck(
                validFindingJSON(run: "other"),
                outputLimit: 100_000, runID: runID, snapshot: snapshot(),
                configuredRecipes: [])
            Issue.record("Expected wrongRunIdentity, decoded instead")
        } catch let error as LintEnvelopeError {
            guard case .wrongRunIdentity(let expected, let got) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(expected == runID.rawValue)
            #expect(got == "other")
        }
    }

    @Test func wrongPageIdentityIsRejected() throws {
        let runID = LintRunID()
        do {
            _ = try LintEnvelopeDecoder.decodeCheck(
                validFindingJSON(run: runID.rawValue, page: "other"),
                outputLimit: 100_000, runID: runID, snapshot: snapshot(),
                configuredRecipes: [])
            Issue.record("Expected wrongPageIdentity, decoded instead")
        } catch let error as LintEnvelopeError {
            guard case .wrongPageIdentity(let expected, let got) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(expected == "page-1")
            #expect(got == "other")
        }
    }

    @Test func oversizedOutputIsRejected() throws {
        let runID = LintRunID()
        let json = validFindingJSON(run: runID.rawValue)
        do {
            _ = try LintEnvelopeDecoder.decodeCheck(
                json, outputLimit: 10, runID: runID, snapshot: snapshot(),
                configuredRecipes: [])
            Issue.record("Expected oversizedOutput, decoded instead")
        } catch let error as LintEnvelopeError {
            guard case .oversizedOutput(let bytes, let limit) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(bytes == json.utf8.count)
            #expect(limit == 10)
        }
    }

    @Test func invalidLocationFailsTheStep() {
        let runID = LintRunID()
        let json = """
        {"run": "\(runID.rawValue)", "page": "page-1", "findings": [
          {"id": "f1", "severity": "info", "message": "m", "evidence": null,
           "scope": "passage",
           "ranges": [{"start": 0, "end": 9999, "expected": "nope"}],
           "rule": null, "recipes": []}
        ]}
        """
        do {
            _ = try LintEnvelopeDecoder.decodeCheck(
                json, outputLimit: 100_000, runID: runID, snapshot: snapshot(),
                configuredRecipes: [])
            Issue.record("Expected invalidLocation, decoded instead")
        } catch let error as LintEnvelopeError {
            guard case .invalidLocation(let finding, _) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(finding == "f1")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func unknownRecipeIsRejected() {
        let runID = LintRunID()
        let start = Self.bodyRangeStart
        let json = """
        {"run": "\(runID.rawValue)", "page": "page-1", "findings": [
          {"id": "f1", "severity": "info", "message": "m", "evidence": null,
           "scope": "passage",
           "ranges": [{"start": \(start), "end": \(start + 5), "expected": "\(Self.bodyRangeExpected)"}],
           "rule": null, "recipes": ["not-configured"]}
        ]}
        """
        do {
            _ = try LintEnvelopeDecoder.decodeCheck(
                json, outputLimit: 100_000, runID: runID, snapshot: snapshot(),
                configuredRecipes: ["cosmetic-fix"])
            Issue.record("Expected unknownRecipe, decoded instead")
        } catch let error as LintEnvelopeError {
            guard case .unknownRecipe(let referenced) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(referenced == "not-configured")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func unknownFieldsAreRejected() {
        let runID = LintRunID()
        let json = """
        {"run": "\(runID.rawValue)", "page": "page-1", "findings": [], "surprise": 1}
        """
        #expect(throws: LintEnvelopeError.unknownField(name: "surprise")) {
            _ = try LintEnvelopeDecoder.decodeCheck(
                json, outputLimit: 100_000, runID: runID, snapshot: snapshot(),
                configuredRecipes: [])
        }
    }

    @Test func pageFindingWithRangesIsRejected() {
        let runID = LintRunID()
        let json = """
        {"run": "\(runID.rawValue)", "page": "page-1", "findings": [
          {"id": "f1", "severity": "info", "message": "m", "evidence": null,
           "scope": "page",
           "ranges": [{"start": 0, "end": 1, "expected": "#"}],
           "rule": null, "recipes": []}
        ]}
        """
        do {
            _ = try LintEnvelopeDecoder.decodeCheck(
                json, outputLimit: 100_000, runID: runID, snapshot: snapshot(),
                configuredRecipes: [])
            Issue.record("Expected invalidLocation, decoded instead")
        } catch let error as LintEnvelopeError {
            guard case .invalidLocation(let finding, let detail) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(finding == "f1")
            #expect(detail.contains("ranges"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}

/// The proposal builder: disjointness, scope containment, unchanged
/// rejection, descending-splice application with multi-byte content.
struct LintProposalBuilderTests {

    private let body = "αlpha βeta\n\ngamma 👍 delta\n"

    private func snapshot() -> LintPageSnapshot {
        LintPageSnapshot(
            wikiID: WikiID(rawValue: "wiki"),
            pageID: PageID(rawValue: "p"),
            title: "T",
            body: body,
            headVersionID: PageVersionID(rawValue: "v"),
            strategyRevision: nil,
            strategyContext: "",
            relatedResources: .empty)
    }

    private func replacement(_ text: String, newText: String) throws -> LintSourceReplacement {
        let start = try LintLocationAdapter.utf8Offset(
            ofUTF16Offset: (body as NSString).range(of: text).location, in: body)
        let end = start + text.utf8.count
        return LintSourceReplacement(
            range: try LintSourceRange(
                lowerBound: start, upperBound: end, expectedText: text, in: body),
            newText: newText)
    }

    @Test func overlappingReplacementsRejected() throws {
        let a = try replacement("αlpha", newText: "x")
        let b = try replacement("lph", newText: "y")
        #expect(throws: LintProposalError.overlappingReplacements) {
            _ = try LintProposalBuilder.build(
                replacements: [a, b], snapshot: snapshot(),
                finding: LintFinding(
                    id: LintFindingID(rawValue: "f"), stepID: LintStepID(rawValue: "s"),
                    ruleID: nil, severity: .info, message: "", evidence: nil,
                    scope: .page, repairOptions: []),
                option: LintRepairOption(
                    id: LintOptionID(rawValue: "o"), recipeID: LintRecipeID(rawValue: "r"),
                    label: "l"),
                candidateLimitBytes: 100_000)
        }
    }

    @Test func passageScopeEscapeRejected() throws {
        let escape = try replacement("gamma", newText: "x")
        let finding = LintFinding(
            id: LintFindingID(rawValue: "f"), stepID: LintStepID(rawValue: "s"),
            ruleID: nil, severity: .info, message: "", evidence: nil,
            scope: .passage([
                // A passage range over "βeta" only.
                try LintSourceRange(
                    lowerBound: 7, upperBound: 12, expectedText: "βeta", in: body),
            ]),
            repairOptions: [])
        #expect(throws: LintProposalError.passageScopeEscape) {
            _ = try LintProposalBuilder.build(
                replacements: [escape], snapshot: snapshot(),
                finding: finding,
                option: LintRepairOption(
                    id: LintOptionID(rawValue: "o"), recipeID: LintRecipeID(rawValue: "r"),
                    label: "l"),
                candidateLimitBytes: 100_000)
        }
    }

    @Test func unchangedCandidateRejected() throws {
        let noop = try replacement("αlpha", newText: "αlpha")
        #expect(throws: LintProposalError.unchangedCandidate) {
            _ = try LintProposalBuilder.build(
                replacements: [noop], snapshot: snapshot(),
                finding: LintFinding(
                    id: LintFindingID(rawValue: "f"), stepID: LintStepID(rawValue: "s"),
                    ruleID: nil, severity: .info, message: "", evidence: nil,
                    scope: .page, repairOptions: []),
                option: LintRepairOption(
                    id: LintOptionID(rawValue: "o"), recipeID: LintRecipeID(rawValue: "r"),
                    label: "l"),
                candidateLimitBytes: 100_000)
        }
    }

    @Test func descendingSpliceHandlesEmojiAndMultipleEdits() throws {
        let first = try replacement("βeta", newText: "βETA")
        let second = try replacement("delta", newText: "DELTA")
        let proposal = try LintProposalBuilder.build(
            replacements: [first, second], snapshot: snapshot(),
            finding: LintFinding(
                id: LintFindingID(rawValue: "f"), stepID: LintStepID(rawValue: "s"),
                ruleID: nil, severity: .info, message: "", evidence: nil,
                scope: .page, repairOptions: []),
            option: LintRepairOption(
                id: LintOptionID(rawValue: "o"), recipeID: LintRecipeID(rawValue: "r"),
                label: "l"),
            candidateLimitBytes: 100_000)
        let applied = try #require(proposal.applying(to: body))
        #expect(applied == "αlpha βETA\n\ngamma 👍 DELTA\n")
    }

    @Test func staleExpectedTextRefusedNotPartial() throws {
        let stale = LintSourceReplacement(
            range: try LintSourceRange(
                lowerBound: 0, upperBound: 6, expectedText: "αlpha", in: body),
            newText: "x")
        let tamperedBody = "OTHER βeta\n"
        #expect(throws: LintProposalError.invalidReplacement(offset: 0)) {
            _ = try LintProposalBuilder.applyOrThrow([stale], to: tamperedBody)
        }
    }
}
