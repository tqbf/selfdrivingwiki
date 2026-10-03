import Testing
import Foundation
@testable import WikiFSCore

/// The cumulative-ingest authoring contract (wiki strategies phase 4).
///
/// Every prompt surface that writes wiki pages must teach the same
/// cumulative-update discipline: read an existing target's body AND head in
/// one JSON read before composing, preserve supported claims with their
/// citations, qualify superseded interpretations, guard new-page creation
/// with `--create-only` (mutually exclusive with `--expect-head`), and on a
/// CAS conflict recompute the composition from the fresh body and retry
/// once — reporting, not looping, on a second conflict.
///
/// The contract is asserted on three layers so they cannot drift apart: the
/// compiled base (`SystemPrompt.defaultBody`), the generated prompt
/// constants the runtime actually loads (`GeneratedPrompts`), and the
/// canonical `prompts/*.md` sources. Plan-schema behavior (supporting
/// sources, backward-compatible decoding, pre-launch validation) is pinned
/// here too — see `ACPIngestPlanValidation` in WikiFSCore.
struct CumulativeIngestContractTests {

    /// `#file` is `<repo>/Tests/WikiFSTests/CumulativeIngestContractTests.swift`
    /// — THREE deletions reach the repo root (filename → WikiFSTests → Tests).
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // <name>.swift
            .deletingLastPathComponent()   // WikiFSTests/
            .deletingLastPathComponent()   // Tests/ → repo root
    }

    private func canonical(_ name: String) throws -> String {
        try readPrompt(
            at: repoRoot().appendingPathComponent("prompts").appendingPathComponent(name),
            label: "prompts/\(name)")
    }

    private func bundled(_ name: String) throws -> String {
        try readPrompt(
            at: repoRoot()
                .appendingPathComponent("Sources/WikiFSCore/Resources/Prompts")
                .appendingPathComponent(name),
            label: "Sources/WikiFSCore/Resources/Prompts/\(name) — run make prompts")
    }

    /// Explicit read errors (house rule: no silent `try?`): record the
    /// failure WITH the underlying error, then rethrow so the test fails
    /// loudly instead of asserting against an empty string.
    private func readPrompt(at url: URL, label: String) throws -> String {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            Issue.record("cannot read prompt \(label): \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - AC.5: all authoring prompts require reconciliation

    /// The prompt surfaces that author pages, each paired with its canonical
    /// file name (surfaces without a file pass nil). The planner and
    /// finalizer are NOT authoring surfaces — the planner writes no pages,
    /// the finalizer owns index/log only (asserted separately below).
    private var authoringSurfaces: [(name: String, prompt: String, file: String?)] {
        [
            ("system-prompt-default (compiled base)", SystemPrompt.defaultBody, "system-prompt-default.md"),
            ("ingest-write-rule (generated)", GeneratedPrompts.ingestWriteRule, "ingest-write-rule.md"),
            ("ingest-single-task (generated)", GeneratedPrompts.ingestSingleTask, "ingest-single-task.md"),
            ("ingest-curator-task (generated)", GeneratedPrompts.ingestCuratorTask, "ingest-curator-task.md"),
            ("ingest-executor (generated)", GeneratedPrompts.ingestExecutor, "ingest-executor.md"),
        ]
    }

    @Test func allAuthoringPromptsRequireReconciliation() {
        for (name, prompt, _) in authoringSurfaces {
            // Body+head read before composing, and both write expectations.
            #expect(prompt.contains("--expect-head"), "\(name): existing-page writes must carry --expect-head")
            #expect(prompt.contains("--create-only"), "\(name): new-page writes must carry the --create-only race guard")
            #expect(prompt.contains("mutually exclusive"), "\(name): --expect-head and --create-only must be declared mutually exclusive")
            #expect(prompt.contains("head_version_id"), "\(name): the CAS token must be named")
            // Reconciliation discipline, not blind append/overwrite.
            #expect(prompt.lowercased().contains("preserve"), "\(name): supported existing content must be preserved")
            #expect(prompt.lowercased().contains("supersed"), "\(name): superseded interpretations must be qualified, not contradicted")
            // Retry-once from a FRESH body — never the stale composition with a new head.
            #expect(prompt.lowercased().contains("retry once"), "\(name): the CAS retry must be bounded to one attempt")
            #expect(prompt.lowercased().contains("recompute") || prompt.lowercased().contains("never resend"),
                    "\(name): a CAS retry must recompute against the re-read body, not reuse the stale composition")
        }
    }

    /// The same contract holds on the canonical `prompts/*.md` sources and
    /// their bundled resource copies — the three layers cannot drift.
    @Test func reconciliationContractHoldsOnCanonicalAndBundledPromptFiles() throws {
        let files = authoringSurfaces.compactMap { $0.file }
        #expect(files.count == authoringSurfaces.count)
        for file in files {
            let source = try canonical(file)
            let copy = try bundled(file)
            #expect(source.contains("--create-only"), "prompts/\(file): missing the --create-only race guard")
            #expect(source.contains("--expect-head"), "prompts/\(file): missing --expect-head")
            #expect(copy == source, "\(file) drifted from its bundled copy — run make prompts")
        }
    }

    /// The ACTUAL authoring surfaces the app assembles — not just template
    /// files — carry the full reconciliation semantics. `WikiOperation.prompt`
    /// composes the write-rule block into both ingest task prompts; the
    /// exact sentences (single body+head JSON read, recompose-never-resend)
    /// must survive assembly, not merely appear as loose keywords.
    @Test func assembledIngestPromptsCarryFullReconciliationContract() {
        let staged = "/scratch/Chapter-01--01SOURCE00000000000.md"
        let ops: [WikiOperation] = [
            .ingest(
                sourcePaths: ["sources/by-id/01SOURCE00000000000.md"],
                stagedSourcePaths: [staged],
                stateFilePath: "/scratch/WIKI_STATE.md",
                plan: .singleOpus),
            .ingest(
                sourcePaths: ["sources/by-id/01SOURCE00000000000.md"],
                stagedSourcePaths: [staged],
                stateFilePath: "/scratch/WIKI_STATE.md",
                plan: .opusCurator),
        ]
        for op in ops {
            let prompt = op.prompt(wikiRoot: "/wiki")
            // ONE JSON read supplying body AND head before composing.
            #expect(prompt.contains("body AND `head_version_id` in ONE `wikictl page get --json` read"),
                    "\(op.kind.rawValue) ingest: assembled prompt must require the single body+head read")
            // Recompose semantics, verbatim.
            #expect(prompt.contains("RECOMPUTE your composition against the new body"),
                    "\(op.kind.rawValue) ingest: CAS retry must recompute from the fresh body")
            #expect(prompt.contains("never resend the old composed body with only a refreshed head"),
                    "\(op.kind.rawValue) ingest: the stale-body resend ban must survive assembly")
            // Both write expectations, mutually exclusive.
            #expect(prompt.contains("--expect-head"))
            #expect(prompt.contains("--create-only"))
            #expect(prompt.contains("mutually exclusive"))
            // Evidence reconciliation semantics.
            #expect(prompt.contains("Preserve claims that remain supported"))
            #expect(prompt.contains("qualify superseded interpretations"))
            #expect(prompt.contains("each source that supports a retained or new claim"))
            #expect(prompt.contains("Keeping a citation in the body does not record that source as a version input"))
            #expect(prompt.contains("--source '<source-id>:supporting'"))
        }
    }

    // MARK: - Executor scope: assigned targets only, existing pages included

    @Test func executorOwnsAssignedExistingPages() {
        let executor = GeneratedPrompts.ingestExecutor
        // The retired blanket ban ("Do NOT update … any existing page") is
        // gone — an executor's ASSIGNED existing page is its responsibility.
        #expect(!executor.contains("or any existing page"),
                "the blanket existing-page ban contradicts cumulative reconciliation")
        #expect(executor.contains("UPDATING an existing page"),
                "updating an assigned existing page must be explicitly in scope")
        #expect(executor.contains("you own updating that page"),
                "the executor must own its assigned existing targets")
        // Unrelated pages stay out of scope; the finalizer owns index/log
        // ONLY — Home is an ordinary assigned page and must NOT be named as
        // a restriction anywhere in the executor prompt.
        #expect(executor.contains("Write ONLY the pages assigned above"))
        #expect(executor.contains("the index and the log, and nothing else"))
        #expect(!executor.contains("Home"),
                "Home is an ordinary assigned page — never an executor restriction (the finalizer owns index/log only)")
        #expect(!executor.contains("index set"), "the executor must not write the index (finalizer owns it)")
        #expect(!executor.contains("log append"), "the executor must not write the log (finalizer owns it)")
        // The primary source is responsibility, not the only admissible evidence.
        #expect(executor.contains("NOT the only admissible"))
        #expect(executor.contains("reconciliation"), "reading beyond the primary source is scoped to reconciliation")
        // A supporting range is a STARTING range: the read may extend when
        // evidence assessment needs it.
        #expect(executor.contains("read further into a supporting source"),
                "supporting-source reads must be allowed to extend past the stated range")
    }

    @Test func finalizerStaysIndexAndLogOnly() {
        let finalizer = GeneratedPrompts.ingestFinalizer
        #expect(finalizer.contains("index set"))
        #expect(finalizer.contains("log append"))
        #expect(!finalizer.contains("page add"), "the finalizer must not write pages — no separate synthesis phase")
        #expect(!finalizer.contains("--expect-head"))
        #expect(!finalizer.contains("--create-only"))
        #expect(!finalizer.contains("Home"), "the finalizer owns the index and the log ONLY — never Home")
    }

    @Test func plannerDocumentsSupportingSourcesAndSingleWriter() {
        let planner = GeneratedPrompts.ingestPlanner
        #expect(planner.contains("supportingSources"), "the plan schema must document optional supporting sources")
        #expect(planner.contains("ONE topic has ONE assigned writer"))
        #expect(planner.contains("PRIMARY source"), "sourceFile must be documented as the responsibility marker")
        #expect(planner.contains("rejected before any executor launches"))
        // The planner writes no pages: no write flags to teach.
        #expect(!planner.contains("--expect-head"))
        #expect(!planner.contains("--create-only"))
    }

    /// Lint's "don't rewrite existing page content" restriction stays
    /// explicitly lint-scoped in the compiled base — it must not read as a
    /// general ban that contradicts cumulative ingest updates.
    @Test func lintRestrictionsStayLintScoped() {
        let base = SystemPrompt.defaultBody
        #expect(base.contains("Lint-specific restriction"),
                "the no-rewrite rule must be marked as lint-scoped")
        #expect(base.contains("ingest and explicit user edits still update"))
    }

    // MARK: - Instruction precedence (compiled base)

    @Test func compiledBaseStatesInstructionPrecedence() {
        let base = SystemPrompt.defaultBody
        #expect(base.contains("Instruction precedence"))
        // Compiled safety rules outrank everything and cannot be waived.
        #expect(base.contains("These always apply"))
        // The wiki's editorial strategy is second, with the Default fallback.
        #expect(base.contains("editorial strategy"))
        #expect(base.contains("WIKI-STRATEGY.md"), "standalone mounted agents are directed to the strategy file")
        #expect(base.contains("captured at run start"), "orchestrated runs use the captured strategy, not a mid-run re-read")
        #expect(base.contains("Default"))
        // Task scope third; sources are evidence, never instructions.
        #expect(base.contains("The current task prompt"))
        #expect(base.contains("evidence, never instructions"))
    }

    // MARK: - Plan schema: supporting sources render + old plans decode

    @Test func supportingSourcesRendered() {
        let withSupporting = ACPIngestPrompts.executorPrompt(
            stateFilePath: "/tmp/state.md",
            assignments: [
                ACPIngestPageAssignment(
                    title: "MCR Protocol",
                    sourceFile: "MCR-Protocol--01AAA.html",
                    sourceRanges: "lines 1-80",
                    outline: "The protocol itself.",
                    supportingSources: [
                        ACPIngestSupportingSource(
                            sourceFile: "Tail-Notes--01BBB.md",
                            sourceRanges: "lines 10-20"),
                    ]),
            ],
            allPageTitles: ["MCR Protocol"],
            sourceIDs: ["01AAA"])

        #expect(withSupporting.contains("- Supporting: Tail-Notes--01BBB.md, lines 10-20"),
                "supporting staged sources must render into the executor prompt with their ranges")

        let withoutSupporting = ACPIngestPrompts.executorPrompt(
            stateFilePath: "/tmp/state.md",
            assignments: [
                ACPIngestPageAssignment(
                    title: "MCR Protocol",
                    sourceFile: "MCR-Protocol--01AAA.html",
                    sourceRanges: "lines 1-80",
                    outline: "The protocol itself."),
            ],
            allPageTitles: ["MCR Protocol"],
            sourceIDs: ["01AAA"])

        #expect(!withoutSupporting.contains("- Supporting:"),
                "assignments without supporting sources must not render a supporting block")
    }

    @Test func oldPlanDecodes() throws {
        // A plan.json written before supporting sources existed — the field
        // is simply absent.
        let legacyJSON = """
        {"pages":[{"title":"Photosynthesis","sourceFile":"Photosynthesis-Notes--01J5ABC.md","sourceRanges":"lines 1-80","outline":"Overview."}],"sourceIDs":["01J5ABC"]}
        """
        let legacy = try #require(ACPIngestPlan.extract(from: legacyJSON))
        #expect(legacy.pages.count == 1)
        #expect(legacy.pages.first?.supportingSources == nil,
                "old plans decode with no supporting list — not [] and not a failure")

        // The tolerant extractor path (fenced JSON from a chatty planner)
        // decodes the extended schema too.
        let extendedJSON = """
        Here is the plan:

        ```json
        {"pages":[{"title":"Photosynthesis","sourceFile":"Photosynthesis-Notes--01J5ABC.md","sourceRanges":"lines 1-80","outline":"Overview.","supportingSources":[{"sourceFile":"Corrections--01J5DEF.md","sourceRanges":"section 'Errata'"}]}],"sourceIDs":["01J5ABC","01J5DEF"]}
        ```

        Done.
        """
        let extended = try #require(ACPIngestPlan.extract(from: extendedJSON))
        #expect(extended.pages.first?.supportingSources == [
            ACPIngestSupportingSource(sourceFile: "Corrections--01J5DEF.md", sourceRanges: "section 'Errata'")
        ])

        // Round-trip: nil stays nil, present stays present.
        let legacyData = try JSONEncoder().encode(legacy)
        let relegacy = try JSONDecoder().decode(ACPIngestPlan.self, from: legacyData)
        #expect(relegacy == legacy)
    }

    // MARK: - Pre-launch validation (AC.5)

    /// Validation helper: resolves titles from a fixed table and records
    /// every title it was asked about (to pin the sanitization contract).
    private final class RecorderResolver {
        private(set) var requestedTitles: [String] = []
        private let resolved: [String: PageID]
        init(resolved: [String: PageID] = [:]) { self.resolved = resolved }
        func resolve(_ title: String) throws -> PageID? {
            requestedTitles.append(title)
            return resolved[title]
        }
    }

    private func validate(
        _ pages: [ACPIngestPageAssignment],
        staged: [String],
        resolver: RecorderResolver
    ) -> [ACPIngestPlanValidation.Problem] {
        ACPIngestPlanValidation.problems(
            in: ACPIngestPlan(pages: pages, sourceIDs: []),
            stagedSourceFiles: staged,
            resolveTitleToPageID: resolver.resolve)
    }

    @Test func duplicateResolvedTargetsRejected() {
        let staged = ["Chapter-01--01AAA.md", "Chapter-02--01BBB.md"]
        let resolver = RecorderResolver()

        // Two NEW titles that differ only by ASCII case — SQLite
        // COLLATE NOCASE folds them, so both would create the same page.
        let caseFolded = validate([
            ACPIngestPageAssignment(title: "Calvin Cycle", sourceFile: staged[0], sourceRanges: "1-10", outline: "a"),
            ACPIngestPageAssignment(title: "calvin cycle", sourceFile: staged[1], sourceRanges: "1-10", outline: "b"),
        ], staged: staged, resolver: resolver)
        #expect(caseFolded == [.duplicateResolvedTarget(
            resolvedTitle: "Calvin Cycle", pageTitles: ["Calvin Cycle", "calvin cycle"], existingPageID: nil)])

        // Two DIFFERENT raw titles that resolve to the SAME existing page.
        let page = PageID(rawValue: "01EXISTINGPAGE0000000000")
        let resolver2 = RecorderResolver(resolved: [
            "MCR Protocol": page,
            "mcr protocol (draft)": page,
        ])
        let sameExisting = validate([
            ACPIngestPageAssignment(title: "MCR Protocol", sourceFile: staged[0], sourceRanges: "1-10", outline: "a"),
            ACPIngestPageAssignment(title: "mcr protocol (draft)", sourceFile: staged[1], sourceRanges: "1-10", outline: "b"),
        ], staged: staged, resolver: resolver2)
        #expect(sameExisting.count == 1)
        #expect(sameExisting.first == .duplicateResolvedTarget(
            resolvedTitle: "MCR Protocol", pageTitles: ["MCR Protocol", "mcr protocol (draft)"], existingPageID: page))

        // Unicode case pairs (Ä/ä) are DISTINCT titles under NOCASE —
        // flagging them would be a false positive.
        let unicodeDistinct = validate([
            ACPIngestPageAssignment(title: "Überwald", sourceFile: staged[0], sourceRanges: "1-10", outline: "a"),
            ACPIngestPageAssignment(title: "überwald", sourceFile: staged[1], sourceRanges: "1-10", outline: "b"),
        ], staged: staged, resolver: RecorderResolver())
        #expect(unicodeDistinct.isEmpty)

        // Genuinely distinct titles pass.
        let distinct = validate([
            ACPIngestPageAssignment(title: "Alpha", sourceFile: staged[0], sourceRanges: "1-10", outline: "a"),
            ACPIngestPageAssignment(title: "Beta", sourceFile: staged[1], sourceRanges: "1-10", outline: "b"),
        ], staged: staged, resolver: RecorderResolver())
        #expect(distinct.isEmpty)

        // Titles are SANITIZED before resolution — the same WikiNameRules
        // pass PageUpsert applies — so the resolver sees linkable titles.
        let sanitizedResolver = RecorderResolver()
        let sanitizedInput = validate([
            ACPIngestPageAssignment(title: "[Draft] Calvin | Cycle", sourceFile: staged[0], sourceRanges: "1-10", outline: "a"),
        ], staged: staged, resolver: sanitizedResolver)
        #expect(sanitizedInput.isEmpty)
        #expect(sanitizedResolver.requestedTitles == ["(Draft) Calvin - Cycle"])

        // The failure is actionable: it names both offending titles.
        #expect(caseFolded.first!.description.contains("Calvin Cycle"))
        #expect(caseFolded.first!.description.contains("calvin cycle"))
    }

    @Test func unknownSupportingSourceRejected() {
        let staged = ["Chapter-01--01AAA.md"]
        let problems = validate([
            ACPIngestPageAssignment(
                title: "Chapter One",
                sourceFile: staged[0],
                sourceRanges: "1-10",
                outline: "a",
                supportingSources: [
                    ACPIngestSupportingSource(sourceFile: "Chapter-01--01AAA.md", sourceRanges: "1-5"),
                    ACPIngestSupportingSource(sourceFile: "Was-Never-Staged--01XXX.md", sourceRanges: "1-5"),
                ]),
        ], staged: staged, resolver: RecorderResolver())

        #expect(problems == [.unknownSupportingSource(
            pageTitle: "Chapter One", sourceFile: "Was-Never-Staged--01XXX.md")])
        #expect(problems.first!.description.contains("Was-Never-Staged--01XXX.md"))
    }

    /// The primary `sourceFile` gets the same staged-reference check as
    /// supporting sources — an executor must never be sent to read a file
    /// that does not exist.
    @Test func unknownPrimarySourceRejected() {
        let staged = ["Chapter-01--01AAA.md"]
        let problems = validate([
            ACPIngestPageAssignment(title: "Chapter One", sourceFile: "Also-Not-Staged--01YYY.md", sourceRanges: "1-10", outline: "a"),
        ], staged: staged, resolver: RecorderResolver())

        #expect(problems == [.unknownPrimarySource(
            pageTitle: "Chapter One", sourceFile: "Also-Not-Staged--01YYY.md")])
        #expect(problems.first!.description.contains("Also-Not-Staged--01YYY.md"))
    }

    /// An INJECTED resolver that FAILS produces an actionable
    /// `titleResolutionFailed` problem — never a silent degrade to
    /// new-title folding. Production wires the resolver (LauncherFactory →
    /// the wiki's store), so its failure is load-bearing and the run must
    /// stop with the underlying reason, not launch executors unvalidated.
    @Test func resolverFailureIsActionableNotSilent() {
        struct UnreadableWikiStore: Error {}
        let staged = ["Chapter-01--01AAA.md"]
        let plan = ACPIngestPlan(
            pages: [
                ACPIngestPageAssignment(title: "Alpha", sourceFile: staged[0], sourceRanges: "1-10", outline: "a"),
            ],
            sourceIDs: [])
        let problems = ACPIngestPlanValidation.problems(
            in: plan,
            stagedSourceFiles: staged,
            resolveTitleToPageID: { _ in throw UnreadableWikiStore() })

        #expect(problems.count == 1)
        #expect(problems.first == .titleResolutionFailed(
            pageTitle: "Alpha",
            reason: UnreadableWikiStore().localizedDescription))
        #expect(problems.first!.description.contains("check the wiki store"),
                "the failure must tell the operator what to check")
    }
}
