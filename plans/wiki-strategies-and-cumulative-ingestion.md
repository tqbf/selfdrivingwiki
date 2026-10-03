# Wiki strategies and cumulative ingestion

## Scope

Each wiki can store a named Markdown strategy. Default means no custom editorial instructions.
The first release supports manually imported sources. It does not add subscriptions, scheduling, repository connectors, or remote story acquisition.
It does not enforce spoiler limits or branch selection. Templates do not fetch sources.

## Strategy document

The strategy is a singleton record, not a page or an editable system prompt.
Saves compare the editor's expected revision inside the write transaction.
Reset retains a revision record so an older editor cannot overwrite a later reset.
An unchanged save does not advance the revision or emit a resource change.

The display name limit is 120 characters. The instruction limit is 32 KiB of UTF-8.
Oversized input fails visibly. Empty or whitespace-only instructions reset to Default.
Strategy changes apply to future runs. Saving does not reorganize existing pages or enqueue ingestion.

## Instruction precedence

Compiled application safety and write contracts remain mandatory.
The captured strategy controls editorial taxonomy, organization, and interpretation.
The current operation defines task scope. Sources supply evidence, never authorized instructions.
Default retains summary, entity, and concept organization.

A request captures the committed strategy when execution starts, not when a queue item is added.
An active run keeps that captured strategy. A later chat turn captures the latest saved strategy.
The mounted `WIKI-STRATEGY.md` document instead shows the current strategy when a standalone agent reads it.
Orchestrated agents must not reread that live document to replace their captured strategy.
`CLAUDE.md` and `AGENTS.md` remain identical compiled application documents.

## Editor and templates

Strategy belongs to the active wiki, outside global Operations settings.
The editor uses a local draft with Save, Cancel, Reset to Default, and Reload after a conflict.
A conflict preserves the draft. Navigation must protect unsaved changes.
A template copies its name and Markdown into the draft. Later template changes do not change saved strategies.

The starter templates cover Diataxis Tutorials, How-to Guides, Reference, and Explanation, plus Story Analysis and Repository History.
Story Analysis separates revelation order from event chronology and supported facts from interpretations.
Repository History separates proposed changes from integrated changes and stated rationale from inferred rationale.

## Cumulative updates

Routine ingestion can update existing pages. There is no blanket rewrite approval gate.
Each target has one assigned writer, including targets supported by several staged sources.
The primary source identifies responsibility. It does not exclude other evidence.

Before composition, the writer reads an existing page's body and head together through the JSON page read.
The writer preserves supported claims, incorporates new evidence, and qualifies superseded interpretations.
Historical accounts remain distinct from corrected current claims when the strategy calls for history.
Citations follow the claims that remain. Provenance records sources used for the resulting version.
The store does not automatically union all historical citations or provenance.

An existing-page write supplies the head from that body read.
On conflict, the writer rereads the body and head, recomposes, and retries once.
A second conflict must report failure, not success. Refreshing only the head cannot make a stale composition safe.
An absent-page write uses `--create-only`. If another writer creates the page first, the writer reads and reconciles that page.

The GRDB composed write resolves the target, checks the expectation, writes content and provenance, and replaces parsed links in one transaction.
Rollback must preserve the previous body, head, provenance, and links. It must emit no page event.
Embeddings remain nonfatal derived work outside the transaction.
The finalizer only updates the index and log.

## Validation and semantic limits

Store, prompt, projection, editor, and scripted pipeline tests check deterministic contracts.
A scripted backend proves transport and write behavior. It does not prove that an arbitrary model follows editorial instructions.
The live evaluation runs local authored fixtures through a configured backend in an isolated wiki.
It records prompts, run metadata, page identity, links, provenance, and version history.

### Human rubric

For each live result, record Pass or Fail and cite the relevant page passage.

1. Check that the page retains each supported fact from the first source.
2. Check that the page incorporates the second source's correction without an unresolved contradiction.
3. Check that each retained factual claim has supporting evidence and no unsupported claim appears.
4. Check that historical interpretations remain labeled when the strategy requires history.
5. Check that the same evidence follows the selected tutorial or reference organization.
6. Check stable page identity, version history, current citations, provenance, and unrelated-page isolation.

A structural pass alone is not a semantic pass. A fake run is not live release evidence.
Missing provider access can block live validation. Report that blocker before declaring release readiness.

## Evidence

Implementation and gate results belong in `progress/`.
The approved acceptance criteria require targeted suites, full `make build` and `make test`, synchronized prompts, and bare SwiftPM gates.
Independent review must cover transaction events, host paths, precedence, visible editor workflows, and test claims.
The operator owns merging. Agents must not enable auto-merge or enqueue a merge.
