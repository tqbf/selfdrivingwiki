# Generalized page-validity lint — implementation

Status: **phases 0–5 complete and committed; phase 6 deterministic core complete;
phase 7 (this document, contract cross-references, independent review) in
progress.** Requirements live in
[`generalized-page-validity-lint.md`](generalized-page-validity-lint.md); this
document records HOW they were implemented and where each piece lives.
Branch: `feature/generalized-page-validity-lint`.

## What landed (committed, full suite green after each)

| Commit | Phase | Contents |
|---|---|---|
| `ca7de2f2` | 0 | System-prompt lint removal; self-contained `lint-page-task.md`; coherent `PageCoherentRead`; bracket fix under CAS with honest reporting |
| `117c9be4` | 1 | Shared parser foundation (`ParsedMarkdownDocument`, AST code protection, `MarkdownFenceFacts`, footnote analysis); typed lint records; pure `LintPagePreflight` with inventory + first detectors |
| `b5e6c036` | 2 | `ManagedRunPolicy` (ordinary / selected-page repair / selected-page report-only / whole-wiki report-only) through lease→broker→registry→grant; lint allowlist (reads + kind-conditioned log append only); `DaemonLintRunState` CAS budget |
| `3fdc97be` | 3 | `wikictl page patch` (strict `--hunk`/`--defect` alternation, `--hunk-file`), atomic `WikiStore.patchPage` in exact-body mode, provenance union, citation/quote integrity, daemon wire, event semantics |
| `ebd81230`/`d43555f0`/… | notes | Progress notes per stretch |
| `de0e7437` | 4 | **Complete v1 detector coverage** (D01–D28 in-scope): fence closures, delimiter parity, table shapes (source-counted rows), indent jumps + accidental indented code, heading jumps/duplicates, placeholders, merge markers + 80-char duplicates, encoding, active content, reference labels + scheme-less media, truncation, meta-text, double entities/bidi, history regression vs the ACTUAL parent (30% shrinkage), rich-fence re-validation. Injected facts (`LintCitationFacts`, `LintOriginURLFacts`, `LintHistoryFacts`, `LintFenceValidationFacts`) keep the scan pure; missing facts record honest limits. Async `detailedFenceValidation` on `FenceSyntaxValidationService` (validated/invalid/unclaimed/suppressed/unavailable). Detector revision `lint-preflight-v2`. |
| `ddfe43f6` | 5a | REQ-29 ten-check model, fixed run-report format + strict parser, REQ-31/32 coverage validator, REQ-54 `LintVerification.compare` |
| `5bd10c7e` | 5b | Typed identity + staged `LINT_PREFLIGHT.md`/`LINT_RUN_REPORT.md` artifacts; shared per-page plan builder; sequential per-page dispatch (app UI, app queue, daemon queue); observed per-page queue outcomes |
| `17105b0b`/`e824e9a3` | 5c | Daemon snapshot receipts wired (mint on selected JSON read, validate on patch, invalidate on commit, two-conflict close); AC.5 live sandbox test |
| `6280f47c`/`a492b0b5` | 5d | Host `--kind lint` audit log (agent-log detection); REQ-54 full compare with store-observed change regions; daemon written-version verification records |
| `be711293` | 6a | `WikiLintEval` harness: fixture manifests, diff oracle, per-class scoring, `LintAcceptanceGate`; shipped `LintGateFixtureManifest.json`; `WikiLintEvalRunner` (inspect/replay/live-refusal); 9 harness tests |
| `4d4d07b9` | 6b | Rollout gate wired into the coordinator: unaccepted configurations run REPORT-ONLY by construction |

## Key semantics (where to look)

- **Table alias-pipe semantics (sourced verdict).** A GFM table row like
  `| [[page:X|alias]] | text |` is MALFORMED per the GFM table extension:
  every unescaped `|` is a cell delimiter, and the extension requires
  pipes inside inline spans (links included) to be escaped. cmark-gfm and
  markdown-it scan rows block-first with no bracket awareness — excess
  cells are truncated, so the alias is severed from the link and the
  entry renders broken. Obsidian users report the same failure and the
  same workaround. Sources: github.github.com/gfm/#tables-extension-,
  github.com/github/cmark-gfm/blob/master/extensions/table.c,
  forum.obsidian.md/t/55052. Consequences:
  - D03 findings on such rows are TRUE positives (the production lint
    01M5QY0GWWR9S270DDGRJ7TQ0B was correct); the honest agent outcome is
    `unresolved` — the repair is not mechanical.
  - Correct authoring: escape the alias pipe (`[[page:X\|alias]]`) or use
    a pipe-free form. (Whether the wiki-link parser should accept `\|` as
    an alias separator is a follow-up reader/parser enhancement.)
  - A renderer MAY protect wiki spans before the table scanner to make
    unescaped aliases work — that is a deliberate GFM deviation, not a
    bug fix, and this plan does not make it.
- **Pure scanning.** `LintPagePreflight.scan` never touches the store; all
  store/package inputs are injected facts (`Sources/WikiFSCore/Core/Lint/`).
  Protected code is byte-masked to spaces so textual detectors share authored
  byte offsets with AST ranges.
- **Repairs.** `page patch` hunks are exact ranged edits with per-hunk defect
  classes and reasons; the store applies them atomically in exact-body mode
  (untouched bytes byte-identical). Report-only classes
  (D02/D04/D05/D14/D18/D28) cannot authorize hunks.
- **Accounting.** The agent fills a fixed-format run report (one line per
  inventory item, finding, and audit step). `LintCoverageValidator` rejects
  omitted/duplicated/unknown/wrong-head/contradictory outcomes; the harness
  never trusts counts alone.
- **Verification.** The daemon scans the WRITTEN immutable version after a
  committed patch (`DaemonLintVerificationRecord`); the coordinator re-scans
  the written bytes and runs `LintVerification.compare` with the change
  region observed from the store's own bytes. A moving current head is
  recorded as divergence, never merged.
- **Rollout gate.** `LintAcceptanceGate` (WikiFSCore) + `LintCoordinatorGate`
  (WikiFSEngine): the acceptance key hashes provider/model/revision/effort +
  the lint-task template bytes + the detector revision + the SHIPPED fixture
  digests. Records require human rubric metadata; selection is
  repair-authorized only on a complete match — every current configuration
  selects REPORT-ONLY.

## Honest limits

- The **live gate (AC.13) is blocked**: provider access, an operator-approved
  budget, and human rubric review are prerequisites. `run --live` reports the
  blocked prerequisites and makes no provider calls. Generalized repairs stay
  disabled (report-only) until a fresh gate passes.
- Inventory coverage proves accounting, not that a model truly read content;
  the seeded-defect oracle and live repetitions are separate evidence.
- Silent provider model replacements cannot be detected automatically; a
  suspected replacement requires a fresh operator-attested gate.
- Evidence-audit classes D12/D13/D16 remain deferred (future operation);
  D19 off; D21 strategy-owned.
