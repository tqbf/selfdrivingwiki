# Foreground page lint

Status: implemented (this branch). Queued wiki lint is retired; page
review is a foreground, single-page **window** (non-modal, resizable — the
same value-driven `WindowGroup` idiom as Compare Versions), opened from the
page toolbar's Lint button or the sidebar page context menu's Lint item.

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

## Deferred

Decision-model execution (no typed decision surface in ACP today), wiki-wide
foreground lint (intentionally not built), and live model-quality evaluation
(needs a configured provider and human review — separate evidence).
