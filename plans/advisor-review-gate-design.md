[User] [Advisor] Review: generalized page-validity lint requirements for an LLM-maintained wiki.

CONTEXT. Self Driving Wiki is a macOS app whose wiki pages are authored and maintained by LLM agent runs (ingest/query/lint operations) that edit pages through a CLI (wikictl) under compare-and-swap discipline. Editorial quality is governed by a per-wiki strategy document captured into every run prompt. A single-page lint operation combines (a) mechanical pre-flight scanners that produce a factual worklist and (b) a prompt with named audit steps for the fixing agent. Production failure that motivated this work: a lint audit with a clean pre-flight report concluded "needs no changes" on a page that had a malformed markdown table and raw external URLs — a link-only audit + low-effort model bailed. PR #1462 added pre-flight worklists (broken links, raw URLs, malformed tables) and named audit steps. We now have draft REQUIREMENTS to generalize lint to all validity defects of LLM-authored pages.

THE REVIEW TASK. Read the requirements draft at tmp/generalized-page-validity-lint-requirements.md (21 defect classes D01–D21, each split into mechanical-detection vs judgment boundaries; requirements REQ-01..51; a prioritized pre-flight detector table; a fixture set; live-model acceptance criteria including three repeated runs per fixture at a low-effort tier). Ground your review in the current implementation by also reading: prompts/lint-page-task.md, prompts/system-prompt-default.md, prompts/ingest-write-rule.md, Sources/WikiFSCore/Core/LintPagePreflight.swift, Sources/WikiFSCore/Core/WikiOperation.swift (the lintPagePrompt function), Sources/WikiFSLinks/WikiLinkSpan.swift.

ANSWER THESE QUESTIONS with reasoning:
1. Is the defect taxonomy complete for LLM-authored markdown wiki pages? What real defect classes are missing?
2. Is the mechanical-vs-judgment boundary drawn at the right places? Where will it fail in practice?
3. Are the hard limits (no editorial rewrites, no page creation for broken links, no invented evidence, untrusted source content) coherent, and are they enforceable by prompt alone given instruction precedence (application rules > strategy > task)?
4. Are the success criteria sufficient — especially AC-07/AC-14 (three repeated live runs per fixture at a low-effort tier) — to prove low-effort model compliance? What would still slip through?
5. Of the 12 open operator questions at the end, which are the highest-stakes, and what is your recommended answer for each?
6. What are the top risks in implementing this, and is anything in the requirements over-engineered for the actual failure mode (a low-effort model bailing on a clean report)?

EXPLICIT ASK: give me a recommendation — approve the requirements as-is, or the specific changes needed before this lands as plans/generalized-page-validity-lint.md. Note: the requirements were authored by an OpenAI-family model; your review is the independent Anthropic-family second opinion.

This is analysis only. Do NOT edit, create, or delete any files. Do NOT write code.
I'll start by reading the requirements draft and the implementation files it builds on.
I've read the draft and the code it relies on, and I'm writing the review now.

`★ Insight ─────────────────────────────────────`
- The bug that triggered this work was a **discovery** failure, not a repair failure. When pre-flight listed nothing, the low-effort model found nothing. Every time pre-flight listed a defect, the model acted on it. So the most useful fix is anything that moves work from "go find problems" to "confirm or reject this listed item."
- The code already has the parts needed to enforce limits without relying on the prompt: `swift-markdown` (the renderer's own parser, `Package.swift:31`), page history and revert, and the run-scoped capability design in `plans/agent-sandbox-scoping.md`. The draft uses none of them. It relies on prompt rules plus a scanner that only checks for a line starting with three backticks (`WikiLinkSpan.swift:141`).
`─────────────────────────────────────────────────`

# Review: Generalized Page Validity Lint Requirements

**Recommendation: don't approve as-is.** The draft is careful, and its separation of mechanical findings, judgment, and strategy is correct. But it treats the production failure mainly as a prompt-completeness problem. As written it will produce a large prompt that low-effort models answer with checklist claims, plus an expensive test matrix that can still pass a model that bails 20% of the time. The changes below come before it lands in `plans/`.

---

## 1. Is the taxonomy complete?

D01–D21 covers generic Markdown damage well. It is missing the defects that are specific to **LLM-written** pages, and those are the most common ones:

| Missing class | Why it matters here |
|---|---|
| **Footnote damage**: `[^id]` with no definition, a definition nobody references, duplicate IDs, or a definition that isn't a valid `[[source:…#"quote"]]` | Footnotes are the wiki's actual citation convention (`system-prompt-default.md` Footnotes section; `WikiFootnoteMarkdown` exists). D20 only mentions generic reference labels. This is the largest gap, and it is fully mechanical. |
| **Truncated output**: body ends mid-sentence, mid-table, or mid-list | This is the classic token-limit failure. D01 only covers the case where it happens inside a fence. |
| **Agent meta-text leaked into the body**: "Here's the updated page:", "I'll now…", wikictl output or CAS error text, scratch paths, tool transcripts | Not the same as D14 placeholders. It is easy to detect with a short phrase list and is very specific to LLM authors. |
| **Whole body wrapped in a ` ```markdown ` fence** | The most frequent D01 case in practice. It deserves its own fast-path detector. |
| **Escaping-layer damage**: literal `\n`, `\[\[`, over-escaped `\*`, double-encoded `&amp;amp;` | Comes from bodies passing through JSON or shell. D17 only covers character encoding. |
| **Regression against the previous head**: large shrinkage, or tables, citations, or sections dropped by a "reconcile" rewrite | This is probably the most damaging maintenance defect. `page history` already gives a free oracle. Report it at minimum. The draft uses history only as evidence for D17. |
| **Rich-fence validity** (e.g. mermaid) | Write-time validation lets a fence through with only a stderr notice when no package claims it (`PageCommand.swift:331-345`). Pages written before the validator existed were never checked. Lint should re-run it. |
| **Invisible or bidi characters inside link targets** | These make a link look fine but resolve as broken. D17's "controls" only partly covers this. |
| **Wrong page overwritten**: body is about a different title | Rare, but catastrophic. The combined multi-page dispatch (Q12) makes it more likely. |

## 2. Is the mechanical/judgment boundary in the right place?

The principle is right. In several places the line is drawn **too far toward judgment**, and the system relies on judgment from exactly the model tier that failed.

- **Detectors should use the renderer's AST (`swift-markdown`), not the code protector.** `protectedCodeRanges` doesn't handle tilde fences or fence length: a ```` ``` ```` line closes a ```` ```` ```` block in the protector but not in CommonMark. Any detector built on it inherits that drift. Parsing with swift-markdown gives tables, lists, headings, footnotes and fences with the same semantics as the reader, and settles open question 4. REQ-48 should be a **P0 prerequisite**, not a later consideration.
- **REQ-40 should allow *candidate repairs*, not just facts.** Several classes the draft calls judgment are deterministic when there is exactly one match:
  - D08: a display name or filename that resolves to exactly one SourceID.
  - D11: a raw URL that exactly matches an ingested source's origin URL. The store keeps source URLs (`WikiStore.swift:707`).
  - D15: conflict markers.
  - D01: a whole body wrapped in a fence.

  Pre-flight should emit "candidate: replace X with Y (unique match)". That changes the model's job from discovering to confirming or rejecting, which is the thing low-effort models do reliably. "Don't declare author intent" can stay; a proposal is not a declaration of intent.
- **D12, D13 and D16 (claim support, detached citations, contradictions) are on the wrong side of a missing prerequisite.** REQ-46 admits no read path for version inputs exists yet. Putting these in v1 means low-effort runs will either mark them `blocked` every time or pretend to do them. Move them to a separate evidence audit operation that runs on a higher tier.
- **D04 and D05 (lists, headings)** are correctly advisory. Expect them to be the main source of false rewrites. Consider keeping them report-only in v1.

## 3. Are the hard limits coherent and enforceable?

**Coherence: there is a live contradiction, and it may have *caused* the production failure.** The system prompt's Lint workflow says "don't rewrite existing page content" (`system-prompt-default.md:498-501`). The precedence section also says the task prompt "narrows the work; it never widens" it. A selected-page task that says "fix" is a widening. Read literally, page-level repair is forbidden, so a cautious or lazy model has a ready reason to conclude "needs no changes." REQ-19 notes the conflict, but it should be **blocking and first**: rewrite the system-prompt section so it scopes "don't rewrite" to whole-wiki lint and explicitly grants selected-page validity repair. The current task also says "create the page if it should exist" and "fix stale content, factual gaps" (`lint-page-task.md:14,20`). Both are editorial mandates that contradict REQ-05 and REQ-06 and should be removed in the same change.

**Enforceability: the prompt alone cannot do it, and most of these limits don't need to rely on it:**

| Limit | Mechanical enforcement available |
|---|---|
| REQ-06 no page creation, REQ-11 no index/strategy/other pages | A lint operation policy under the run-scoped capability design (`plans/agent-sandbox-scoping.md`): writes allowed only to the selected PageIDs, `--create-only` and `index set` denied. |
| REQ-15 CAS required | The same policy rejects blind upserts (writes with neither flag) from lint runs. |
| REQ-05/07/08 minimal, justified edits | **Add a patch-style write**, e.g. `wikictl page patch --expect-head H --hunk …` with a `--defect <class>` per hunk. Untouched regions are then preserved by construction, and each edit carries its reason. This is the biggest single lever in the whole design. Without it, every repair is a full-body rewrite by a low-effort model, and AC-08 will be fragile. |
| REQ-09 no invented evidence | Post-write check: every *newly added* `[[source:…]]` must resolve, and any new quote fragment must match the source text. |
| REQ-36 verification | The **app** re-runs pre-flight on the written head and records any remaining findings in the log and UI. The agent's own readback is not a verification gate. |

What stays prompt-only: editorial restraint inside a hunk, and the untrusted-content rule. Those are acceptable, given the scoped capability limits the damage.

**An existing violation the draft understates (REQ-39 / Q8):** the bracket auto-fix in `preflightLint` calls `PageUpsert.upsert` with no expected head and default `provenance: []` (`WikiStoreModel.swift:1850-1871`). That is a blind write racing with other writers. It also appears to write a head version without version inputs; please verify, because if so every lint auto-fix silently removes provenance from the head.

## 4. Are AC-07/AC-14 (three live runs per fixture) enough?

No.

- **Statistics.** If a configuration bails with per-run probability p, the chance it passes 3/3 is (1−p)³. At p = 0.2 that is 51%; at p = 0.1 it is 73%. Three runs only catch failure rates above about 50%. The production incident was one occurrence. To bound a ~10% bail rate you need about 20 or more runs. Run those on a **small, targeted fixture** (clean pre-flight with one hidden defect), not on all 15 groups.
- **All-or-nothing per fixture gives no diagnosis.** One mixed page with ~18 defect classes mostly tests long-context degradation. Score recall and precision per class instead.

What still slips through:

1. **Checklist theater.** A no-change report that names every completed check (REQ-30) is free to fake. Fix: pre-flight emits an inventory (N tables, M source citations, K URLs, F footnotes), the report must give a per-item outcome, and a harness checks the counts.
2. **Edits outside the protected list.** AC-08 checks only the protected content each fixture lists. The oracle should be "every diff hunk maps to a seeded defect; anything else fails."
3. **Provenance drift.** No AC checks that version inputs are kept across a lint write.
4. **Fixture overfitting.** Prompt tuning against the same fixtures. Keep a held-out set.
5. **Real page lengths.** Fixtures are short and production pages are long. Include at least one long page with the defect late in the body.
6. **Model updates under the same name.** Re-run the evaluation when the provider's model version changes, not only when the prompt changes.
7. **Scale of human review.** 15 groups × 3 runs × N configurations is too much to review by hand. Use deterministic expected output (an AST or normalized-byte comparison) for mechanical repairs, and keep human review for the judgment fixtures.

## 5. The highest-stakes open questions, with recommended answers

| # | Recommendation |
|---|---|
| **1 Repair permission** | Whole-wiki lint stays report-only. Selected-page lint gets validity repairs. Grant this explicitly in the system prompt **and** in the operation policy. This is the top-priority item; see §3. |
| **12 Multi-page** | **Run each selected page as its own run.** It's cheap, it removes REQ-28, a fixture group, and the wrong-page-write risk, and it fixes the current flattening in `AgentOperationRunner.swift:522-546`. |
| **4 Dialect** | The renderer's parser (swift-markdown plus wiki-link extensions) defines validity, and detectors use the same parser. |
| **2 Evidence access** | Defer. Remove D12, D13 and D16 from v1. Add a `page get --json` field listing version inputs later, as part of a separate evidence audit. |
| **7 New pages** | Prohibit creation, and enforce it in policy. A broken link becomes an "unresolved: target missing" finding, so a page gets created through ingest or query instead. |
| **8 Pre-flight writes** | Put them under CAS and preserve provenance now, as a bug fix. Longer term, turn them into candidate repairs the agent applies, so there is one write path. |
| **9 Evaluation tier** | The lowest tier actually used for lint in production. Scheduled and batch runs are the ones that bailed. Use ≥20 runs on the targeted bail fixture and 3 runs on the rest. |
| 6 Unrecoverable text | Leave it in place and report it as unresolved. Removal is an editorial decision. |
| 10 Active content | Rendering safety belongs to the renderer or sanitizer. Lint only reports. Remove "neutralize" from D18 repairs unless it is a removal clearly marked as accidental. |
| 3 / 5 / 11 | Lower stakes. No metadata contract means D19 is off. Citation density belongs to strategy. Structured log fields can wait for v2. |

## 6. Top risks, and what is over-engineered

**Risks:**
1. A prompt with 10 named audits and 9 worklist sections is enough to make a low-effort model narrate compliance instead of doing the work. A longer prompt does not mean more checking.
2. Full-body rewrites by weak models will damage untouched content. Without a patch primitive, this is the main source of regressions.
3. Detector drift from the renderer if the scanners keep relying on the protector heuristic.
4. False positives from D04, D05, D14 and D02 teaching the model to "fix" valid pages, which AC-10 is meant to prevent.
5. The prompt and the system prompt staying contradictory if REQ-19 slips.

**Over-engineered for the actual failure (a low-effort model bailing on a clean report):**
- D12, D13, D16 and their evidence plumbing (REQ-46/47) belong in a separate operation.
- The five-outcome taxonomy plus the 7-field log entry plus the 9-section ordering. Keep the outcomes, but collapse the reporting to a per-item list that a harness can check.
- REQ-28 and the multi-page fixture group become unnecessary once each page runs separately.
- 15 fixture groups × 3 runs × every configuration as the release gate. Use a smaller, statistically meaningful gate instead.

## Changes required before this lands as `plans/generalized-page-validity-lint.md`

1. **Phase 0, blocking:** resolve the system-prompt lint conflict. Remove "create the page" and "stale content / factual gaps" from `lint-page-task.md`. Make the bracket auto-fix use CAS and preserve provenance.
2. Add the missing classes: footnotes, truncation, meta-text leakage, a whole-body fence, escaping damage, regression against the previous head, and rich-fence re-validation.
3. Make swift-markdown AST detectors a P0 prerequisite, and let REQ-40 emit unique-match candidate repairs.
4. Move D12, D13 and D16 out of v1, into a separate evidence audit.
5. Add mechanical enforcement requirements: a lint operation policy (selected pages only, no create or index writes, CAS required), a patch-style write with a defect class per hunk, and a post-write pre-flight re-run done by the app.
6. Replace the no-change contract with inventory counts and per-item outcomes that a harness can check.
7. Rework the acceptance criteria: ≥20 runs on the targeted bail fixture, recall and precision per class, a "no unattributed hunks" diff oracle, a check that provenance is kept, held-out fixtures, a long-page fixture, and re-evaluation when the model version changes.
8. Run each selected page separately (answer to Q12) and drop REQ-28.

`★ Insight ─────────────────────────────────────`
- The pattern behind most of these changes: each prompt-only rule should have an enforcer in code (operation policy, patch hunks, post-write re-scan), so the prompt only covers judgment calls.
- "Three runs at a low-effort tier" sounds strict, but it's a weak statistical gate. When the incident being fixed is intermittent, the evaluation needs many runs on the case that triggers it, not a few runs across many cases.
`─────────────────────────────────────────────────`
[User] # DESIGN REVIEW REQUEST — page-validity lint rollout gate vs. zero-ceremony end users

You reviewed the page-validity lint requirements earlier. Since then the feature is fully implemented (28 defect classes, exact patch write under CAS, per-page coordinator with coverage/verification/accounting, daemon receipts) and an independent implementation review is dispositioned. One design decision is now open, and your earlier framing applies directly: **the operator has set a new product requirement — a non-technical user must be able to run lint and have things fixed with NO evaluation run, NO custom configuration, and NO approval ceremony.** We need you to review the gate design against that requirement and recommend the correct shape.

## Current gate design (implemented)

- Every lint run consults an acceptance gate before authorizing repairs. The
  key = SHA-256 over provider + model + revision + effort + lint-prompt hash
  + detector revision + shipped fixture digests. A record must exist at
  `App Group/lint-acceptance/<key>.json`, written host-side only after a
  live evaluation (20/20 bail trials, fixture groups, diff-oracle checks)
  AND human rubric approval. No record → report-only (detect + report,
  never patch). Unresolved gate components hard-fail to report-only before
  lookup. The record is per-machine (local App Group), never checked in,
  never agent-writable.
- An evaluation harness (`WikiLintEvalRunner`) exists dev-side: disposable
  wikis, seeded fixtures, diff oracle, per-class scoring. `run --live`
  spends real provider tokens and is operator-initiated.

## The tension

- The current design means every END USER of the app must either run an
  eval themselves (non-starter: they are non-technical) or get
  report-only forever. That defeats the product purpose: lint should fix
  pages.
- The eval harness is dev-side (in-repo SwiftPM target + script), NOT part
  of the app. The plan's AC.13/AC.14 assumed the operator IS the evaluator.
  With the new requirement, that assumption is wrong: end users never run
  it, so the gate as built can never authorize repairs for them.

## Proposed direction (please critique)

Move the ACCEPTANCE into the shipped app, not the user's machine:

- The developer runs the eval harness against the production provider
  configuration before each app release that changes the lint pipeline
  (prompt, detectors, fixtures). The gate report + rubric sign-off are
  reviewed operator-side, then the approval is COMMITTED: a versioned
  `lint-acceptance/<key>.json` in the repo (or shipped app resource),
  keyed to the full configuration, carrying the rubric metadata and
  fixture digests.
- The app ships with that approval. At lint time the coordinator computes
  the runtime configuration key and checks it against the SHIPPED
  approvals: match → repair lease; no match → report-only with reason.
- The eval harness remains purely dev-side: it is how the EVIDENCE for the
  next approval is produced, not a user step. Users update the app; new
  releases carry freshly-gated approvals.
- Revocation = a release without the approval (or its removal).

## Questions to answer

1. Does shipping operator-approved acceptance with the app satisfy the
   safety intent (AC.13's evidence + rubric) while giving end users
   zero-ceremony repair? What is LOST by decoupling the gate from
   per-user evaluation?
2. The key currently includes provider/model/effort — but end users
   configure their OWN providers in Settings (claude/codex/...). Options:
   (a) approval covers only the app default provider path; custom
   provider = report-only; (b) approval covers a supported-provider
   matrix evaluated at release; (c) drop provider/model from the key and
   pin only prompt+detector+fixtures (approval = "this pipeline shape is
   trusted with any configured model"). Which is right for a
   non-technical user base, and what are the real risks of (c)?
3. Does per-configuration re-gating (AC.14) survive in a useful form, or
   should re-gating be tied to APP RELEASES (approval ships with the
   release; a release that changes prompt/detector/fixtures requires a
   new approval before it ships)? What would you change in AC.14's
   wording?
4. Threat model check: end users own their wiki and their provider keys.
   If a user edits the shipped approval resource to self-authorize
   repairs, is that actually a harm (they are authorizing repairs to
   their own pages with their own model)? Does the answer change what
   needs protecting (the APPROVAL itself vs. the BOUNDARY against repair
   leaking to non-lint operations)?
5. Anything in the implemented enforcement (receipts, page pinning,
   coverage validation, verification compare, host audit log) that
   should change if repairs are on-by-default for shipped approvals?

## Constraints that remain fixed

- Exact patch write under CAS with receipts; no full-body rewrites.
- Report-only classes stay report-only (D02/D04/D05/D14/D18/D28).
- Coverage validation and host-side verification cannot be skipped.
- The lint child is sandboxed; it can never write acceptance records.

## Deliverable

A recommended design: what the gate checks, what ships in the app, what
the eval is for after this change, what AC.14 becomes, and any risks you
would flag before we implement. Be concrete — component lists, file
locations, and the exact fallback rule.
I'll look at how the gate is implemented before answering.
I read the implemented gate: `LintAcceptanceGate.swift`, `LintCoordinatorGate.swift`, and the call site in `AgentOperationRunner.swift`.

`★ Insight ─────────────────────────────────────`
- The production call site passes hard-coded values: `provider: "unconfigured", model: "unconfigured", modelRevision: nil, effort: "unconfigured"` (`AgentOperationRunner.swift:584-586`). So the gate always returns report-only today, whatever records exist. Before any shipped approval can match, the host has to resolve the real configuration. That is the first implementation task in the new design.
- The approval only ever made a probabilistic claim about model quality. The actual safety comes from the enforcement layer: exact patch, CAS, coverage checks, host verification, report-only classes. Moving the approval into the app is safe because that layer doesn't move.
`─────────────────────────────────────────────────`

# Recommendation: ship the approval with the app; let local state only reduce authority

**Your proposed direction is right. Approve it with five changes:**
1. Grants come only from a manifest inside the signed app bundle. Nothing in the App Group directory can grant repairs.
2. The runtime match key covers what changes behavior at runtime. Fixture digests become CI-checked evidence.
3. The model part of the key becomes a supported-configuration matrix, with no exact model revision required.
4. Add a local circuit breaker and one-click undo to replace per-user evaluation.
5. Add a CI release check so an approval can never ship stale or silently go missing.

## 1. Does a shipped approval meet AC.13's intent?

**Yes.** AC.13 asks whether this pipeline with this model shows low bail rates and preserves content on the fixtures, with a human signing off. That is a property of the pipeline and the model, not of the user's machine. A per-user eval would run the same fixtures against the same model and learn nothing new, just at the user's expense.

**What's lost by dropping per-user evaluation, and what covers each gap:**

| Lost | Mitigation |
|---|---|
| **Model drift after release** (an alias like `sonnet` changes underneath) | Local circuit breaker (§5), periodic re-evaluation between releases, optional revocation list (§3) |
| **The user's pages differ from the fixtures** (languages, very long pages, unusual layouts) | Add fixtures with a non-default strategy, a non-English page, and a long page. The breaker catches the rest. |
| **The user's strategy text is in the prompt, but the key only hashes the template** | Accept it. Application rules take precedence over strategy, and strategy can't widen what the patch contract allows. Include one deliberately "aggressive" strategy fixture in the evaluation. |
| **Honest per-machine evidence** | Never existed for end users. AC.13 assumed the operator was the evaluator. |

## 2. Provider and model in the key: choose (b), not (c)

**Recommendation: (b), a supported-configuration matrix evaluated at each release, where the app's default configuration must always be in the matrix.** Option (a) is just (b) with one row, so start there if evaluation budget is tight. Configurations outside the matrix get report-only, with a plain-language reason.

Two changes to the key:
- **The model part should be a tuple of (agent runtime, model selector, effort).** The runtime is Claude Code, letta-code, or codex. It changes tool-calling behavior as much as the model does, which matters given the planned letta-code swap. Use the selector the user actually configured (for example the alias `sonnet`), not a resolved revision.
- **Remove `modelRevision` from the match.** Most runtimes don't report it, and the current code treats `nil` as report-only (`LintCoordinatorGate.swift:54`). Required as written, it would keep the default path in report-only forever. Record the revision the evaluation saw as evidence, and log the revision seen at runtime when it's available. Drift is handled by the breaker.

**Real risks of (c), trusting any configured model with the pipeline:**
- Bailing is the *harmless* failure. The dangerous one is a **plausible but wrong repair** that still passes structural checks: a real SourceID that's the wrong source, a table cell shifted into the wrong column, a raw URL replaced with a page that only looks equivalent. Host verification checks that defects weren't reintroduced; it does not check that the meaning is right. How often this happens depends heavily on the model, and small local models are the worst case.
- Under (c), the evaluation's evidence says nothing about the model actually running. The approval becomes a label with nothing behind it.

**Optional second phase, worth considering for unlisted models:** a *verifiable-only* tier. For classes where pre-flight emitted a **unique host-computed candidate** (wrapped-body fence, unique canonical SourceID, exact origin-URL match, missing table separator), the host accepts a hunk only if it **byte-equals the candidate**. Correctness then doesn't depend on the model, so no model approval is needed. Unlisted models would get those fixes and report-only for everything else. In v1, unlisted means report-only.

## 3. AC.14: tie re-gating to releases

Per-machine re-gating can't work for end users. Re-gating should happen at release time.

**Proposed AC.14 wording:**

> **AC.14.** A release build shall carry repair authority only for configurations listed in its shipped acceptance manifest. Each listed configuration shall have an acceptance record produced against that release candidate's pipeline components: the lint-task prompt, detector revision, repair-class authority table, patch and verification contract versions, and the gate fixture set. Any change to a pipeline component invalidates every listed approval. The release shall not ship repair authority until fresh records exist and the operator has signed off on the rubric. Model changes detected after release do not re-gate automatically. The local circuit breaker covers them, and they are re-evaluated before the next release or in a scheduled drift run. A failed drift run shall produce a release, or a revocation entry, that removes the affected approval.

**CI enforcement**, as a release-build test:
- Every approval's `pipeline` block must equal the components computed from the build. If not, the build fails; it must not silently ship report-only.
- The default configuration must have an approval, unless the manifest sets an explicit `defaultReportOnly: true` with a reason.
- The evidence's fixture digest must match the fixture set in the repo.

**Revocation:** a release is slow. If you want faster removal, add a **deny-only** list to the existing update feed (the appcast). It can revoke approvals and can never grant them. This is optional; flag it as a decision for the operator.

## 4. Threat model

**A user editing the approval to authorize repairs on their own machine is not a harm worth defending against.** It's their wiki, their key, their pages, and every change can be undone. Editing a bundle resource also breaks the code signature, so the bundle location keeps honest users honest, which is enough.

**What does need protecting is the boundary, against injected instructions, not against the user.** The realistic attacker is untrusted page or source content steering an agent. That means:
1. **Only the host derives the gate inputs.** Runtime, model, and effort come from the host's own run configuration and never from anything the child reports, its environment, or its arguments.
2. **Grants come only from the signed bundle.** This is a *security improvement* over today. The App Group directory can be written by any process running as the same user, including an **unsandboxed** agent child (`plans/agent-sandbox-scoping.md` says unsandboxed children are same-user). Today, a prompt-injected chat agent could drop a file at `lint-acceptance/<key>.json` and grant repairs. The M8 hardening argued that a key anyone can compute is dangerous. With shipped approvals, keys are public by design, so safety can't depend on keeping them secret. It has to depend on where grants are allowed to come from.
3. **The lease stays tightly scoped.** Selected-page lint only, pinned page IDs, patch-only, report-only classes enforced on the host, no leakage into ingest, query, chat, or whole-wiki lint.

**Rule: local state can only ever reduce authority.** App Group files may hold breaker state and user opt-outs. A forged file there can only *demote* a configuration to report-only.

## 5. Changes to enforcement once repairs are on by default

| Component | Change |
|---|---|
| **Undo** | Make it the user's main safety net. Show "N fixes applied" with **Undo lint fixes**, which reverts to the inspected head using CAS against the written head (page history and revert already exist). Without this, on-by-default isn't acceptable for non-technical users. |
| **Local circuit breaker** (new, host-side, App Group) | Per pipeline and configuration. It trips to report-only on either of: (a) ≥2 host verification failures in the last 10 repair runs, or (b) ≥2 user undos of lint fixes in the last 10. Show a plain message. It resets when the app updates to a new pipeline. This replaces per-user evaluation. |
| **Verification failure** | If verification finds reintroduced or new defects, the host **automatically reverts** using CAS on the written head, or marks the page visibly if the head has moved. Don't leave a bad write in place silently. Check what the current code does. |
| **Patch budget** | Cap hunks and changed bytes per run, relative to the number of findings. Over the cap, reject the whole patch and fall back to report-only for that run. |
| **Receipts and host audit log** | Add `approvalID` (release version, manifest key, matrix row) and `authorityTier` to every receipt, so any bad repair can be traced to the approval that allowed it. |
| **Sandbox precondition** | If the lint child isn't sandboxed, report-only. On-by-default must not extend to the unsandboxed fallback. |
| **Module boundary** | `WikiFSEngine` imports `WikiLintEval` (`LintCoordinatorGate.swift:3`), which links the evaluation harness into the app. Replace that with a build-generated constant in WikiFSCore, the way `GeneratedPrompts` works, and keep `WikiLintEval` dev-only. |
| **Whole-wiki lint** | Stays report-only, but offers **"Fix N pages"**, which queues gated per-page runs. One click counts as zero ceremony. |

---

## Recommended design

### What ships
- `Sources/WikiFSCore/Resources/LintAcceptance/manifest.json`, inside the signed bundle:
  ```json
  {
    "schema": 2,
    "pipeline": {
      "promptSHA256": "…", "detectorRevision": "…",
      "repairClassTableSHA256": "…", "patchContract": 1, "verificationContract": 1
    },
    "evidence": { "fixtureDigest": "…", "reportSHA256": "…", "rubricReviewer": "…", "decidedAt": "…" },
    "approvals": [
      { "id": "2026.11-claude-sonnet-low", "runtime": "claude-code", "model": "sonnet",
        "effort": "low", "evaluatedRevision": "…", "bailTrials": "20/20", "authority": "full" }
    ],
    "defaultReportOnly": false
  }
  ```
- A generated `LintPipelineComponents` constant in WikiFSCore, so the runtime doesn't depend on WikiLintEval.
- `LintAcceptanceGate.production()` reads **only** the bundle manifest. A dev override directory is allowed under `#if DEBUG` only, for the harness and local testing.

### Gate check and exact fallback rule
In order. The first failing step selects **report-only, with a plain-language reason**:
1. The operation is selected-page lint. Otherwise report-only.
2. The lint child is sandboxed and the patch write path is available.
3. The build's computed pipeline components equal `manifest.pipeline`.
4. The host resolves (runtime, model selector, effort) from its own run configuration. If any part is unresolved, report-only.
5. That tuple matches an `approvals` row. If not: report-only in v1 (verifiable-only in phase 2), with a reason like *"Automatic fixes are available with Claude Sonnet. Your current model can find problems but not fix them."*
6. The local breaker for (pipeline, tuple) hasn't tripped, and the tuple isn't on the deny list.
7. The host mints the repair lease and stamps `approvalID` into the receipt.

### What the evaluation is for after this change
- **Release gate:** it produces the evidence and a candidate manifest for each matrix row. The operator's rubric sign-off happens in the PR that commits the manifest; reviewing that PR *is* the developer-side approval step.
- **Drift check:** a scheduled re-run against the current release's matrix. A failure produces a hotfix release or a deny-list entry.
- It never runs on an end user's machine.

### Risks to flag before implementing
1. **Host-side resolution doesn't exist yet.** The call site hard-codes "unconfigured". Wiring the real (runtime, model, effort) is a prerequisite, and it must come from host configuration, never from the child.
2. **Model drift between releases** is the main remaining exposure. The breaker, drift runs, and the deny list cover it partially, not fully. Say so in the plan's Honest limits section.
3. **Evaluation cost grows with the matrix size** (20 bail trials plus fixture groups per row, per release). Keep the matrix small, with the default configuration plus one or two rows.
4. **UX:** report-only reasons must be actionable for a non-technical user. No hashes or key components in user-facing text.
5. **On-by-default without one-click undo is a no-go.** Ship undo in the same release that turns repairs on.

`★ Insight ─────────────────────────────────────`
- "Grants only from signed code, reductions from
[User] # DESIGN REVIEW REQUEST — page-validity lint rollout gate vs. zero-ceremony end users

You reviewed the page-validity lint requirements earlier. Since then the feature is fully implemented (28 defect classes, exact patch write under CAS, per-page coordinator with coverage/verification/accounting, daemon receipts) and an independent implementation review is dispositioned. One design decision is now open, and your earlier framing applies directly: **the operator has set a new product requirement — a non-technical user must be able to run lint and have things fixed with NO evaluation run, NO custom configuration, and NO approval ceremony.** We need you to review the gate design against that requirement and recommend the correct shape.

## Current gate design (implemented)

- Every lint run consults an acceptance gate before authorizing repairs. The
  key = SHA-256 over provider + model + revision + effort + lint-prompt hash
  + detector revision + shipped fixture digests. A record must exist at
  `App Group/lint-acceptance/<key>.json`, written host-side only after a
  live evaluation (20/20 bail trials, fixture groups, diff-oracle checks)
  AND human rubric approval. No record → report-only (detect + report,
  never patch). Unresolved gate components hard-fail to report-only before
  lookup. The record is per-machine (local App Group), never checked in,
  never agent-writable.
- An evaluation harness (`WikiLintEvalRunner`) exists dev-side: disposable
  wikis, seeded fixtures, diff oracle, per-class scoring. `run --live`
  spends real provider tokens and is operator-initiated.

## The tension

- The current design means every END USER of the app must either run an
  eval themselves (non-starter: they are non-technical) or get
  report-only forever. That defeats the product purpose: lint should fix
  pages.
- The eval harness is dev-side (in-repo SwiftPM target + script), NOT part
  of the app. The plan's AC.13/AC.14 assumed the operator IS the evaluator.
  With the new requirement, that assumption is wrong: end users never run
  it, so the gate as built can never authorize repairs for them.

## Proposed direction (please critique)

Move the ACCEPTANCE into the shipped app, not the user's machine:

- The developer runs the eval harness against the production provider
  configuration before each app release that changes the lint pipeline
  (prompt, detectors, fixtures). The gate report + rubric sign-off are
  reviewed operator-side, then the approval is COMMITTED: a versioned
  `lint-acceptance/<key>.json` in the repo (or shipped app resource),
  keyed to the full configuration, carrying the rubric metadata and
  fixture digests.
- The app ships with that approval. At lint time the coordinator computes
  the runtime configuration key and checks it against the SHIPPED
  approvals: match → repair lease; no match → report-only with reason.
- The eval harness remains purely dev-side: it is how the EVIDENCE for the
  next approval is produced, not a user step. Users update the app; new
  releases carry freshly-gated approvals.
- Revocation = a release without the approval (or its removal).

## Questions to answer

1. Does shipping operator-approved acceptance with the app satisfy the
   safety intent (AC.13's evidence + rubric) while giving end users
   zero-ceremony repair? What is LOST by decoupling the gate from
   per-user evaluation?
2. The key currently includes provider/model/effort — but end users
   configure their OWN providers in Settings (claude/codex/...). Options:
   (a) approval covers only the app default provider path; custom
   provider = report-only; (b) approval covers a supported-provider
   matrix evaluated at release; (c) drop provider/model from the key and
   pin only prompt+detector+fixtures (approval = "this pipeline shape is
   trusted with any configured model"). Which is right for a
   non-technical user base, and what are the real risks of (c)?
3. Does per-configuration re-gating (AC.14) survive in a useful form, or
   should re-gating be tied to APP RELEASES (approval ships with the
   release; a release that changes prompt/detector/fixtures requires a
   new approval before it ships)? What would you change in AC.14's
   wording?
4. Threat model check: end users own their wiki and their provider keys.
   If a user edits the shipped approval resource to self-authorize
   repairs, is that actually a harm (they are authorizing repairs to
   their own pages with their own model)? Does the answer change what
   needs protecting (the APPROVAL itself vs. the BOUNDARY against repair
   leaking to non-lint operations)?
5. Anything in the implemented enforcement (receipts, page pinning,
   coverage validation, verification compare, host audit log) that
   should change if repairs are on-by-default for shipped approvals?

## Constraints that remain fixed

- Exact patch write under CAS with receipts; no full-body rewrites.
- Report-only classes stay report-only (D02/D04/D05/D14/D18/D28).
- Coverage validation and host-side verification cannot be skipped.
- The lint child is sandboxed; it can never write acceptance records.

## Deliverable

A recommended design: what the gate checks, what ships in the app, what
the eval is for after this change, what AC.14 becomes, and any risks you
would flag before we implement. Be concrete — component lists, file
locations, and the exact fallback rule.
This is the complete review. It replaces my earlier reply, which was cut off at the end. The findings rest on code I already read: `LintAcceptanceGate.swift`, `LintCoordinatorGate.swift`, and `AgentOperationRunner.swift:575-600`.

`★ Insight ─────────────────────────────────────`
- **The gate can't authorize repairs today no matter what records exist.** The production call site passes `provider: "unconfigured", model: "unconfigured", modelRevision: nil, effort: "unconfigured"` (`AgentOperationRunner.swift:584-586`). Even with a perfect approval record, the host has to resolve the real configuration first.
- **The approval was only ever a statistical claim about model quality.** The actual safety comes from the fixed constraints: exact patch, CAS, coverage checks, host verification, and report-only classes. Moving the approval into the app is safe because none of those move.
`─────────────────────────────────────────────────`

# Recommendation: approve your direction, with five changes

Your direction (developers run the evaluation, approvals ship with the app, users get zero ceremony) is right. Make these five changes:

1. **Only the signed app bundle can grant repairs.** The App Group directory can no longer grant anything.
2. **The runtime key covers only what changes runtime behavior.** Fixture digests become evidence that CI checks, not part of the key.
3. **Use a supported-configuration matrix, without exact model revisions.** Each matrix entry is a model tuple: agent runtime, model selector, and effort.
4. **Add a local circuit breaker and one-click undo.** Together they replace per-user evaluation.
5. **Add a CI release check.** It stops an approval from shipping stale or quietly going missing.

## 1. Does a shipped approval meet AC.13's intent?

**Yes.** AC.13 asks whether this pipeline with this model has a low bail rate and preserves content, with a human signing off. That is a property of the pipeline and the model, not of the user's machine. A per-user evaluation would run the same fixtures against the same model, so it adds no evidence and costs the user tokens.

**What decoupling loses, and what covers each gap:**

| Lost | Mitigation |
|---|---|
| **Model drift after release.** An alias like `sonnet` changes underneath the approval. | Local circuit breaker, scheduled drift runs, and an optional deny list (§3). |
| **Real pages differ from fixtures.** Other languages, long pages, odd layouts. | Add fixtures for a non-English page, a long page with a late defect, and a non-default strategy. The breaker catches the rest. |
| **Strategy text is in the prompt, but only the template is hashed.** | Accept it. Application rules take precedence over strategy, and strategy can't widen the patch contract. Add one fixture with a deliberately aggressive strategy. |
| **Per-machine evidence** | End users never had it. AC.13 assumed the operator was the evaluator. |

## 2. Provider and model in the key: choose (b)

**Choose (b): a supported-configuration matrix evaluated at release.** The app's default configuration must always be in it. Option (a) is just (b) with one row, so start there if the evaluation budget is tight. Any configuration outside the matrix gets report-only, with a plain-language reason.

Two changes to the key:

- **Use a model tuple: (agent runtime, model selector, effort).**
  - The agent runtime is Claude Code, letta-code, or codex. It changes tool-calling behavior as much as the model does. That matters because of the planned letta-code swap.
  - The selector is what the user configured, such as the alias `sonnet`.
- **Take `modelRevision` out of the match.** Most runtimes don't report a revision, and the current code turns `nil` into report-only (`LintCoordinatorGate.swift:54`). Keeping it required would leave the default path report-only forever.
  - Store the revision the evaluation saw as evidence.
  - Log the runtime revision when one is available.
  - Let the breaker handle drift.

**Why not (c):**

- **Bailing is the harmless failure.** The dangerous one is a repair that looks right and passes structural checks but is wrong. Examples: a real SourceID that points to the wrong source, a table cell in the wrong column, or a URL replaced with a page that only looks equivalent.
- **Host verification checks structure, not meaning.** The rate of wrong-but-plausible repairs depends heavily on the model, and small local models are the worst case.
- **Under (c), the evidence says nothing about the model actually running.** The approval becomes a label.

**Phase 2 option for unlisted models: a "verifiable-only" tier.** Some classes have a unique candidate computed by the host:

- a whole-body fence wrap
- a unique canonical SourceID
- an exact origin-URL match
- a missing table separator

For these, the host accepts a hunk only if it byte-equals the candidate. Correctness then doesn't depend on the model, so no model approval is needed. In v1, unlisted configurations get report-only.

## 3. AC.14: re-gate per release

**Proposed wording:**

> **AC.14.** A release build carries repair authority only for configurations listed in its shipped acceptance manifest.
>
> Each listed configuration requires a record produced against that release candidate's pipeline components:
> - the lint-task prompt
> - the detector revision
> - the repair-class authority table
> - the patch-contract version and the verification-contract version
> - the gate fixture set
>
> Changing any pipeline component invalidates every listed approval. The release shall not ship repair authority until fresh records exist and the operator has signed off the rubric.
>
> Model changes after release do not re-gate automatically. The local circuit breaker covers them until they are re-evaluated before the next release or in a scheduled drift run. A failed drift run shall produce a release or a deny-list entry that removes the affected approval.

**CI enforcement (a release-build test):**

- **Pipeline match.** Every approval's `pipeline` block must equal the components computed from the build. A mismatch fails the build. It must not silently ship report-only.
- **Default coverage.** The default configuration must have an approval, unless the manifest sets `defaultReportOnly: true` with a reason.
- **Fixture match.** The evidence's fixture digest must equal the digest of the fixture set in the repo.

**Revocation.** A new release is slow. The faster option is a deny-only list delivered through the existing update feed (the appcast). It can revoke approvals and can never grant them. This is optional and is a decision for the operator.

## 4. Threat model

**A user editing the approval on their own machine is not a harm worth defending against.** They own the wiki, the provider key, and the pages, and every change can be undone. Editing a bundle resource also breaks the code signature, which is enough to discourage it.

**What needs protecting is the boundary, against prompt injection, not against the user.** The realistic attacker is untrusted page or source content steering an agent. Three things follow:

1. **Only the host derives gate inputs.** Runtime, model, and effort come from the host's own run configuration. Nothing the child reports, nor its environment or arguments, feeds the gate.
2. **Only the signed bundle can grant repairs. This is better than today.**
   - The App Group directory is writable by any process running as the same user. That includes an unsandboxed agent child (`plans/agent-sandbox-scoping.md`).
   - So today, a prompt-injected chat agent could write `lint-acceptance/<key>.json` and grant itself lint repairs.
   - The M8 hardening worried about keys anyone can compute. With shipped approvals the keys are public by design, so safety has to come from where grants are allowed to come from, not from secret keys.
3. **The lease stays narrow.** It covers selected-page lint only, pinned page IDs, and patch-only writes, with report-only classes enforced by the host. Repair authority never reaches ingest, query, chat, or whole-wiki lint.

**Rule: local state can only reduce authority.** App Group files may hold breaker state and user opt-outs. A forged file there can only demote a configuration.

## 5. Enforcement changes for on-by-default repairs

| Component | Change |
|---|---|
| **Undo** (new, required) | Show "N fixes applied" with **Undo lint fixes**. Undo reverts to the inspected head with CAS against the written head, using the existing page history and revert. Without one-click undo, on-by-default is not acceptable for non-technical users. |
| **Local circuit breaker** (new, host-side, stored in App Group) | Tracked per pipeline and model tuple. It trips to report-only on ≥2 host verification failures in the last 10 repair runs, or ≥2 user undos in the last 10. Show a plain message when it trips. It resets when an app update brings a new pipeline. |
| **Verification failure** | If verification finds a reintroduced or new defect, the host automatically reverts with CAS on the written head. If the head has moved since, it flags the page visibly instead. Never leave a bad write in place silently. Check what the current code does here. |
| **Patch budget** | Cap the number of hunks and changed bytes per run, relative to the finding count. Above the cap, reject the whole patch and treat that run as report-only. |
| **Receipts and host audit log** | Add `approvalID` (release, manifest key, matrix row) and `authorityTier` to every receipt, so any bad repair traces back to the approval that allowed it. |
| **Sandbox precondition** | An unsandboxed lint child gets report-only. On-by-default never extends to the unsandboxed fallback. |
| **Module boundary** | `WikiFSEngine` imports `WikiLintEval` (`LintCoordinatorGate.swift:3`), so the evaluation harness is linked into the app. Replace that with a build-generated constant in WikiFSCore, the same way `GeneratedPrompts` works. `WikiLintEval` stays dev-only. |
| **Whole-wiki lint** | Stays report-only, but offers **"Fix N pages"**, which queues gated per-page runs. A single click counts as zero ceremony. |

---

## Recommended design

### What ships

- **`Sources/WikiFSCore/Resources/LintAcceptance/manifest.json`**, inside the signed bundle:
  ```json
  {
    "schema": 2,
    "pipeline": {
      "promptSHA256": "…", "detectorRevision": "…",
      "repairClassTableSHA256": "…", "patchContract": 1, "verificationContract": 1
    },
    "evidence": {
      "fixtureDigest": "…", "reportSHA256": "…",
      "rubricReviewer": "…", "decidedAt": "…"
    },
    "approvals": [
      { "id": "2026.11-claude-code-sonnet-low", "runtime": "claude-code",
        "model": "sonnet", "effort": "low", "evaluatedRevision": "…",
        "bailTrials": "20/20", "authority": "full" }
    ],
    "defaultReportOnly": false
  }
  ```
- **A generated `LintPipelineComponents` constant in WikiFSCore.** This is the build's own pipeline block, used for runtime comparison and the CI check.
- **`LintAcceptanceGate.production()` reads only the bundle manifest.** A dev override directory exists under `#if DEBUG` only, for the harness and local testing.
- **New: `LintRepairBreaker`.** It lives in WikiFSEngine and stores its state at `App Group/lint-breaker/<pipeline>-<tuple>.json`. It can only demote.

### Gate check and exact fallback rule

Run these checks in order. The first one that fails selects **report-only, with a plain-language reason**.

1. The operation is selected-page lint.
2. The lint child is sandboxed, and the patch write path is available.
3. The build's `LintPipelineComponents` equal `manifest.pipeline`.
4. The host resolves (runtime, model selector, effort) from its own run configuration. If any part is unresolved, select report-only.
5. The tuple matches an `approvals` row. If not, select report-only in v1 (verifiable-only in phase 2). The user sees a message like: *"Automatic fixes are available with Claude Sonnet. Your current model can find problems but not fix them."*
6. The breaker for (pipeline, tuple) has not tripped, and the approval is not on the deny list.

If all six pass, the host mints the repair lease and stamps `approvalID` into the receipt.

### What the evaluation is for after this change

- **Release gate.** `WikiLintEvalRunner run --live` produces the evidence and a candidate manifest row for each matrix entry. The operator signs off the rubric in the PR that commits `manifest.json`. That PR review is the developer-side approval step.
- **Drift check.** A scheduled re-run against the current release's matrix. A failure produces a hotfix release or a deny-list entry.
- **Never on end-user machines.**

### Risks to flag before implementing

1. **Host-side resolution doesn't exist yet.** The call site hard-codes "unconfigured". Wiring the real (runtime, model, effort) from host configuration, never from the child, comes first.
2. **Model drift between releases is the main remaining exposure.** The breaker, drift runs, and deny list reduce it but don't eliminate it. Record this in the plan's Honest limits section, replacing the current line about "operator-attested gate".
3. **Evaluation cost grows with the matrix.** Each row needs 20 bail trials plus the fixture groups on every release. Keep the matrix to the default plus one or two rows.
4. **User-facing reasons must be actionable.** No hashes or key components in anything a user sees.
5. **No undo, no on-by-default.** One-click undo ships in the same release that turns repairs on.
6. **Retire the App Group record directory as a grant source.** Leave it unread in release builds. Don't keep it as a fallback, because that reopens the self-grant path described in §4.

`★ Insight ─────────────────────────────────────`
- **"Signed code grants, local state only takes away"** is a general pattern for client-side authorization. You stop needing to defend local files, because the worst a forged file can do is make the app more conservative.
- **The breaker and undo together replace per-user evaluation.** You stop trying to predict whether this model will behave on this machine, and instead detect quickly when it doesn't and limit the damage. For an app whose users won't run evaluations, that is the right trade.
`─────────────────────────────────────────────────`
