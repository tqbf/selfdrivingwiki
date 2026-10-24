# Independent implementation review — generalized page-validity lint

- Reviewer: claude-opus-5-5 (non-author)
- Date: 2026-10-24
- Branch: `feature/generalized-page-validity-lint` at `f18f34ec`, base `5aeadc68` (28 commits, 102 files, +11.4k/−0.4k)
- Method: read-only. The main checkout is on `main`, so the branch tree was exported with `git archive` to `/tmp/lintreview` and read there. Suspicions were confirmed with standalone Swift scripts in `/tmp/lintreview-scratch` that copy the relevant logic verbatim (no repo build, no `make test`).
- Line numbers refer to the branch tree.

## Overall verdict

**Not ready to merge as a safety feature. The building blocks are good, but the main enforcement layers are not connected to any production path.** The pieces themselves are well made:

- the typed policy enum and the payload-conditioned allowlist;
- the atomic exact-body patch with provenance union;
- the strict report parser and coverage validator;
- the acceptance-gate record format.

The problem is what runs in production:

- **No production code ever mints a lint policy.** Every lint child still runs with `.ordinaryManaged` authority, so the receipt gate, page pinning, creation/index denial, and "report-only by construction" are enforced only in tests that build the lease by hand.
- **No production code runs the post-run accounting.** The only path with coverage validation, the REQ-54 compare, and the agent-log check is `runOneLintPage`, and it has no callers. Both queue providers, which run every production lint including the scheduled path that bailed in #1461, report "run completed" from the launcher exit status alone.
- **Two crash/corruption defects in the deterministic core:**
  - Detector offsets drift whenever protected code contains non-ASCII text. When the drift pushes a match past the end of the body, the detector raises an uncatchable `NSRangeException`, and that path is reachable inside `wikid` after every committed lint patch.
  - The patch composer can commit bytes that differ from the hunks it validated (an insertion and a replacement at the same offset).
- **The report-truth layer accepts an untouched skeleton as "coverage complete."**

The implementation document's "Key semantics" section describes guarantees the shipped binary does not provide. It should be corrected along with the code.

## Findings

Severity scale: **critical** = security / data loss / correctness; **major** = broken behavior or dishonest reporting; **minor** = robustness / clarity.

### C1 — critical — Lint policies are never minted in production; every lint child runs with ordinary edit authority

- **Where:**
  - `Sources/WikiFSEngine/AgentLauncher.swift:408`: `manager.issueScopedRun(for: wikiID, policy: .ordinaryManaged)` is unconditional, and the only issue site.
  - `grep` finds no production use of `.lintSelectedPageRepair`, `.lintSelectedPageReportOnly`, or `.lintWholeWikiReportOnly` outside the guard and dispatcher `switch` statements.
  - The AC.5 live test builds the policy by hand: `Tests/WikiFSAppTests/AgentSandboxProcessTests.swift:975` calls `broker.launchScopedRun(… operationPolicy: .lintSelectedPageRepair(…))` directly, bypassing the launcher.
- **What it breaks:**
  - The rollout gate's report-only decision (`AgentOperationRunner.makeLintPagePlan`, `repairAuthorized=false`) reaches only the prompt's `{{repairAuthorization}}` block. It never reaches the lease.
  - The docs say otherwise: `plans/agent-sandbox-scoping.md` ("Lint operation policies … Status: IMPLEMENTED … the rollout gate … selects the policy") and `plans/generalized-page-validity-lint-implementation.md` ("unaccepted configurations run REPORT-ONLY by construction").
  - REQ-06, REQ-11, REQ-15, REQ-49, REQ-51 and REQ-52 ("no full-body rewrite path") are not enforced for any real run.
- **Failure scenario:**
  1. Enqueue a selected-page lint for page P.
  2. The gate selects report-only (it always does today).
  3. The child ignores the prompt and runs any of:
     - `wikictl page add --title P --body <whole rewritten body>` (a blind, canonicalizing full-body rewrite);
     - `page add --title NewPage …` (page creation);
     - `page patch --id OTHER …` with no receipt;
     - `index set …` or a strategy write.
  4. All of these pass, because `.ordinaryManaged` grants `wikiEdit`. `applyLintReceiptLifecycle` returns `nil` for non-repair policies (`DaemonDomainSocketDispatcher.swift:212`), so receipts are never required.
- **Fix direction:**
  - Derive the policy from the `OperationRequest` in the launcher: `.lintPage(page, repairAuthorized: true)` → `.lintSelectedPageRepair(page.id)`; `repairAuthorized: false` → `.lintSelectedPageReportOnly(page.id)`; `.lint` → `.lintWholeWikiReportOnly`.
  - Thread it through `issueScopedRunIfConfigured` and the second issue site at `AgentLauncher.swift:3911`.
  - Add a launcher-level test: run a `.lintPage` request through `AgentLauncher.run` and assert the registered grant's `operationPolicy`.
  - Decide what lint does when scoped runs are not configured (the unscoped child). Recommendation: refuse to launch lint at all.

### C2 — critical — Detector offsets drift on non-ASCII protected code; a large drift crashes the process (`NSRangeException`)

- **Where:** `Sources/WikiFSCore/Core/Lint/LintDetectors.swift`.
  - The regexes run over `maskedBody` (built by `byteMasked`, `:89`).
  - The UTF-16 match ranges are then converted against the **source**: `utf8Range(match.range, in: source)` and `(source as NSString).substring(with: match.range)` at `:538/539`, `:684`, `:697`, `:711`, `:737`, `:804`, `:816`, `:867` (placeholders D14, mojibake/entities D17/D26, meta-text D24, and the other masked-regex detectors).
- **Why it fails:** `byteMasked` keeps the UTF-8 length, but each masked multi-byte scalar becomes *k* spaces, which is *k* UTF-16 units instead of 1 or 2. Every match after protected non-ASCII text therefore lands at a shifted UTF-16 offset in `source`.
- **Reproduced** (script copies the mask, regex, and conversion logic):
  - Body: three-backtick fence, `漢字漢字漢字` inside it, then `See the TODO marker …`.
  - Result: the match reports UTF-16 location 35 (true location 23) with evidence `"and "`.
  - Body: a fence holding 20 CJK characters, then `TODO\n`.
  - Result: `*** Terminating app due to uncaught exception 'NSRangeException' … Range {69, 4} out of bounds; string length 34`.
  - `utf8Range` degrades to `zeroRange`, but `substring(with:)` is an Objective-C exception, which Swift cannot catch.
- **Crash sites:**
  - `wikid`'s post-commit `recordWrittenVersionVerification` → `LintPagePreflight.scan` (`DaemonDomainSocketDispatcher.swift:395`), which takes the daemon down.
  - `makeLintPagePlan` in the app and daemon queue hosts.
- **Silent damage short of a crash:**
  - Wrong `authoredRange` and wrong evidence are shown to the agent.
  - The agent's hunks then fail `oldText` (safe, but the run cannot repair).
  - Verification's `insideHunk` attribution becomes wrong.
- **Coverage gap:** no detector fixture puts non-ASCII text inside protected code before a regex-detected construct. `LintMarkdownAnalysisTests:130` has non-ASCII only outside code.
- **Fix direction:**
  - Convert ranges against `maskedBody`. Its UTF-8 byte offsets equal the source's, so `utf8Range(match.range, in: maskedBody)` is correct.
  - Slice evidence from `source` by that UTF-8 range, never by the masked UTF-16 range.
  - Better: mask by replacing each protected *scalar* with one space-equivalent of the same UTF-16 width, or run the regexes over source and filter matches by protected UTF-8 ranges.
  - Add fixtures with CJK/emoji inside fences and inline code, followed by D14/D17/D24/D26 triggers near EOF.

### C3 — critical — The patch composer commits bytes that differ from the validated hunks (insertion plus replacement at one offset)

- **Where:** `Sources/WikiFSCore/Core/PagePatch.swift:159-194`.
  - Validation sorts by `startByte` only.
  - The overlap check rejects `hunk.start < previous.end`, or an identical `(start, end)` pair.
  - Application then sorts by `startByte` descending and mutates `composed` in place using offsets from the *original* body.
- **Why it fails:** when an insertion `(s, s)` sorts before a replacement `(s, e)`, validation passes (`s < s` is false; the ranges differ). The stable descending sort then applies the insertion first, so the replacement's range covers inserted text instead of the validated `oldText`.
- **Reproduced** (verbatim logic, body `abcdefgh`):
  - `[ins(3,3,"X"), repl(3,6,"def"→"")]` gives `abcfgh`. Intended: `abcXgh`. The inserted `X` is lost and `f`, declared deleted, survives.
  - `[ins(3,3,"é"), repl(3,4,"d"→"D")]` gives `abcDédefgh`. The validated `d` is never replaced, and the replacement range splits a scalar.
  - In the opposite submission order the overlap check rejects, so the result depends on submission order.
- **Impact:**
  - `GRDBWikiStore.patchPage` (`:4994`) commits a version whose bytes are not the declared edit. It reports `appliedClasses` as if the hunks applied, and the WikiStore doc's "untouched bytes byte-identical / exact ranged edits" contract is violated.
  - Bytes outside the union of hunk ranges stay intact.
  - The eval oracle cannot catch this: `LintDiffOracle.apply` (`Sources/WikiLintEval/LintDiffOracle.swift:121-130`) uses the same reverse-sort apply, so reproduction "matches" and the corrupted outcome is accepted.
  - `validatorRejectsInvalidHunks` covers only two insertions at one offset.
- **Fix direction:**
  - Compose by concatenation instead: sort by `(start, end)`, walk the original bytes, and emit `original[cursor..<start] + newText`. Reject any two hunks that share a start offset when either is zero-length, or define insertion-before-replacement explicitly.
  - Use the same composer in the oracle, and test both submission orders.

### M1 — major — Production lint never validates the run report, re-verifies the write, or checks the agent log

- **Where:**
  - `AgentOperationRunner.runOneLintPage` (`Sources/WikiFSEngine/AgentOperationRunner.swift:685`) and `runLintPages` (`:852`) have **no callers** in `Sources/`. On base `5aeadc68` the app UI also routed lint through the queue.
  - Production goes through `AppQueueIngestionProvider.runLintPages` (`Sources/WikiFS/Queue/AppQueueIngestionProvider.swift:466-500`) and `DaemonQueueIngestionProvider.runLintPages` (`Sources/wikid/DaemonQueueIngestionProvider.swift:312-360`).
  - Those set `observed.append("<title>: run completed")` from launcher exit status (app) or unconditionally (daemon).
  - `QueueIngestionReporting.agentCompletionMutation` then marks the report `availability: .available` with "Per-page lint outcomes: … run completed".
- **What it breaks:** REQ-32 (harness checks coverage), REQ-36/53 (app re-scan), REQ-38 (log contract), REQ-54 (post-write check) and REQ-33 (distinguish outcomes) are unenforced for every real run.
- **Failure scenario (the #1461 shape):**
  1. A scheduled lint of a page with a hidden malformed table runs.
  2. The agent writes "needs no changes" and never touches `LINT_RUN_REPORT.md`.
  3. The queue item finishes with "Per-page lint outcomes: Page: run completed", shown as an available, successful report.
- **Fix direction:**
  - Factor `runOneLintPage`'s accounting into a host-agnostic function and call it from both queue providers.
  - Fail the page (and the observed summary) on rejected coverage, failed verification, or a missing agent log.

### M2 — major — The host-staged skeleton, untouched, validates as "coverage complete"

- **Where:** `LintRunReportParser.parseOutcome`, `Sources/WikiFSCore/Core/Lint/LintAuditReport.swift:336-346`.
  - An unknown outcome token, including the skeleton's own `pending`, becomes `.unresolved(reason: "unparseable outcome token in: …")`.
  - The comment at `:343` says this surfaces "via reason loss", but the reason is *non-empty*.
  - `LintCoverageValidator` (`:416-441`) only checks that the reason is non-empty, so every `check … pending` line passes.
  - Item and finding lines are never reason-checked (`:397-411`), so `finding X valid-as-written` with no reason also passes.
- **Failure scenario:**
  1. The agent does nothing to `LINT_RUN_REPORT.md`.
  2. The parser accepts it: page, head, fingerprint, and inventory are host-rendered and correct; every ID appears once.
  3. `validate` returns `.complete`.
  4. `runOneLintPage` records "run-report coverage complete", lists every finding as "unresolved", and keeps `status = .dispatched`.
  5. A one-line `sed s/pending/valid-as-written|ok/` passes just as easily.
  - The plan treats this as checklist theater. The deterministic layer should at least reject the unfilled form.
- **Fix direction:**
  - Throw `malformedLine` for unknown outcome tokens, including `pending`.
  - Require non-empty reasons for `valid-as-written`, `unresolved`, `outside-scope`, and `blocked` on items and findings too.
  - Require the `verification` line to be filled.
  - Add a test that the rendered skeleton is rejected.

### M3 — major — Verification compare scans with inconsistent facts, a self-compared head, and an aggregate change region

- **Where:** `AgentOperationRunner.swift:776-789`, plus `LintVerification.compare` (`LintAuditReport.swift:494-564`).
  - **(a) Different facts.** The written-head scan passes only `resolution` (no citations, origin URLs, history, or fence-validation facts). The pre-run `plan.preflight` used all of them. That violates REQ-45 (compatible rules).
    - D09, D27 and D28 findings vanish from the written scan. They carry no `candidateRepair`, and D09 also has no range, so `compare` ignores their disappearance.
    - **Lie scenario:** the agent claims `finding D09-1 repaired` and writes nothing. `persisted` is false, so the verdict is `verified`.
    - **Inverse:** a D11 exact-origin raw-URL finding *has* a `candidateRepair`. When the agent correctly leaves it alone (every report-only run today), it "disappeared outside the applied hunks", so verification fails on every such page with no write at all.
  - **(b) Self-compared head.** `writtenHead: writtenRead.headVersionID, currentHead: writtenRead.headVersionID` (`:787-788`) both come from the same post-run read.
    - `.verifiedWrittenHeadDiverged` is unreachable.
    - If another writer commits after the agent's patch, the gate scans *that* version and `observedChangeRanges` attributes the other writer's edits to the agent, while the detail claims "verified on the written head".
  - **(c) Aggregate change region.** `observedChangeRanges` returns one prefix/suffix-trimmed region. Two hunks at bytes 10 and 9000 make everything between them count as "inside a hunk", so the unattributed-vanish check becomes vacuous.
  - **(d) No required write.** A claimed repair is never required to intersect an observed change.
- **Fix direction:**
  - Build the written scan with the same fact loaders.
  - Take the written head from the patch outcome (or the daemon record) and read that immutable version, not the current head.
  - Compute per-hunk ranges from the server's `PagePatchOutcome`.
  - Require each claimed repair's range to intersect an applied hunk.

### M4 — major (latent until C1 is fixed) — The receipt does not bind head or body, and survives a CAS conflict

- **Where:**
  - `DaemonLintRunState.validateReceipt` (`Sources/wikid/DaemonLintRunState.swift:82-86`) compares the token only. The stored `headVersionID` and `bodyFingerprint` are never consulted.
  - The dispatcher (`DaemonDomainSocketDispatcher.swift:219-230`) never compares `receipt.headVersionID` with `payload.expectHead`.
  - On `.casConflict` it calls `recordConflict` (`:252`) but does **not** invalidate the receipt.
- **Contradiction:** the file header says the receipt "ties to the head AND the body fingerprint (an old body cannot pass with a refreshed head)". `casBudgetAndReceipts` says "a conflict … demands a NEW receipt" but never asserts the old token fails afterwards.
- **Failure scenario:**
  1. The child reads P (receipt R for H1).
  2. A concurrent writer commits H2.
  3. The child's patch with `expectHead=H1` conflicts (budget 1/2).
  4. The child learns H2 from a non-minting read (`page info` or `page history`, or a non-JSON `page get`).
  5. It re-submits the **old** hunks with `expectHead=H2` and receipt R. The receipt passes and CAS passes.
  - The only remaining guard is the per-hunk `oldText`, so any hunk whose bytes did not move commits against a body the agent never read. That is the replay REQ-16 forbids, bounded by `oldText`.
- **Fix direction:**
  - Require `receipt.headVersionID == payload.expectHead`.
  - Invalidate the receipt on any non-success reply, conflict included.
  - Optionally re-fingerprint the body under the store transaction.

### M5 — major — Patch integrity accepts nonexistent version pins (REQ-09/REQ-54)

- **Where:** `GRDBWikiStore.patchPageLocked` (`Sources/WikiFSCore/Store/GRDBWikiStore.swift:5057-5066`).
  - `link.versionPin.flatMap { resolveVersionPin(...) }` yields `nil` for a non-numeric or out-of-range pin (`resolveVersionPin`, `:3447-3454`).
  - `sourceMarkdownContent` then falls back to the **active head** (`:5150`).
  - A pinned citation *without* a fragment is never pin-checked at all.
- **Failure scenario:** a hunk adds `[[source:<ID>@v99#"text that is in the active head"]]`, or just `[[source:<ID>@v99]]`. The patch commits.
- **Test gap:** `pinnedQuoteChecksThePinnedVersion` covers only existing pins.
- **Fix direction:** if a pin is present and does not resolve, throw a new `PagePatchIntegrityError.unresolvedPin`, whether or not a fragment exists.

### M6 — major — The daemon queue host log reports another run's verification and a mislabeled "written_head"

- **Where:**
  - `DaemonQueueIngestionProvider.swift:338-346` uses `lintRunState.latestVerificationRecord(pageID:)`, which spans every run since daemon start (`DaemonLintRunState.swift:137-141`).
  - `forget(runID:)` is never called (no callers), so records never expire.
  - `written_head` is simply the current head.
  - The daemon's own record scans the *current* head after commit, not the written version (`DaemonDomainSocketDispatcher.swift:391`), with a facts-less scan (`:395`).
- **Failure scenario:**
  1. Run 1 patches page P, which records verification V1.
  2. A day later, run 2 on P writes nothing.
  3. The host log for run 2 says `written_head=<current>; verification=written <V1 head>; classes=D25; remaining=0`. That is a write and verification run 2 never made.
- **Fix direction:**
  - Key lookups by run id. The host knows the lease it issued.
  - Clear records on teardown (call `forget`).
  - Log `written_head` only when this run's patch outcome exists.
  - Scan the reply's written version id.

### M7 — major (latent until M1 is fixed) — Agent-log detection is not scoped to the page or the author

- **Where:** `AgentOperationRunner.swift:826`: `recentLogEntries(limit: 50).contains { $0.kind == .lint && $0.timestamp >= runStart }`.
- **Failure scenarios:**
  - A concurrent lint in the other host (the daemon queue while the app runs), or this agent logging for a *different* page, satisfies the check.
  - More than 50 log appends during a long run (a concurrent ingest) push the real entry out of the window, giving a false "AGENT LOG MISSING".
- **Fix direction:** query by time window rather than count, and match the page title or id (and ideally the run's author identity).

### M8 — major — The rollout gate key is a constant, publicly computable digest

- **Where:** `AgentOperationRunner.swift:583` passes `provider: "unconfigured", model: "unconfigured", effort: "unconfigured"` into `LintCoordinatorGate.selection`.
- **Why it matters:**
  - The resulting key is a fixed SHA-256 of constants plus the shipped prompt and fixture digests.
  - Any same-user process can write `<AppGroup>/lint-acceptance/<key>.json` with any non-empty `rubricReviewer`. `LintAcceptanceRecord.isValid` checks shape only, with no freshness and no tie between rubric fixture ids and the manifest.
  - That one file authorizes repairs for **every** provider and model. Today, because of C1, that changes only the prompt; once C1 is fixed it changes the lease.
  - Conversely, a legitimate record keyed to a real model can never match.
  - The comment "an unconfigured key never matches a record" is false. AC-14 (model change re-gates) is not implemented.
- **Fix direction:**
  - Pass the resolved provider, model, revision, and effort.
  - Hard-fail to report-only when any component is unknown or `"unconfigured"`, *before* the record lookup.
  - Enforce freshness (`rubricDecidedAt` age) and that rubric fixture ids cover the manifest.
  - Confirm the seatbelt profile denies child writes to `lint-acceptance/`.

### M9 — major — Evaluator negative controls are weaker than documented

- **(a) Trap on duplicate classes.** `LintEvalScoring.score` builds `Dictionary(uniqueKeysWithValues:)` keyed by class (`Sources/WikiLintEval/LintEvalScoring.swift:58-59`). A fixture seeding two defects of one class (two broken tables) is a fatal trap, and the manifest loader does not validate this.
- **(b) Class-granular scoring.** Recall and precision count classes, not defects. Repairing one of two seeded D03 defects is a full hit. A false-confirmed finding of a seeded class is invisible. The plan scores "each seeded defect".
- **(c) Loose declaration match.** `LintDiffOracle` matches on `defectClass + oldText` with `first(where:)` (`:98-110`). It ignores the range and never consumes a declaration, so a declared repair applied at a *different* occurrence of the same text (for example another fence), or applied twice, is accepted unless protected ranges happen to cover it.
- **(d) Narrow full-body check.** It fires only for a *single* hunk covering at least 80% (`:87-92`). Two 50% hunks, or one 79% hunk, evade it for judgment fixtures.
- **(e) Shared apply bug.** The oracle's `apply` shares C3's bug.
- **(f) Wrong bail shape.** The shipped canonical gate's bail fixtures are `bail-d25-wrap` (D25) and `held-bail-merge-markers` (D15). Both are **pre-flight-detected** classes, so neither reproduces the #1461 shape AC-07 requires ("clean pre-flight report and one seeded hidden defect"). There is no hidden table or raw-URL bail fixture and no long-page *bail* fixture (AC-11). The only long fixture is report-only D14.
  - The digest is frozen into the acceptance key, so evidence gathered on this set would be accepted for rollout.
- **Fix direction:**
  - Score per seeded defect (by id and range).
  - Match declarations by range and consume each once.
  - Detect rewrites by the total fraction of bytes changed.
  - Add hidden-defect bail fixtures (table, raw URL) that the current detectors miss, and a long late-defect bail fixture, before freezing the digest.

### m1 — minor — `lastScratchDirectory` is stale or nil on early-return paths

- **Where:** `AgentLauncher.swift` sets `lastScratchDirectory` only at `:1736`. The model guard (`:1701`), ACP spawn resolution (`:1716`), and scratch failure (`:1729`) return earlier.
- **Impact:**
  - For page N>1, `runOneLintPage` reads page N−1's report and fails with a misleading "report names page …" reason.
  - For the first page it records "no run scratch" (`AgentOperationRunner.swift:809`) but leaves `status = .dispatched`.
  - `run(...)`'s outcome (`preflightError`, `exitStatus`) is never consulted.
- **Fix direction:** reset `lastScratchDirectory = nil` at run start, and treat a launcher preflight error as `.failed`.

### m2 — minor — A no-op patch is not "empty"

- **Scenario:** a hunk with `oldText == newText`. `createPageVersionWithProvenance` short-circuits (`didWrite: false`), but `patchPage` ignores that.
  - It still emits a page event.
  - The dispatcher invalidates the receipt and records a "verification".
  - If the author differs from `last_edited_by`, a **new version with an identical body** is created (#763 fall-through).
- **Contradiction:** the `WikiStore.patchPage` doc says an empty patch "writes nothing, creates no version, and emits no event".
- **Fix direction:** reject `composedBody == pageBody` with a typed error.

### m3 — minor — D03 counts escaped pipes; the line table ignores CR-only line endings

- **Escaped pipes:** `pipeCells` (`LintDetectors.swift:322`) splits on every `|`. A body row `| a \| b | c |` in a two-column table yields 3 cells, a false D03, though the plan requires escaped pipes be respected. No fixture covers it.
- **CR-only bodies:** `MarkdownSourceLineTable` (`MarkdownAnalysis.swift:15`) splits only on `\n`. cmark treats a lone `\r` as a line ending, so CR-only bodies mis-map AST ranges, the protected ranges drop, and code is not masked.

### m4 — minor — `LintVerification` identity collapses duplicates

- **Where:** identity is `class|evidence` with `uniquingKeysWith: first` (`LintAuditReport.swift:505-511`).
- **Scenario:** two identical raw URLs, one repaired. The survivor makes the repaired one look "persisted", a false failure.

### m5 — minor — Daemon lint state is never torn down

- **Where:** `DaemonLintRunState.forget` has no callers.
- **Impact:** receipts, conflict counters, closed-run sets and verification records grow for the daemon's lifetime. This also feeds M6.

### m6 — minor — The Phase 0 bracket fix is now dead code

- **Where:** `WikiStoreModel.preflightLint` has no callers on the branch. The implementation doc lists "bracket fix under CAS" as landed. `repairLocations` is documented as ranges "in the ORIGINAL (pre-fix) body" but holds ranges from the recomposed snapshot after a conflict.
- **Fix direction:** either delete it or make it a candidate repair surfaced by the new pre-flight.

### m7 — minor — App queue: only the last page's launcher outcome throws

- **Where:** `AppQueueIngestionProvider.swift:503`.
- **Impact:** an earlier page's failure is only in the summary. A last-page failure throws and discards the per-page summary of earlier pages.

### m8 — minor — The fixture digest re-encodes the decoded struct

- **Where:** `LintEvalFixtureManifest.digest`.
- **Impact:** JSON fields absent from the Codable model never affect the digest, and the digest depends on `JSONEncoder` output details. This fails safe (report-only) but is surprising.

## Checked and sound

1. **Guard/wire key parity.**
   - `logAppendPayloadKind` decodes `kind`, the same key `DaemonLogAppendRequest` uses.
   - `patchPayloadPageID` decodes `id`, the same key `DaemonPagePatchRequest` uses. The command handler acts on the same decoded payload, so a key-alias bypass is not possible.
   - Unreadable payloads deny.
   - Report-only and whole-wiki policies deny `patch`.
   - Only `.page`/`patch` reaches the patch handler: `DaemonCommandRouting` maps `.patch` to exactly that family and operation. No alternate family carries it.
   - The 24 `.allow(.wikiRead)` table entries are genuine reads.
2. **Receipt mint and absence.**
   - A missing or forged `lint_receipt` under the repair policy denies with the generic message.
   - A closed run denies before receipt validation.
   - A committed patch invalidates the receipt before the reply returns.
   - Minting happens only on a successful `--id`-selector read of the selected page.
3. **Conflict budget.** `maxConflicts = 2` gives exactly one recomposition, matching REQ-15/16. Two concurrent patches presenting one receipt are serialized by the store's CAS, so only one can commit.
4. **Patch atomicity.**
   - CAS check, validation, integrity check, version write, and link replacement all run inside one `mutate` savepoint.
   - Every rejection throws before the version write.
   - The event closure runs only on success. Reviewed together with `rejectedPatchWritesNothingAndEmitsNothing`.
   - No event is emitted on reject or conflict (apart from m2).
5. **Provenance union.** The `page_version_sources` primary key is `(page_version_id, source_id, role)`, so `(sourceID, .quoted)` alongside an existing `(sourceID, .primary)` is legal. Head inputs carry forward unchanged, and existence is checked in `normalizedPageVersionProvenance`.
6. **Validator basics** for non-colliding hunks:
   - range bounds;
   - UTF-8 scalar-boundary checks;
   - exact `oldText` byte equality;
   - overlap rejection for distinct-start overlaps;
   - reverse application when starts differ (the repl-first case in the C3 script rejects as intended);
   - report-only classes cannot authorize hunks;
   - payload size cap.
7. **Quote check with a valid pin** uses the pinned `source_markdown_versions` row (whitespace-normalized, case-sensitive).
8. **Coverage validator, apart from M2:**
   - page and head identity;
   - inventory totals;
   - unknown, duplicate, and missing occurrence ids;
   - exactly one outcome per audit step;
   - steps cannot claim `repaired`;
   - report-only findings cannot claim `repaired`.
   - The parser rejects unknown labels and duplicate structural lines.
9. **Footnote analysis** (`MarkdownFootnoteAnalysis`) computes UTF-16 ranges against the source with UTF-16 protected ranges, so it is consistent and does not share C2.
10. **`byteMasked`** preserves UTF-8 byte length for scalar-aligned ranges, so UTF-8 offsets agree between masked and source text. The defect is only in the UTF-16 conversion (C2).
11. **Line table, LF and CRLF.** Columns are UTF-8 based, and `\r\n` bodies map correctly. This agrees with `LintMarkdownAnalysisTests:130`.
12. **Cancellation in the sequential loops.** All three hosts check `Task.isCancelled` before each page, record skipped pages explicitly, and never retry an earlier page.
13. **`LintAcceptanceGate`.**
    - A missing record means report-only.
    - A malformed or undecodable record throws.
    - A key or filename mismatch throws.
    - A fixture-digest mismatch means report-only.
    - `write(record:)` is called only from tests (grep). `WikiLintEvalRunner run` refuses without `--live`.
    - `shippedFixtureDigestsMatchCanonicalManifests` compares the shipped digest with `canonical().digest()`.

## Not fully verified

- **Nothing was built or tested.** I did not build the branch or run its tests. C2 and C3 were confirmed with standalone scripts that copy the branch logic verbatim. Every other finding comes from reading the code.
- **`AgentLauncher.run` gate acquisition and cancellation races.** I reviewed only the diffed region and the scratch/lease ordering. The generation-slot acquire and release under cancellation was not traced end to end.
- **Whether `pages.body_markdown` can diverge from the head version's body.** For example through workspace publish or `refs` moves. `patchPageLocked` validates against `pages.body_markdown` while CAS checks the `refs` head; if those can differ, the patch base is wrong.
- **Whether the scoped seatbelt profile lets a child write `<AppGroup>/lint-acceptance/`** (relevant to M8).
- **Detector-by-detector false-positive behavior** for D01, D04, D05, D06, D15, D20, D23, D24 and D27. This includes the `MarkdownFenceFacts` overlap-predicate fix (block ranges starting at content rather than indent) and fence nesting inside list and blockquote containers. I sampled D03 and the masked-regex detectors only.
- **Prompt text** (`lint-page-task.md`): wording quality and its consistency with the receipt flag (`--lint-receipt`).
- **`DaemonScopedSocketTests` raw-frame receipt round trip and `DaemonLintPolicyTests` matrix.** I read their structure, not every assertion.
- **The live gate (AC-07 … AC-15).** It is blocked by design. I assessed only the fixture set's shape (M9f).
