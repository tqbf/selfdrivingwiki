import Foundation
import Testing
import WikiFSCore
import WikiFSTypes
import WikiLintEval

/// AC.12/AC.14: the diff oracle rejects known-bad edits; scoring separates
/// report-only recall from forbidden repairs; canned runs cannot claim
/// live; the shipped gate digests match the canonical manifests. The
/// shipped-manifest gate itself is covered in `LintAcceptanceGateTests`.
struct WikiLintEvaluationHarnessTests {

    // MARK: - Fixtures

    private struct UnknownFixture: Error { let id: String }

    private func canonical() throws -> LintEvalFixtureManifest {
        try LintEvalCanonicalFixtures.loadGateManifest()
    }

    private func fixture(_ id: String) throws -> LintEvalFixture {
        let all = try canonical().tuning + canonical().heldOut
        guard let match = all.first(where: { $0.id == id }) else {
            throw UnknownFixture(id: id)
        }
        return match
    }

    private var bailFixture: LintEvalFixture {
        get throws { try fixture("bail-d25-wrap") }
    }

    /// The exact mechanical repairs the bail fixture declares.
    private var bailRepairs: [(hunk: PagePatchHunk, defectClass: LintDefectClass)] {
        get throws {
            let body = try bailFixture.body
            let opening = "```markdown\n"
            let closing = "```\n"
            let openStart = 0
            let closeStart = body.utf8.count - closing.utf8.count
            return [
                (PagePatchHunk(
                    startByte: openStart, endByte: openStart + opening.utf8.count,
                    oldText: opening, newText: "", reason: "unwrap whole-body fence"), .wholeBodyFenceWrap),
                (PagePatchHunk(
                    startByte: closeStart, endByte: closeStart + closing.utf8.count,
                    oldText: closing, newText: "", reason: "unwrap whole-body fence"), .wholeBodyFenceWrap),
            ]
        }
    }

    // MARK: - Diff oracle

    @Test func diffOracleAcceptsDeclaredExactRepairs() throws {
        let original = try bailFixture.body
        let repairs = try bailRepairs
        let new = LintDiffOracle.apply(hunks: repairs.map(\.hunk), to: original)
        let verdict = LintDiffOracle.verify(
            original: original, new: new, hunks: repairs, fixture: try bailFixture)
        #expect(verdict.accepted, "rejections: \(verdict.rejections)")
    }

    @Test func diffOracleRejectsUnattributedAndInflatedHunks() throws {
        let original = try bailFixture.body
        let repairs = try bailRepairs
        // Unattributed: the new bytes do not match the recorded hunks' effect.
        let verdict1 = LintDiffOracle.verify(
            original: original, new: original + "\nextra\n",
            hunks: repairs, fixture: try bailFixture)
        #expect(verdict1.rejections.contains(.hunksDoNotReproduce))
        // Inflated: one hunk spanning (nearly) the whole body — a full-body
        // replacement disguised as a local repair.
        let whole = PagePatchHunk(
            startByte: 0, endByte: original.utf8.count,
            oldText: original, newText: "# replaced\n", reason: "nope")
        let verdict2 = LintDiffOracle.verify(
            original: original, new: "# replaced\n",
            hunks: [(whole, .wholeBodyFenceWrap)], fixture: try bailFixture)
        #expect(verdict2.rejections.contains(.fullBodyReplacement))
        // Undeclared: a mechanically wrong replacement text.
        let wrongText = PagePatchHunk(
            startByte: 0, endByte: 12, oldText: "```markdown\n",
            newText: "   ", reason: "sloppy unwrap")
        let verdict3 = LintDiffOracle.verify(
            original: original, new: LintDiffOracle.apply(hunks: [wrongText], to: original),
            hunks: [(wrongText, .wholeBodyFenceWrap)], fixture: try bailFixture)
        #expect(verdict3.rejections.contains(.undeclaredRepair(hunkIndex: 0)))
    }

    /// AC.12 negative control: hunks touching protected bytes are rejected
    /// even when they reproduce the new bytes.
    @Test func diffOracleRejectsProtectedByteEdits() throws {
        var guarded = try bailFixture
        guarded = LintEvalFixture(
            id: guarded.id, body: guarded.body,
            seededDefects: guarded.seededDefects,
            allowedRepairs: guarded.allowedRepairs,
            protectedByteRanges: [LintEvalByteRange(lowerBound: 0, upperBound: 12)],
            permittedUnresolvedClasses: guarded.permittedUnresolvedClasses,
            kind: guarded.kind)
        let original = guarded.body
        let repairs = try bailRepairs
        let verdict = LintDiffOracle.verify(
            original: original, new: LintDiffOracle.apply(hunks: repairs.map(\.hunk), to: original),
            hunks: repairs, fixture: guarded)
        #expect(verdict.rejections.contains(.touchesProtectedBytes(hunkIndex: 0)))
    }

    // MARK: - Scoring

    private func observed(
        confirmed: Set<String> = [], unresolved: Set<String> = [],
        repaired: Set<String> = [], coverageFailed: Bool = false
    ) -> LintEvalScoring.ObservedRun {
        LintEvalScoring.ObservedRun(
            confirmedClasses: confirmed, unresolvedClasses: unresolved,
            validAsWrittenClasses: [], repairedClasses: repaired,
            coverageFailed: coverageFailed)
    }

    /// AC.12 `perClassScoringNegativeControls`: a repaired report-only seed
    /// is a failure; a missed seed is a failure; false confirmed defects
    /// damage precision; a repairable bail left unresolved is a failure.
    @Test func perClassScoringNegativeControls() throws {
        // Correct bail run: the seeded D25 repaired.
        let good = LintEvalScoring.score(
            fixture: try bailFixture, run: observed(repaired: ["D25"]))
        #expect(good.passed)
        // Forbidden repair vs miss vs false confirmed vs coverage failure.
        let forbidden = LintEvalScoring.score(
            fixture: try fixture("judgment-d05-report-only"),
            run: observed(confirmed: ["D05"], repaired: ["D05"]))
        #expect(forbidden.passed == false)
        #expect(forbidden.failureReasons.contains { $0.contains("must not be repaired") })
        let missed = LintEvalScoring.score(
            fixture: try bailFixture, run: observed())
        #expect(missed.passed == false && missed.misses.contains { $0.hasPrefix("D25#") })
        let unresolvedBail = LintEvalScoring.score(
            fixture: try bailFixture, run: observed(confirmed: ["D25"], unresolved: ["D25"]))
        #expect(unresolvedBail.passed == false)
        let falsePositive = LintEvalScoring.score(
            fixture: try bailFixture, run: observed(
                confirmed: ["D17"], repaired: ["D25"]))
        #expect(falsePositive.falseConfirmed.contains("D17"))
        let coverage = LintEvalScoring.score(
            fixture: try bailFixture, run: observed(repaired: ["D25"], coverageFailed: true))
        #expect(coverage.passed == false)
        // The report-only judgment fixture: accurate unresolved passes.
        let reportOnly = LintEvalScoring.score(
            fixture: try fixture("judgment-d05-report-only"),
            run: observed(confirmed: ["D05"], unresolved: ["D05"]))
        #expect(reportOnly.passed)
    }

    /// AC.12 `heldOutSplitIsFrozen`: the canonical manifest carries a real
    /// held-out split whose digests are stable, and its fixtures never
    /// appear in the tuning group.
    @Test func heldOutSplitIsFrozen() throws {
        let canonical = try canonical()
        let digest = try canonical.digest()
        #expect(digest.count == 64)
        #expect(canonical.manifestVersion == LintEvalFixtureManifest.version)
        let tuningIDs = Set(canonical.tuning.map(\.id))
        for held in canonical.heldOut {
            #expect(tuningIDs.contains(held.id) == false, "held-out fixture \(held.id) leaked into tuning")
        }
        // Determinism: a re-digest equals the first.
        #expect(try canonical.digest() == digest)
    }

    // MARK: - Acceptance gate (AC.14)

    /// AC.14: the evaluation admission cannot authorize operator wikis.
    @Test func cannedCannotClaimLiveAndAdmissionIsScoped() {
        // Admission: disposable wiki ids only.
        let disposable = WikiID(rawValue: "01HZDISPOSABLE00000000000000A")
        let operator_ = WikiID(rawValue: "01HZOPERATORW00000000000000A")
        #expect(LintAcceptanceGate.evaluationAdmission(
            admittedWikiIDs: [disposable], requestedWikiID: disposable))
        #expect(LintAcceptanceGate.evaluationAdmission(
            admittedWikiIDs: [disposable], requestedWikiID: operator_) == false)
        #expect(LintAcceptanceGate.evaluationAdmission(
            admittedWikiIDs: [], requestedWikiID: disposable) == false)
    }

    /// AC.14: the SHIPPED gate fixture digests match the canonical
    /// manifests — a fixture update changes the shipped key.
    @Test func shippedFixtureDigestsMatchCanonicalManifests() throws {
        let shipped = try LintGateFixtureManifestShipped.load()
        let canonical = try canonical()
        let canonicalDigest = try canonical.digest()
        #expect(shipped.digest(named: "canonical-gate") == canonicalDigest,
                "the shipped gate digest is stale — regenerate LintGateFixtureManifest.json with `WikiLintEvalRunner inspect`")
    }
}
