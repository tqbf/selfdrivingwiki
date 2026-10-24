# Generalized Page Validity Lint Requirements

**Status:** Approved requirements. Operator decisions resolved 2026-10-23. Advisor review incorporated.
**Scope:** Validity checks and bounded repairs for LLM-maintained wiki pages.
**Motivation:** The #1461 incident — a lint audit with a clean pre-flight report concluded "needs no changes" on a page with a malformed table and raw external URLs.

## Review provenance

Authored by an OpenAI-family model (codex/gpt-6.1-sol). Independently reviewed by an
Anthropic-family model (claude-opus-5-5) via paseo session
`5df2823c-4638-41c4-9321-f1e142cb92d7`. This revision applies every change the review
required before landing, plus the operator decisions of 2026-10-23. Decision markers
`(D1)`–`(D6)` refer to the "Resolved operator decisions" section at the end of this
document.

The review's central finding shapes this revision: the #1461 failure was a **discovery**
failure, not a repair failure. When pre-flight listed a defect, the model acted on it.
When pre-flight listed nothing, the model found nothing. Each prompt-only rule in this
revision therefore has an enforcer in code — an operation policy, a patch-style write
primitive, an app-side re-scan — so the prompt covers only judgment calls.

## 1. Purpose

**REQ-01.** Page lint shall detect malformed content that a link-only audit misses.

**REQ-02.** Page lint shall repair confirmed defects when the available evidence supports a safe, local repair. Repairs are applied as patch hunks, not full-body rewrites (REQ-53).

**REQ-03.** Page lint shall preserve valid content, evidence, and intentional formatting.

**REQ-04.** Lint shall distinguish page validity from editorial quality. Strategy shall own editorial choices.

A defect is not a lint repair merely because the page could be clearer, shorter, broader, or better organized.

The current task already requires full checks after clean pre-flight results. The generalized task shall retain this requirement.

## 2. Ownership and decision boundary

### 2.1 Mechanical findings

A mechanical detector shall establish an observable fact from page text, supported syntax, or resource identity.

Examples include an unmatched fence candidate, an empty link target, a footnote reference with no definition, or a missing source ID.

A mechanical finding may include a **candidate repair** when a unique match exists (REQ-40). A proposal is not a declaration of author intent. A mechanical finding shall never by itself authorize a rewrite.

Pre-flight lists facts; the lint model decides what changes. `Sources/WikiFSCore/Core/LintPagePreflight.swift` (pre-flight worklists, #1462).

### 2.2 Judgment checks

The prompt audit shall decide whether a candidate is accidental, whether evidence supports a repair, and whether the repair preserves meaning.

The agent shall report uncertainty instead of selecting an unsupported interpretation.

### 2.3 Strategy-owned rules

Heading style, organization, taxonomy, tone, coverage, line width, and citation density shall remain strategy concerns unless an application contract requires otherwise.

Strategy shall not waive application safety, supported link syntax, source identity, or write constraints.

### 2.4 Finding outcomes

Each finding shall receive one outcome:

- **Repaired:** A confirmed defect has a verified repair, applied as a hunk with its defect class.
- **Valid as written:** Context establishes that the candidate is intentional or supported.
- **Unresolved:** A defect or concern remains because evidence or a safe repair is unavailable.
- **Outside lint scope:** The concern belongs to strategy or another operation.
- **Check blocked:** The agent could not complete a required check.

An unresolved finding or blocked check shall prevent a claim that the page passed every check.

## 3. Defect taxonomy

**M** means mechanical detection. **J** means judgment. **S** marks strategy ownership.

Every class below separates detection from repair authority. Examples describe candidates, not unconditional rewrite rules.

v1 scope notes: D02, D04, D05, and D14 are **report-only** in v1 (D4). D12, D13, and D16
move to a separate future evidence-audit operation (D3). Detector foundations are the
renderer's own parser (REQ-46) — a P0 prerequisite, not a later refinement.

| ID and class | Example | Mechanical boundary | Judgment and repair boundary | Ownership |
| --- | --- | --- | --- | --- |
| D01. Fence boundary damage | A missing closing fence makes later prose appear as code. A short closer fails to close a longer fence. | M: Identify fence opener, marker, length, nesting context, and apparent closure under the supported dialect, from the AST. | J: Confirm that later prose escaped its intended context. Restore only the evidenced boundary. Never add a closing fence solely because EOF ends a block. | Lint for accidental rendering damage. Legal EOF-closed blocks remain valid. |
| D02. Other Markdown delimiter damage | A lost inline-code delimiter or broken `[label](target` expression. | M: Report suspicious delimiter runs and incomplete recognized constructs. Do not label every unmatched punctuation mark invalid. | J: Distinguish prose punctuation and literal examples from intended markup. | **Report-only in v1 (D4).** Detectors list candidates; the prompt instructs report-don't-rewrite. Emphasis style is S. |
| D03. Table damage | Missing header separator, shifted cells, or a pasted multiline cell that becomes another row. | M: Report candidate table bounds, separator shape, and cell counts. Respect escaped pipes and supported table forms. | J: Confirm table intent and cell ownership. Preserve every row and cell value. Do not invent headers or drop data. | Lint for structure. Table versus list presentation is S. |
| D04. List nesting damage | A child item becomes detached prose after an indentation loss. | M: Report suspicious indentation transitions and detached continuation candidates. | J: Infer intended membership from surrounding text. Preserve ordered-list meaning, task states, and code examples. | **Report-only in v1 (D4).** Marker choice and preferred indentation are S. |
| D05. Heading or title damage | A merge repeats a title and section body. A heading changes from level two to level five. | M: Report repeated headings, repeated heading/body pairs, and level jumps. | J: Repair only evidenced duplication or lost hierarchy. A skipped level, repeated title, or multiple H1 headings alone does not prove invalidity. | **Report-only in v1 (D4).** Heading hierarchy conventions are S unless an application contract requires them. |
| D06. Malformed wiki-link expression | `[[source:]]`, `[[Target|]]`, an unclosed `[[`, or an accidental nested opener. | M: Inspect attempted expressions, including forms skipped by the parser. Exclude confirmed literal examples. | J: Recover intended target and boundaries when evidence permits. Otherwise report unresolved. | Lint. |
| D07. Broken or wrong-namespace target | A page, source, or chat reference points to no resource, or uses the wrong prefix. | M: Resolve each namespace with the shared identity rules. Distinguish absent targets from lookup failures. | J: Select a replacement only when identity is clear. Preserve useful text if removing link markup. Do not create content to make a target exist (REQ-06). | Lint for reference repair. New-page coverage is S and outside this operation. |
| D08. Noncanonical source target | `[[source:report.pdf]]`, a display name, path, or `slug--ULID` instead of a bare SourceID. | M: Inspect the source base after separating namespace, version pin, fragment, and alias. Resolve candidates to canonical SourceIDs. A display name that resolves to exactly one SourceID yields a candidate repair (REQ-40). | J: Resolve ambiguous identities with source evidence. Preserve valid pins, fragments, quote text, aliases, and embed roles. | Lint under the existing canonical-source rule. |
| D09. Fragment, quote, or version-pin damage | A dangling quote, a nonexistent section, a quote absent from the pinned source version, or a nonexistent extraction pin. | M: Check syntax and exact target/version availability where supported. Report quote-match or anchor-resolution results separately. | J: Preserve title text containing `#`. Never invent a quote or silently repoint a version pin. Report ambiguous repairs. | Lint for invalid anchors. More precise citations are S unless needed to repair a false reference. |
| D10. Unsupported or broken embed | `![[Page]]`, `![[chat:Title]]`, or a source embed whose resource no longer exists. | M: Check permitted embed namespaces and resource existence. | J: Determine whether the author intended a citation, an embed, or a literal example. Preserve source embeds with supported syntax. | Lint for invalid expressions. Media selection is S. |
| D11. Raw external URL | Bare `https://example.org/report` where an existing wiki resource covers that exact material. | M: List raw URL occurrences and context. A raw URL that exactly matches an ingested source's origin URL yields a candidate repair (REQ-40). | J: Replace only with a verified equivalent page or source. Keep the URL when no equivalent exists. Do not delete the only reference. | Lint under the existing URL rule. External-link style otherwise belongs to S. |
| D12. Missing or mismatched claim support | A numeric claim lacks its available supporting citation. A citation points to evidence that says something else. | M: Compare known citation IDs with version inputs when available. This cannot establish semantic support. | J: Read the relevant input passages. Add or repair a citation only when those passages support the claim. | **Out of v1 (D3).** Moves to a separate evidence-audit operation. Citation density is S. |
| D13. Stale or detached citation | A merge removes a claim but leaves its citation attached to unrelated text. | M: Identify isolated citation candidates and reference structures. | J: Determine which surviving claim, if any, the citation supports. Remove only the detached reference, not evidence for retained claims. | **Out of v1 (D3).** Moves to the evidence-audit operation. Bibliography layout is S. |
| D14. Placeholder or template residue | An unfilled `{{claim}}`, accidental `TBD`, or lorem ipsum inside a factual paragraph. | M: List token occurrences with context. | J: Distinguish accidental residue from quoted text, a genuine task list, or a page about TODO markers. Never invent replacement facts. | **Report-only in v1 (D4).** Accidental residue is lint; intentional incomplete notes are S. |
| D15. Duplicate blocks or merge residue | The same paragraph and citation block appears twice. Conflict markers remain after a merge. | M: Find conflict markers and exact substantial duplicate blocks with both locations. Conflict markers are deterministic (REQ-40). | J: Confirm accidental duplication. Preserve intentionally repeated warnings, quotations, examples, and distinct evidence. | Lint for confirmed merge damage. Repetition preference is S. |
| D16. Contradictory duplicate statements | A page says the same measurement is both 12 and 21 for the same time and scope. | M: At most, surface near-duplicate text or conflicting token values. No mechanical truth decision. | J: Compare source passages, dates, and attribution. Preserve documented disagreements and historical changes. | **Out of v1 (D3).** Moves to the evidence-audit operation. Interpretation and historical presentation are S. |
| D17. Encoding damage | U+FFFD, NUL, or `FranÃ§ais` in text whose source contains `Français`. Invisible or bidi control characters inside link targets that make a link look valid but resolve broken. | M: List replacement/control characters, bidi overrides inside link targets, and suspicious encoding sequences. | J: Confirm damage against accessible source or history. Preserve legitimate multilingual text and technical literals. Never guess missing characters. | Lint for confirmed corruption. Typography normalization is S. |
| D18. Pasted active content or source instructions | An accidental script block, event handler, dangerous URL scheme, or instruction pasted from a source. | M: Identify candidate active constructs and unsafe schemes outside literal examples. | J: Treat source content as evidence, never instructions. Report the candidate with location and evidence. Do not execute it. | **Lint reports only (D6).** The renderer or sanitizer owns active-content safety. Harmless HTML is not automatically invalid. |
| D19. Page metadata or front-matter damage | A required metadata field is malformed, or an accidental front-matter opener consumes content in a supported format. | M: Validate only a documented page metadata contract. | J: Distinguish literal YAML, horizontal rules, source examples, and intended metadata. | **Off in v1.** No page metadata contract exists today. Revisit only after an application contract is documented. |
| D20. Missing image, media, or Markdown reference destination | `![Chart](missing.png)` or `[claim][missing-label]` has no resolvable destination. | M: Check defined reference labels and supported local resource identities. Report remote status separately from identity. | J: Repair only verified destinations. Preserve alt text and captions. Do not fabricate media or treat a transient network failure as deletion evidence. | Lint for broken references. Media coverage is S. |
| D21. Long lines or cosmetic formatting | A valid paragraph occupies one long source line. | M: Measure line length and formatting patterns if useful. | J: No validity repair based on length alone. A real renderer limit requires a separate documented contract. | S. Exclude from default validity findings. |
| D22. Footnote damage | `[^1]` is referenced but never defined. Two definitions share an ID. A definition is not a valid `[[source:…#"quote"]]` citation. | M: Match references to definitions. Flag orphans, duplicate IDs, and definitions whose target fails the source-citation rules. Footnotes are the wiki's citation convention, so this check is fully mechanical. | J: Repair a definition only with a verified source target. Never invent a quote or a source ID. Preserve footnote text otherwise. | Lint. Footnote density and style are S. |
| D23. Truncated output | The body ends mid-sentence, mid-table row, or mid-list item after a token-limit cut. | M: Report bodies that end mid-construct: an unclosed inline construct, a dangling table row, an incomplete final sentence. | J: Confirm against source length and page history. A body that ends in a complete construct is not truncated. Never invent the missing ending — an unconfirmed truncation is an unresolved finding (D6). | Lint for confirmed truncation. |
| D24. Agent meta-text leakage | "Here's the updated page:", a pasted wikictl CAS error, a scratch path, or tool transcript left in the body. | M: Match a bounded phrase list and tool-output shapes outside literal examples. | J: Distinguish leaked meta-text from quoted examples. Removing a clear leak is a permitted removal of accidental content. | Lint. |
| D25. Whole-body fence wrap | The entire body is wrapped in a ` ```markdown ` fence, so links and tables render as literal text. | M: One fence opens at the first line and closes at the last. Fully deterministic; the most frequent D01 form in practice. | J: None required. This is a mechanical repair candidate (REQ-40): unwrap the body, preserving its content. | Lint. |
| D26. Escaping-layer damage | `\[\[Page\]\]`, over-escaped `\*emphasis\*`, double-encoded `&amp;amp;`, or a literal `\n` in prose, after a body passed through JSON or a shell. | M: List suspicious escape sequences, double-encoded entities, and literal escape text outside code ranges. | J: Confirm against source text and history. Preserve intentional literals and technical examples. Never guess the intended character without evidence. | Lint for confirmed damage. |
| D27. Regression against the previous head | A "reconcile" rewrite silently drops a table, two citations, or a section; the body is far shorter than the previous head. | M: Diff the current head against the previous head from page history. Report large shrinkage and dropped tables, citations, sections, and footnotes (REQ-57). | J: Confirm the drop is accidental. Strategy-driven reorganization is legal and preserved. | Lint for accidental loss. This is probably the most damaging maintenance defect class. |
| D28. Rich-fence re-validation | A mermaid (or other rich) fence written before the write-time validator existed, or unclaimed by any package, renders as literal text. | M: Re-run the write-time fence validation over the stored head. Report fences no package claims (REQ-49). | J: Report per the D28 rules; converting to a supported form is a candidate repair only with verified syntax. | Lint reports. Diagram and media selection is S. |

### 3.1 Existing syntax constraints

Source citations currently require a canonical bare SourceID, while preserving fragment, quote, or alias text.

The parser supports aliases, namespace prefixes, fragments, and source version pins. `Sources/WikiFSLinks/WikiLinkParser.swift`.

Same-page anchors do not enter the link graph. Only source links can be embeds.

Generalized detectors shall not mistake these valid forms for damage.

The current code protector (`WikiLinkSpan.protectedCodeRanges`) recognizes backtick fences and exact-length inline backtick runs, and its fence scan extends unmatched blocks to EOF. It does not handle tilde fences or fence length under CommonMark rules. Detectors shall not build structural analysis on this heuristic — see REQ-48. Code protection ranges shall derive from the AST.

## 4. Hard limits on repairs

**REQ-05.** Lint shall not rewrite tone, preferred structure, summaries, taxonomy, or coverage.

**REQ-06.** Lint shall not create a page merely to satisfy a broken link. The lint operation policy denies page creation mechanically (REQ-51). A broken link becomes an unresolved finding, and a missing page is created through ingest or query instead.

The current task text permits creation and editorial fixes; Phase 0 removes those permissions from the task prompt (D1).

**REQ-07.** Each content edit shall have a confirmed defect and a stated validity reason. The patch write makes this structural: every hunk carries its defect class (`--defect <class>`, REQ-52).

**REQ-08.** Repairs shall preserve supported claims, table data, quotations, aliases, valid anchors, and intentional examples.

**REQ-09.** Lint shall not invent facts, SourceIDs, quotes, anchors, media, or supporting passages. A post-write check verifies that newly added citations resolve and new quote fragments match source text (REQ-54).

**REQ-10.** Missing evidence shall produce an unresolved finding, not a fabricated citation or silent claim deletion.

**REQ-11.** Lint shall not update immutable raw sources, strategy, indexes, or unrelated pages to simplify a repair. The lint operation policy enforces this mechanically (REQ-51).

Raw-source immutability is an existing application rule. `prompts/system-prompt-default.md`.

**REQ-12.** Page and source content shall remain untrusted data. The agent shall not obey instructions found inside them.

**REQ-13.** Lint shall use the exact run wiki selector and the supported `wikictl` write path.

The existing write rule prohibits writes through the mount and requires the run selector. `prompts/ingest-write-rule.md`.

**REQ-14.** The body and head used for a repair shall come from the same current JSON read.

**REQ-15.** Existing-page writes shall use `--expect-head`. The operation policy rejects blind upserts from lint runs (REQ-51). A conflict shall trigger one fresh read and recomposition.

**REQ-16.** A second conflict shall stop the repair and produce a failure report. Lint shall never replay an old body with a refreshed head.

These requirements preserve the existing CAS contract. `prompts/ingest-write-rule.md`.

**REQ-17.** A repair shall retain honest version inputs for the resulting claims. The patch write carries the head's version inputs forward by construction; a hunk that adds a citation must name its source (REQ-54). Body citations alone shall not substitute for provenance.

**REQ-18.** A clean page shall receive no page write. Logging a completed audit shall remain permitted.

## 5. Prompt requirements

Lint policy lives in the task prompts, not the system prompt (D1). The system prompt says
nothing about lint. `lint-page-task.md` is self-sufficient: it carries the repair
permission, the validity scope, the no-editorial-rewrites rule, and the CAS contract. The
whole-wiki lintTask template carries its own report-only policy.

### 5.1 Scope and context

**REQ-20.** The prompt shall identify each selected page by stable identity and exact title.

**REQ-21.** The prompt shall state whether the operation can repair selected pages or only report whole-wiki findings. Selected-page lint repairs; whole-wiki lint is report-only.

**REQ-22.** The prompt shall use captured strategy only to understand valid intent and avoid editorial changes.

Each selected page runs as its own lint run (REQ-55).

### 5.2 Pre-flight worklist order

**REQ-23.** The prompt shall present worklists in this order:

1. Page identity, inspected head, scan coverage, and pre-flight repair records.
2. Scan failures, unavailable checks, and truncated findings.
3. Fence and block-boundary candidates, including whole-body fence detection (D25).
4. Other Markdown structure candidates: tables, lists, headings, delimiters. List, heading, delimiter, and placeholder candidates are report-only in v1 (D4).
5. Wiki-link syntax, target, citation fragment, version-pin, embed, and footnote candidates.
6. Raw URLs, Markdown references, media destinations, and rich-fence re-validation results (D28).
7. Placeholder, duplicate, conflict-marker, encoding and escaping damage, meta-text leakage, and regression candidates from history comparison.
8. Metadata-contract findings. v1 records that no page metadata contract exists (D19).
9. Required judgment audits that pre-flight cannot complete. Evidence-integrity audits are out of v1 scope (D3).

Boundary damage comes first because it can conceal later findings.

**REQ-24.** Every finding shall include page identity, inspected head, class, location, short evidence, and detector scope.

**REQ-25.** Every section shall state `none detected`, `not checked`, `blocked`, or `truncated` when applicable. Those states shall not be interchangeable.

**REQ-26.** A clean report shall require the complete checklist. It shall never authorize early completion.

**REQ-27.** Stale worklist locations shall remain clues, not authority. The agent shall inspect the current body.

### 5.3 Mandatory named audits

**REQ-29.** The prompt shall require these named checks for each selected page:

1. **Read current body and head.** Record the snapshot used for the audit.
2. **Audit block boundaries.** Check fences, whole-body wrap, code context, truncated endings, and leaked prose.
3. **Audit Markdown structure.** Check tables, list membership, headings, and broken inline constructs.
4. **Audit every reference.** Check all wiki namespaces, source identity, aliases, anchors, pins, embeds, footnotes, media, and reference labels.
5. **Audit content integrity.** Check accidental residue, duplication, encoding and escaping damage, meta-text leakage, and pasted active content.
6. **Audit regression against the previous head.** Check for unexplained shrinkage and dropped tables, citations, sections, and footnotes (D27).
7. **Audit applicable metadata.** In v1, record that no page metadata contract applies.
8. **Choose minimal repairs.** Emit hunks with defect classes. Reject editorial changes. List report-only candidates without rewriting them. Record unresolved cases.
9. **Write and verify.** Submit hunks through the patch write under CAS. The app re-runs pre-flight on the written head (REQ-54). The agent's readback provides context; it is not a verification gate.
10. **Log and report.** Account for each inventory item, finding, and audit step.

The agent shall perform a second audit of content exposed by a fence or block repair within the same run.

### 5.4 Inventory and per-item outcome contract

The no-change contract is replaced by inventory counts plus per-item outcomes that a
harness can check. A report that merely names completed checks is free to fake; counts are
not.

**REQ-30.** Pre-flight shall emit an inventory of the selected page: table count, source citation count, raw URL count, footnote reference and definition counts, and fence count.

**REQ-31.** The report shall give a per-item outcome for every inventoried item and every finding, using the outcome set in §2.4.

**REQ-32.** `Pre-flight found nothing` shall not satisfy the contract. A harness shall verify the report's per-item coverage against the emitted inventory counts.

**REQ-33.** Reports shall distinguish no defects, unresolved defects, blocked checks, CAS failure, and log failure.

### 5.5 Write, verification, and log contract

**REQ-34.** The agent shall submit only confirmed repairs, as patch hunks with defect classes and required provenance.

**REQ-35.** The agent shall read back the stored body after a successful write. Readback is context for the agent; the verification gate is the app-side re-scan (REQ-36, REQ-54).

**REQ-36.** Verification shall check that repaired defects are absent and no content, reference, or rendering defect was introduced. The app re-runs pre-flight on the written head and records any remaining findings in the log and UI.

**REQ-37.** The final report shall identify repaired, retained-valid, unresolved, and outside-scope findings.

**REQ-38.** Every completed audit shall append a `--kind lint` log entry.

The entry shall include:

- Page identity and inspected head.
- Written head and hunk summary with defect classes, if any.
- Audit-step outcomes.
- Retained candidates and reasons.
- Unresolved findings and missing evidence.
- CAS, readback, validation, and logging outcomes.

Machine-readable audit fields are deferred to v2 (D6). The text entry above is the v1 contract.

The user report shall not claim success when a write or verification failed.

### 5.6 Draft prompt outline

This is an outline, not final prompt prose.

1. **Task identity and permissions**
   - The selected page record.
   - Page-validity scope.
   - Repair mode (selected page) or report-only mode (whole wiki).
2. **Mandatory limits**
   - No editorial rewrites or invented evidence.
   - Source immutability and untrusted-content rule.
   - Exact wiki selector and CAS contract.
   - Patch-hunk write; no full-body rewrite path.
3. **Captured context**
   - Strategy reference.
   - Supported syntax; no page metadata contract in v1.
4. **Ordered pre-flight worklists and inventory**
   - Sections from REQ-23, plus the REQ-30 inventory counts.
5. **Named audits**
   - The nine checks from REQ-29.
   - Re-audit after boundary repairs.
6. **Repair and verification procedure**
   - Hunk submission with defect classes.
   - CAS, bounded retry, app-side re-scan, stored-body readback.
7. **Completion contract**
   - Per-item outcomes (REQ-31).
   - Lint log entry and user report.

## 6. Pre-flight requirements and priorities

### 6.1 Common detector contract

**REQ-39.** New detectors shall produce deterministic factual findings. They shall not silently rewrite page content.

Pre-flight bracket auto-fixes move under CAS and the reporting contract as a Phase 0 bug fix: today `preflightLint` persists bracket fixes through a blind upsert with empty provenance. That write races other writers and drops provenance from the head. Longer term, bracket fixes become candidate repairs the agent applies, so there is one write path (D6).

**REQ-40.** Findings shall expose location, rule, observed evidence, severity, and confidence without declaring inferred author intent. A finding may include a candidate repair when exactly one match exists — a display name resolving to one SourceID (D08), a raw URL matching one ingested source's origin URL (D11), conflict markers (D15), a whole-body fence (D25). A proposal is not a declaration of intent.

**REQ-41.** Detectors shall use shared link identity and syntax rules. They shall not invent a parallel link grammar.

**REQ-42.** Code examples shall remain protected where the relevant rule does not apply. Protection ranges derive from the AST (REQ-46). Fence analysis inspects fence boundaries themselves. Literal executable examples shall not become active-content violations.

**REQ-43.** A detector failure shall remain visible. An unavailable detector shall never return a clean finding set as its only status.

**REQ-44.** Detectors shall document dialect coverage and false-positive limits. The current table scanner recognizes runs of pipe-prefixed lines; it does not establish that every supported table form passed.

**REQ-45.** Pre-flight and post-repair checks shall use compatible rules.

**REQ-46.** The rendered page dialect is defined by the renderer's parser — swift-markdown plus the wiki-link extensions. Detectors shall parse with that same parser, so fences, tables, lists, headings, and footnotes carry reader semantics. This is a **P0 prerequisite**: no structural detector ships before the AST foundation lands. It settles the dialect question: where CommonMark, the old protector heuristic, and the renderer differ, the renderer's parser wins.

**REQ-47.** Lint shall complement write-time cosmetic fixes and fence validation. Lint re-runs the write-time rich-fence validation over stored heads, because pages written before the validator existed were never checked (D28).

**REQ-48.** Single-page and whole-wiki prompts shall share validity definitions without silently sharing write permissions.

**REQ-49.** Whole-wiki runs shall not gain repair permission through this document alone. Their scope requires an explicit operator decision.

**REQ-50.** Pre-flight shall compare the current head against the previous head using page history and report unexplained shrinkage and dropped structure as findings (D27). Page history is a free oracle; `page history` already exposes it.

The version-input read path requirements moved to the evidence-audit operation together with D12/D13/D16 (D3).

### 6.2 Priority order

| Priority | Detector and classes | Detection approach | False-positive risk and required guard |
| --- | --- | --- | --- |
| **P0 prerequisite** | AST foundation, all classes | Parse every body with the renderer's parser (REQ-46) before any structural detector runs. | Blocking. Without it, detectors inherit the protector's drift. |
| P0 | Fence boundaries, D01 + whole-body wrap D25 | AST fence nodes: markers, lengths, containers, closure. Whole-body-wrap fast path. | Medium. EOF closure and nested examples can be legal. D25 is deterministic. |
| P0 | Footnote integrity, D22 | Match references to definitions; flag orphans, duplicate IDs, and non-citation definitions. | Low for orphans and duplicates. Check definition targets by the source-citation rules. |
| P0 | Attempted wiki-link syntax, D06 | Compare attempted delimiters with complete parsed spans. Report empty targets, aliases, and damaged expressions. | Medium. Literal brackets and incomplete examples require context protection. |
| P0 | Canonical source IDs and namespace roles, D07–D10 | Separate base, pin, fragment, and alias. Resolve by shared namespace rules. Check embed roles. Unique matches yield candidate repairs. | Low for proven absent IDs. Medium for legacy names and ambiguous titles. Do not guess identity. |
| P0 | Existing table and URL coverage, D03/D11 | Retain existing facts. Add coverage tests for supported table forms, escaped pipes, aliases, and code contexts. URL-to-source exact matches yield candidate repairs. | Medium. Pipe prose and valid external URLs are not automatic defects. |
| P1 | Fragment and version availability, D09 | Validate declared syntax, target extraction versions, and supported anchor resolution. | Medium to high. Quote normalization, title hashes, and source revisions can make naive matching wrong. |
| P1 | Merge residue and exact duplicates, D15 | Find merge-marker lines and exact substantial duplicate blocks. Report both locations. Conflict markers are deterministic. | Low for markers outside examples. Medium for intentional repetition. No automatic deletion. |
| P1 | Markdown reference/media resolution, D20 | Match definitions and uses. Resolve supported local resource identities. | Low for missing local definitions. High for remote network results. Do not use remote failures as deletion proof. |
| P1 | Unsafe constructs, D18 | List known active elements, event handlers, and unsafe destination schemes in rendered content. **Report-only (D6).** | Medium. Code examples and harmless HTML require context. The renderer or sanitizer is the security boundary, not the prompt. |
| P1 | Encoding and escaping indicators, D17/D26 | Locate U+FFFD, prohibited controls, bidi overrides inside link targets, double-encoded entities, and suspicious escape sequences. | Low for prohibited controls and bidi in targets. High for inferred mojibake. Require evidence before character substitution. |
| P1 | Truncation, D23 | Report bodies ending mid-construct: unclosed inline construct, dangling row, incomplete final sentence. | Medium. Complete short endings are legal. Confirm against source and history. |
| P1 | Meta-text leakage, D24 | Bounded phrase list plus tool-output shapes, outside AST-protected code ranges. | Low–medium. Quoted examples are protected; keep the phrase list reviewed and small. |
| P1 | Regression against previous head, D27 | History diff: shrinkage ratio, dropped tables, citations, sections, footnotes (REQ-50). | Medium. Strategy-driven rewrites are legal. Judgment confirms before any repair. |
| P1 | Rich-fence re-validation, D28 | Re-run the write-time fence validator over the stored head. Report unclaimed fences. | Low. Report per D28 rules; no forced conversion. |
| P2 | List and heading candidates, D04/D05 | Report indentation anomalies, level jumps, and repeated heading/body regions. **Report-only in v1 (D4).** | High. Many forms are valid. Expected main source of false rewrites if repair were allowed. |
| P2 | Placeholder candidates, D14 | Locate a bounded token list and unresolved template syntax. **Report-only in v1 (D4).** | High. Genuine tasks and quoted templates remain valid. |
| P2 | Inline/reference delimiter candidates, D02 | Use supported syntax boundaries rather than raw punctuation counts. **Report-only in v1 (D4).** | High. Markdown permits literal unmatched punctuation. |
| Out of v1 | Claim support, detached citations, contradictions, D12/D13/D16 | Separate evidence-audit operation (D3). Requires a version-input read path `page get --json` does not have. | Putting these in v1 would make low-effort runs mark them blocked every time or fake them. |
| Conditional | Metadata, D19 | Validate only an approved page metadata schema and renderer behavior. | Off in v1. No page metadata contract exists. Do not enable by analogy with imported source metadata. |
| Excluded | Semantic truth | No mechanical claim-support or contradiction verdict. | Requires evidence and judgment. See the evidence-audit operation. |
| Excluded | Cosmetic width, D21 | No default detector for validity enforcement. | Strategy-owned unless an application limit proves rendering damage. |

## 7. Mechanical enforcement

The prompt covers judgment calls. Everything else has an enforcer in code.

**REQ-51.** A lint operation policy shall exist under the run-scoped capability design in `plans/agent-sandbox-scoping.md`. It shall permit writes only to the selected PageIDs. It shall deny page creation, index writes, strategy writes, source writes, and registry/queue-global operations. It shall require CAS: writes without `--expect-head` are rejected from lint runs. (D2)

**REQ-52.** Repairs shall use a new patch-style write: `page patch --expect-head <head> --hunk <body> --defect <class>`. Each hunk carries its defect class. Untouched text is preserved by construction. Lint runs shall have no full-body rewrite path. This is the single biggest lever in the design: without it, every repair is a full-body rewrite by a low-effort model, and content preservation is fragile. (D2)

**REQ-53.** After a lint write, the app shall re-run pre-flight on the written head and record any remaining findings in the log and UI. The agent's readback is context, not a verification gate. (review change 5)

**REQ-54.** A post-write integrity check shall verify that every newly added `[[source:…]]` resolves, any new quote fragment matches source text, and the write carried the head's version inputs forward. A violation fails the run and is recorded. (enforces REQ-09, REQ-17)

**REQ-55.** Each selected page shall run as its own lint run. Dispatchers shall not flatten multiple pages into one task. A page identity, its findings, and its writes stay attached to one page. This removes the wrong-page-write risk and the multi-page fixture group. (D6)

## 8. Success criteria

### 8.1 Deterministic requirements

**AC-01.** Each mechanical detector shall pass positive, negative, and boundary fixtures.

**AC-02.** Finding locations shall identify the correct page and inspected body.

**AC-03.** Detector errors and missing pages shall not appear as `none detected`.

**AC-04.** Prompt tests shall prove that empty worklists still contain every named audit, the inventory counts, and the per-item outcome contract.

**AC-05.** Integration tests shall prove CAS retry bounds, per-hunk defect-class recording, denial of creation and index writes under the lint operation policy, rejection of blind upserts from lint runs, and no writes after a second conflict.

**AC-06.** A clean audit shall add no page version and shall preserve page bytes and provenance. A second lint run on a repaired page shall produce zero hunks. A patch write shall carry the head's version inputs forward.

### 8.2 Live model requirements

Three runs per fixture is a weak statistical gate: a configuration that bails with
per-run probability 0.2 still passes 3/3 about half the time. The live gate below
concentrates runs on the failure that actually happened, scores diagnosis instead of
pass/fail, and defends against checklist theater.

**AC-07 (bail gate).** At least 20 runs on one targeted bail fixture that reproduces the #1461 incident: a clean pre-flight report and one seeded hidden defect. Every run must surface and correctly repair the defect. A single miss fails the configuration for rollout. (D5)

**AC-08 (per-class scoring).** Recall and precision are scored per defect class across the mixed fixture set. Recall: each seeded defect is repaired or unresolved-reported — never silently missed. Precision: each reported defect maps to a seeded defect. A mixed page with every defect class mostly tests long-context degradation, so scoring is per class, not per page. (D5)

**AC-09 (diff oracle).** Every hunk in every write must map to a seeded defect class. Any unattributed hunk fails the run. This replaces fixture-list-based preservation checks, which only cover content the fixture author remembered to list. (D5)

**AC-10 (held-out fixtures).** A held-out fixture set, never used for prompt tuning, runs at the gate tier under the same recall, precision, and diff-oracle rules.

**AC-11 (long page).** At least one long-page fixture places the defect late in the body. Production pages are longer than evaluation fixtures; the gate must hold at length. (D5)

**AC-12 (inventory check).** On every live evaluation run, a harness verifies the report's per-item outcomes against the pre-flight inventory counts (REQ-30..32). A report that skips inventoried items fails, whatever it claims. (checklist-theater defense)

**AC-13 (boundary cascade).** A boundary repair shall expose and repair later defects within the same run.

**AC-14 (model version change).** The full gate re-runs when the provider changes the model under the same name, and when the prompt revision changes. (D5)

**AC-15 (tiers and records).** The gate tier is the lowest effort tier actually used for lint in production — scheduled and batch runs are the ones that bailed. The ≥20-run bail gate uses that tier. Remaining fixture groups run three times per configuration. Each evaluation record includes provider, model, effort, prompt revision, fixtures, transcripts, and final page differences. Mechanical repairs are compared with deterministic expected output — normalized AST or byte comparison; human review is reserved for judgment fixtures.

Deterministic tests shall establish plumbing and contracts. They shall not substitute for live evidence of model obedience.

### 8.3 Required fixture set

Each fixture defines expected repairs, protected content, acceptable unresolved findings, and forbidden edits.

| Fixture group | Required cases and expected outcome |
| --- | --- |
| Bail reproduction (D5) | The #1461 shape: clean pre-flight report, one hidden defect (malformed table or raw URL). ≥20 runs; every run must find and repair it. Long-page variant with the defect late in the body (AC-11). |
| Structure-positive | Accidental unclosed fence, wrong fence length, whole body wrapped in a ` ```markdown ` fence, malformed table, detached list child, evidenced duplicated title. Repair without lost text. |
| Structure-negative | Legal EOF fence, longer outer fence around examples, supported tilde fence, inline code, escaped pipes, optional table pipes, intentional heading jumps, repeated headings, nested lists. Preserve valid content. |
| Link-positive | Empty target, empty alias, incomplete delimiters, wrong namespace, missing page/source/chat, noncanonical source name/path, damaged quote, invalid pin, invalid page/chat embed, invisible/bidi characters inside link targets. Repair only where targets are unambiguous. |
| Link-negative | Canonical IDs, explicit `page:`, aliases, source embeds, valid extraction pins, quotes containing pipes or hashes, titles containing hashes, same-page anchors, literal examples. Preserve. |
| Footnotes (D22) | Reference with no definition, definition with no reference, duplicate IDs, definition that is not a source citation; and the negatives — valid footnote definitions citing sources with quotes. Repair orphans and duplicates; preserve valid footnotes. |
| Reference-positive | Raw URL with verified equivalent (and the exact origin-URL match case), undefined reference label, missing local media. Repair from supplied evidence. |
| Reference-negative | Only available external citation, Markdown link, angle autolink, remote timeout, genuine bibliography, common-knowledge convention, source consulted without a visible citation (not a v1 lint defect — density is strategy). Preserve or report uncertainty as specified. |
| Content-positive | Unfilled template (report-only), exact merge duplication, conflict markers, recoverable mojibake, escaping damage, meta-text leakage, accidental active content (report). Repair without added claims; report where D4/D6 say report-only. |
| Content-negative | A TODO task list, article about templates, repeated warning, historical disagreement, conflicting attributed sources (contradictions are out of v1 — preserve), multilingual text, harmless HTML, quoted scripts, intentional escape literals. Preserve. |
| Truncation (D23) | Body ending mid-sentence, mid-table row, mid-list item; and a body that legitimately ends with a short complete list. Repair never invents the ending; confirmed truncation is unresolved unless a verbatim source continuation exists. |
| History regression (D27) | Previous head holds more tables/citations/sections than the current head; current head silently shorter. Report; repair only evidenced accidental loss. |
| Rich fence (D28) | Unclaimed mermaid fence on a page written before the validator existed. Report per D28; no forced conversion. |
| Ambiguous | Missing sources, ambiguous source names, absent source passages, uncertain anchor intent. Report unresolved without invention. |
| Concurrency and failure | One CAS conflict, two conflicts, failed readback, detector failure, log failure. Report exact outcomes and preserve concurrent edits. |
| Clean and idempotence | Clean pages across supported syntax. Zero page writes on initial and repeated lint runs (AC-06). |
| Held-out (AC-10) | A mirrored sample of the groups above, never used for prompt tuning. Same rules. |

Deferred to the evidence-audit operation: missing supported citation, wrong source attribution, detached citation, evidence-resolved contradiction fixtures.

Human review shall assess semantic preservation and evidence support on judgment fixtures. Parser success alone shall not establish acceptance (AC-15).

## 9. Delivery boundaries and phases

This document defines requirements. It does not by itself authorize an implementation.

**Phase 0 — blocking, first.** (D1, D6)

1. Remove the lint workflow section from `prompts/system-prompt-default.md` and sweep every other lint reference out of the system prompt. The system prompt says nothing about lint.
2. Strip "create the page if it should exist" and "fix stale content, factual gaps" from `prompts/lint-page-task.md` in the same change. The task keeps repair permission for validity defects only, with no-editorial-rewrites and CAS rules stated in full.
3. Move the pre-flight bracket auto-fix under CAS and the reporting contract, preserving provenance (bug fix — today it is a blind upsert with empty provenance).

**Phase 1.** AST detector foundation (REQ-46, P0), the lint operation policy (REQ-51), the patch-style write (REQ-52), the app-side post-write re-scan (REQ-53), the per-page dispatch (REQ-55), detector fixtures, and the live gate (§8.2).

**Deferred.** The evidence-audit operation (D12/D13/D16 and the version-input read path), machine-readable log fields (v2), and the page metadata contract (D19).

Implementation work shall include prompt alignment, detector tests, dispatch coverage, and live evaluation. Each phase lands through review.

---

## Resolved operator decisions (2026-10-23)

All decisions below are resolved. They are not open questions.

- **D1 — No lint in the system prompt.** Delete the lint workflow section from `prompts/system-prompt-default.md` and sweep other lint references. Lint policy lives entirely in the task prompts: `lint-page-task.md` is self-sufficient (repair permission, validity scope, no-editorial-rewrites rule, CAS); the whole-wiki lintTask template carries its own report-only policy. Blocking Phase 0. This resolves the system-prompt/task contradiction by removal. (Retires REQ-19 from the draft.)
- **D2 — Patch-style write plus operation policy.** Repairs use `page patch --expect-head <head> --hunk <body> --defect <class>`. Each hunk carries its defect class; untouched text is preserved by construction. A lint operation policy under the scoped-run capability design (`plans/agent-sandbox-scoping.md`) permits writes only to selected PageIDs, denies creation and index writes, and requires CAS. (REQ-51, REQ-52.)
- **D3 — Evidence audit moves out of v1.** D12 (missing/mismatched claim support), D13 (stale/detached citations), and D16 (contradictory duplicates) belong to a separate future evidence-audit operation. They need a version-input read path that `page get --json` lacks. (Retires the draft's REQ-46/47 evidence-access requirements into that operation.)
- **D4 — High-false-positive classes are report-only in v1.** D04 (lists), D05 (headings), D14 (placeholders), D02 (delimiters): detectors may list candidates; the prompt instructs report-don't-rewrite.
- **D5 — Acceptance gate.** ≥20 runs on one targeted bail fixture reproducing the #1461 incident (clean pre-flight, one hidden defect); per-defect-class recall and precision scoring; a diff oracle where every hunk must map to a seeded defect; held-out fixtures; one long-page fixture with the defect late in the body; re-evaluation on model version change.
- **D6 — Repair and safety boundaries.** Unrepairable text stays in place as an unresolved finding — never deleted, never guessed. The renderer or sanitizer owns active-content safety; lint reports only, and "neutralize" is removed from D18 repairs. Pre-flight bracket auto-fixes move under CAS plus the reporting contract as a Phase 0 bug fix. Machine-readable log fields are deferred to v2. Selected pages run individually. (Retires REQ-28, the multi-page flattening fix.)

Adopted review answers folded into the requirements above: whole-wiki lint stays report-only (REQ-21, REQ-49); each selected page runs as its own run (REQ-23); the renderer's parser defines the dialect (REQ-46); page creation is prohibited and mechanically enforced (REQ-06, REQ-51); the gate tier is the lowest production lint tier (AC-15); no page metadata contract exists, so D19 is off; citation density belongs to strategy.

Retired requirements: REQ-19 (contradiction resolved by removal, D1), REQ-28 (multi-page flattening — superseded by per-page runs, D6), and the draft's REQ-46/47 (evidence-access path — moved to the evidence-audit operation, D3). The draft's open-questions section is closed by this list.
