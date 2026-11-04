# Foreground page lint

Status: implemented (this branch). Queued wiki lint is retired; page
review is a foreground, single-page **window** (non-modal, resizable — the
same value-driven `WindowGroup` idiom as Compare Versions), opened from the
page toolbar's Lint button or the sidebar page context menu's Lint item, and
raised to front on open (`openWindow` creates the window without reliably
raising it).

## Two pipelines, one rule

The feature has a **check pipeline** and a **repair pipeline**, and neither can
save wiki content. Only the sheet's **Apply** button saves, and only through
the app model's composed upsert with the previewed candidate pinned.

- **Check** produces typed findings against one captured page snapshot.
- **Repair** produces one bounded proposal for the option the user picked.
- **Apply** commits exactly the previewed canonical candidate once, or writes
  nothing.

## Configuration (`lint-pipelines.json`)

Stored beside `agent-providers.json` in the App Group container. Missing file →
the bundled defaults apply in memory. An invalid or unsupported-version file is
NEVER overwritten; the typed problems surface in the sheet. Version 1 schema:

```json
{
  "version": 1,
  "checkSteps": [
    { "id": "builtin-wiki-links",  "kind": "built-in", "builtin": "wiki-links" },
    { "id": "builtin-cosmetics",   "kind": "built-in", "builtin": "markdown-cosmetics" },
    { "id": "model-page-review",   "kind": "acp", "prompt": "bundled:lint-check",
      "providerId": null, "modelId": null,
      "timeoutSeconds": 300, "maxOutputBytes": 262144 }
  ],
  "repairRecipes": [
    { "id": "bracket-correction", "label": "Fix bracket syntax",
      "kind": "built-in", "builtin": "bracket-correction",
      "validators": [
        { "id": "bounds",  "kind": "built-in", "builtin": "replacement-bounds" },
        { "id": "scope",   "kind": "built-in", "builtin": "passage-scope" },
        { "id": "fences",  "kind": "built-in", "builtin": "fence-integrity" }
      ] },
    { "id": "model-repair", "label": "Repair with model",
      "kind": "acp", "prompt": "bundled:lint-repair",
      "validators": [ "…" ] }
  ]
}
```

Validation runs before launch: duplicate ids, absent recipe references,
unsupported step kinds, missing prompts/executables, invalid limits, and
unresolved explicit provider/model pins. `"kind": "decision"` decodes but
always fails validation — typed decision models are deferred until the
provider contract exposes them. ACP steps without overrides fall back to the
legacy `lint` provider/model pin, then the global default.

## Snapshot and coordinates

The session captures page identity, body, head version, strategy revision,
rendered strategy, and resolution namespaces in ONE store read transaction
(`WikiStore.lintCapture`). All finding coordinates are UTF-8 byte offsets into
the captured body, each carrying its expected text; `LintLocationAdapter`
(WikiFSMarkdown) is the single UTF-8↔UTF-16 conversion point. An invalid
passage location fails the producing step — the host never invents a
page-level finding from one.

## Step isolation

- `.lintCheck` / `.lintRepair` are distinct provider stages. Each step gets a
  fresh, NON-cached backend and a fresh ACP session bound to its stage token.
- `ClientCapabilities` are deny-based via the `.plan` permission policy: every
  tool/permission request is auto-denied. Provider subprocesses still get OS
  write isolation: the extraction/probe-grade `SandboxProfile.readOnlyInvocation`
  baseline over a per-snapshot `LLMSandboxScratch` — never the strict
  summarizer tier.
- Scripts run through `LintScriptRunner`: one bounded request JSON file in
  private scratch passed as a fixed `--request` argument, one bounded JSON
  envelope on stdout, timeout + output caps, nonzero exit = failure, and a
  seatbelt profile that denies all writes outside scratch, denies the network,
  and denies the wiki database and daemon socket paths (emitted last,
  last-match-wins). Sandbox unavailability prevents launch.

## Structured output

Model and script steps return ONE JSON envelope. A whole-response Markdown
fence is accepted; prose is never scraped. The decoder rejects unknown fields,
wrong run/page identities, invalid locations, unauthorized recipe ids, and
oversized output. A bad output fails the step visibly — it never becomes "zero
findings" or a clean page.

## Repairs, preview, Apply

A proposal is a bounded array of exact replacements bound to the snapshot
digest, finding, option, and recipe. Passage repairs stay inside the finding's
approved ranges; page-wide repairs remain one explicit option and require the
full preview. Before the diff shows, the candidate is canonicalized with the
same link rewriter the composed upsert uses. Apply pins BOTH the expected head
AND the previewed canonical body: if the title graph moved and in-transaction
canonicalization would produce different bytes, the store throws
`PageCanonicalizationConflictError` and nothing is written. Dirty editor
drafts block starting lint and block Apply; deleted pages, stale heads, and
double-Apply all refuse with zero writes and zero events.

## Cancellation and lifetime

The sheet owns one run per wiki (per-wiki coordinator). Run generation rejects
late results after cancellation, dismissal, or rerun. Closing the sheet
cancels in-flight work and discards proposals. Wiki shutdown rejects all late
results.

## Retired queued lint

The queued lane is gone: the sidebar and whole-wiki lint actions, the
`runLint`/`runLintPages` provider methods, the executable `OperationRequest`
and `WikiOperation` lint cases, and the old prompts are removed. New lint
payloads are refused at `QueueEngine.enqueue` and `QueueStore.enqueue`
(daemon/CLI included). Pending, recovered, or retried legacy lint terminates
visibly in `QueueIngestionWorker.execute` before any provider call. Historical
rows, transcripts, targets, and reports still decode; their raw `lint` queue
kind maps to ingestion at the persistence boundary with the typed
`isLegacyLint` classification preserved. Ordinary ingestion is unaffected.
`WikiStoreModel.preflightLint` (the old auto-saving preflight) is removed; the
detection logic lives on read-only in `LintAnalyzer`.

## Resource and content checks (2026-10)

The deterministic pipeline now carries version-aware resource and content
checks, all read-only over ONE captured snapshot.

### Capture

`lintCapture(pageID:)` reads, inside ONE `dbWriter.read` transaction: the page
row and head version, the resolution namespaces, the CITATION evidence, and
the head's declared PARENT version (from the head's `parent_id`, never "the
second history row"). Citation evidence is typed, not a string map:

- Occurrences parse through the shared span/syntax APIs: alias-free links,
  aliases, source names, canonical ids, `@vN` pins, quote fragments, heading
  fragments. Fenced and inline-code content is excluded. Embeds are not
  citations.
- Each distinct (source id, version request) pair gets one record with an
  explicit status: present (complete or bounded prefix), missing target,
  missing version, unavailable extraction, read failure, or budget omission.
  A missing dictionary entry is never read as "broken".
- Pins resolve through the store's `@vN` ordering; the unpinned form resolves
  through the reader's head rules (ref first, newest-ULID fallback).
- Source names resolve through a multiplicity-preserving index with the
  store's precedence (exact → legacy projection → extension-stripped →
  loose-key unique). A tier with several candidates is reported as AMBIGUOUS
  with its candidate ids; nothing is picked silently.
- Named budgets: 32 source-version targets, 512 KiB per source version,
  4 MiB aggregate source text, 512 KiB parent text, 512 citation
  occurrences. Clipping happens only on Unicode scalar boundaries; the
  original byte count and a completeness flag stay with the record.
- The read pool path (`WikiReadAccess.lintCapture`) and the model's
  memory-fallback path (main-actor hop) implement the same contract. Read
  failures THROW; nil is only a genuinely missing page or head.

### Checks

- Footnotes (`footnotes`): undefined references and conflicting duplicate
  definitions are report-only. An unused definition is informational. The
  single safe repair deletes a redundant definition ONLY when its normalized
  label and complete authored bytes match the retained definition
  (`redundant-footnote-deletion`).
- Citations (`wiki-citations`): pins validate without quotes. Quote
  correspondence uses `WikiQuoteProjection` (WikiFSMarkdown), a pure
  visible-text projection mirroring the production reader: typography
  normalization, entity decoding, HTML inline elements, paired-emphasis
  stripping with flanking constraints (identifiers keep underscores), and
  the reader's ≥4-word partial fallback. Full, partial, missing, and
  unavailable are distinct verdicts. A quote absent from a PREFIX capture is
  unverified, never absent; a quote present in a prefix verifies the prefix
  only. Ambiguous source names are report-only with candidates. A uniquely
  resolving name can canonicalize to its typed id
  (`source-canonicalization`). The only quote repair is the encoding-only
  edit (`citation-encoding-fix`), offered only when the whole quote has a
  UNIQUE evidence-backed correspondence after projection and the candidate
  still resolves through the reader's search — markdown emphasis in the
  anchor versus HTML emphasis in the source is the required case.
- Tables (`table-structure`): report-only. Declared-column mismatch and
  wiki-link alias/quote pipes that sever cells are found from AUTHORED
  unescaped pipes (the parser discards extra cells, so the AST cannot be the
  detector). Escaped pipes and fenced examples are never flagged.
- History (`history`): compares the captured parent. For a COMPLETE parent
  it reports one page-scoped candidate with concrete counts: lost table
  blocks, removed citation occurrences (identity = target + version request
  + fragment, so alias edits never count), and a substantial reduction
  (≥50 percent AND ≥256 non-whitespace scalars). Incomplete parents mark the
  comparison incomplete. First versions stay silent. Nothing is ever
  restored automatically.
- Truncation candidates (kept from the earlier work) stay report-only.

Recipe ids are stable; the new safe recipes are `redundant-footnote-deletion`,
`source-canonicalization`, and `citation-encoding-fix`. Defaults are keyed
by step id, never array index.

### Model evidence disclosure

Check and repair prompts embed a bounded JSON evidence object: source id,
requested pin, resolved version id, digest, availability label, and labeled
excerpts; the parent version and labeled history excerpt; omission counts.
Budgets: 8 source records, 8 KiB per record, 16 KiB parent, 64 KiB total
evidence; the complete page body is capped separately at 256 KiB and the
complete serialized task at 384 KiB. Excerpts prefer a window around an
exact quote match (1 KiB each side). Repair evidence leads with the
selected finding's source targets. When a limit is exceeded the model step
is SKIPPED with a visible notice — never a clipped page or clipped evidence
identity. Evidence, strategy, and page content are untrusted data between
explicit markers. A custom configured prompt is captured at run admission
and used verbatim; a missing capture fails the step visibly. Source-text
presence is not claim support; missing evidence cannot establish a false
claim; the prompts permit uncertainty and empty results on valid historical
prose. Version-1 script steps keep their exact request contract — these
checks are built-in Swift code, and source-aware custom-script evidence is a
future versioned protocol change.

## Deferred

Decision-model execution (no typed decision surface in ACP today), wiki-wide
foreground lint (intentionally not built), raw-URL citation conversion,
rich-fence validation, and a broad generated-debris detector (separate work).
Live model-quality evaluation needs a configured provider AND a human rubric
review — the driver and its guard tests exist (`LintLiveEvaluationTests`,
opt-in), but a provider-less run records the blocker, and no model-quality
claim is made without the manual rubric pass. The lint-specific hosted
window driver exists (`ForegroundLintHostedTestDriver` + gated suite, run
with `WIKIFS_APP_TESTS=1 WIKIFS_LINT_HOSTED=1`), but in-process
accessibility queries poison the test process's exit (swiftpm-testing-helper
segfault after pass — operator-accepted limitation, recorded to
`tmp/lint-hosted-a11y/`); an out-of-process driver is future work. The
earlier foreground-lint verification debt (subprocess/ACP fixture suites)
stands.
