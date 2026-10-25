# wikictl batch reads

Status: Design only. Pending operator review. This document does not implement the command.

Review status: Revised per two independent reviews (GLM, Claude Opus) on 2026-10-19.

## 1. Goals and non-goals

Add `wikictl batch get` for independent page and source Markdown reads. Reduce separate CLI executions without hiding missing items or truncating bodies.

A batch captures one bounded result from one database snapshot. Later executions read the saved result, not current database heads.

Keep `page get` and `source cat` unchanged. Their output, errors, and fallback rules remain compatibility contracts.

V1 does not add:

- GraphQL, SQL, filters, or a general query language.
- An interactive session or a database transaction that remains open between executions.
- Page or source bodies in `WIKI_STATE`.
- Binary bodies, base64 bodies, or raw source-byte fallback.
- A separate body-file export or file-escape mechanism.
- Workspace-overlay reads. V1 reads committed main heads only.
- Writes, source extraction, or changes to existing single-item commands.
- Convenience selector flags. The ordered JSON request file is the canonical input.

## 2. Recorded operator decisions

These four decisions define the design. Numeric limits remain provisional where stated.

1. **Saved-result batch.** One read transaction captures the full bounded result into the run's scratch directory. Every continuation serves that same copy. This gives batch-wide consistency across executions. Saved results expire, provisionally after one hour. Agents must start a new batch after writes when they need current state.
2. **Body chunks in the batch cursor.** Large bodies use explicit, valid-UTF-8 chunks. Each chunk carries its byte offset, total body bytes, and completion marker. V1 has no separate file-escape mechanism.
3. **Projection and response budget.** The default projection includes metadata, body, and version identity. Proposed response limits are 32 KiB by default, 128 KiB maximum, and about eight records per response. Validate these limits against provider output tools before implementation approval.
4. **Selectors and correlation.** Pages accept a title or ID. Sources accept an ID. Source-name support requires explicit per-item ambiguity results. Preserve duplicate requests. Use `request_index` to correlate every result with its input position.

## 3. Evidence and requirements

### 3.1 Research measurements

The completed investigation measured the Flower wiki. These are sample measurements, not product limits. This design does not repeat the measurement.

| Content | Count | Median body | p95 body | Maximum body | Above 32 KiB |
| --- | ---: | ---: | ---: | ---: | ---: |
| Pages | 115 | 8.2 KiB | Not reported | 44 KiB | Not reported |
| Current source Markdown heads | 256 | 38 KiB | 116 KiB | 141 KiB | 169 / 256 |
| Sources without a Markdown head | 55 / 311 | Not applicable | Not applicable | Not applicable | Not applicable |

KiB means 1,024 bytes. A typical source body exceeds the proposed default response budget. Chunk support is therefore required, not optional.

In one observed ingest run, all 66 `page get` calls used `--title`. They addressed 24 distinct titles. The run made 69 `wikictl` read executions. Title selectors and grouped reads match this observed use.

### 3.2 Requirements R1–R10

| ID | Requirement |
| --- | --- |
| R1 | Resolve all selectors and capture all projected values in one read transaction. Serve every continuation from that saved result. |
| R2 | Accept an ordered JSON request file. Preserve input order and duplicates with a zero-based `request_index`. |
| R3 | Use tagged page/source targets. Resolve pages by title or ID and sources by ID. Never guess between namespaces or ambiguous names. |
| R4 | Return explicit per-item `found`, `missing`, `ambiguous`, and `no_markdown` outcomes. Do not substitute raw source bytes. |
| R5 | Default to metadata, body, and version identity. A metadata-only projection must avoid body and blob loads. |
| R6 | Enforce the exact encoded response-byte cap. Split large bodies into complete UTF-8 sequences with explicit offsets and completion. |
| R7 | Bound request size, item count, capture bytes, saved-result storage, and lifetime. Reject excess work without a partial published batch. |
| R8 | Make cursors replayable. Bind them to the saved result, database selection, saved-result format, projection, limits, scratch context, and validated page position. |
| R9 | Use a read-only dispatch path. Keep database handles and transaction state private to the store. Preserve existing CLI contracts. |
| R10 | Teach agents to group independent reads, consume complete bodies before dependent rewrites, and start a new batch for post-write state. |

### 3.3 Current code constraints

Code anchors refer to the design baseline, `ee9a2143`. Re-verify all line anchors at implementation start. Use the named methods if later changes move the lines.

- `WikiReadService.asyncRead` exposes `WikiReadAccess`, not a database handle (`Sources/WikiFSCore/Store/WikiReadService.swift:122–135`).
- `WikiReadAccess` delegates individual calls to the store (`Sources/WikiFSCore/Store/WikiReadService.swift:36–54`). The private pool lends one store, not one transaction (`Sources/WikiFSCore/Store/WikiReadService.swift:197–206`).
- `GRDBWikiStore.getPage` opens its own `dbWriter.read` (`Sources/WikiFSCore/Store/GRDBWikiStore.swift:4718–4743`). Grouping existing facade calls does not give one snapshot.
- Same-actor coalescing changes a head version's `blob_hash` and `title` in place (`Sources/WikiFSCore/Store/GRDBWikiStore.swift:13129–13142`, `13179–13201`). The pair `(page_version_id, refs.generation)` pins content. Pages without a refs row use the `MAX(id)` fallback and a null generation, with weaker pinning.
- `source cat --markdown` falls back to raw bytes when no Markdown head exists (`Sources/WikiCtlCore/SourceCommand.swift:274–289`). Batch reads must not copy that rule.
- The relevant scratch-write rule is in `SandboxProfile.generate` (`Sources/WikiFSCore/Core/SandboxProfile.swift:138`), not `generateReadOnly`. Source export already uses atomic writes (`Sources/WikiCtlCore/SourceCommand.swift:294–320`).
- Job inspection bypasses the writable store path without migrations or checkpoints (`Sources/wikictl/main.swift:107–117`). That precedent is registry-only. Batch dispatch must also support explicit database paths through `WikiResolver.selection(wikiSelector:databasePath:)`.

The research calls this the `WikiReadPool` facade. In current code, `WikiReadPool` is private. The implementation must extend the public `WikiReadService` / `WikiReadAccess` boundary.

## 4. Command surface

```text
wikictl [--wiki <id-or-name> | --database-path <file>] batch get --scratch <absolute-path> --request-file <path>
wikictl [--wiki <id-or-name> | --database-path <file>] batch get --scratch <absolute-path> --cursor <opaque-token>
```

Exactly one of `--request-file` and `--cursor` is required. Both forms require `--scratch` and emit one JSON envelope. V1 stays file-only. Support for `--request-file -` is an open implementation option, not part of v1.

Resolve the database selection through `WikiResolver.selection(wikiSelector:databasePath:)`. Bind the saved result to the canonical database URL and the wiki ID when one exists. Explicit-database runs need no invented wiki ID. Unknown or ambiguous `--wiki` selectors fail before any capture. Continuations validate the same selection without opening the database.

The request file carries the projection and response limits. A cursor inherits those settings. Continuations cannot change selectors, projection, or budgets.

Canonicalize the required absolute scratch path with `realpath`. Neither cwd nor `WIKI_SCRATCH` is authoritative. Agents must copy the absolute path from RUN ENVIRONMENT. Standalone callers choose a writable root explicitly. Every continuation must pass the same canonical root.

`--request-file` must be absolute or resolve relative to `--scratch`, never cwd. Enforce the 256 KiB request-file cap before decoding.

## 5. Request and response envelopes

The examples define the proposed field contract. IDs and cursor text below are placeholders, not valid tokens. Implementation review must finalize exact field names and validation rules.

### 5.1 Request

```json
{
  "schema_version": 1,
  "projection": ["metadata", "body", "version"],
  "response_limits": {
    "max_bytes": 32768,
    "max_records": 8
  },
  "requests": [
    {"kind": "page", "selector": {"title": "Soil health"}},
    {"kind": "source", "selector": {"id": "<source-id>"}},
    {"kind": "page", "selector": {"id": "<page-id>"}},
    {"kind": "page", "selector": {"title": "Soil health"}}
  ]
}
```

Omitted projection and response limits use the defaults. `requests` is a nonempty ordered array. Each selector contains exactly one allowed field.

Page selectors accept `id` or `title`. Titles use existing case-insensitive matching, but duplicate matches return `ambiguous`. This deliberately differs from `resolveTitleToID`, which chooses the lowest ULID. The outcome includes `duplicate_title_count` and bounded candidate IDs, never candidate bodies. Writes to a duplicated title MUST target by ID.

Source selectors accept `id` in the required v1 surface. If v1 also accepts `name`, it must return explicit ambiguity outcomes. Source-name support is not required to ship v1.

Unknown kinds, fields, projection members, malformed IDs, and conflicting selectors are request errors. Validate the complete request before database work.

Internally, decode targets into tagged types with `PageID` and `SourceID`. Equal raw IDs in different namespaces remain different targets. Introduce `RawRepresentable` newtypes `BatchCursor` and `BatchID` at the parse boundary. Raw strings cross only the CLI edge.

`metadata` and `version` form the required base projection. `body` is optional. Thus the metadata-only form is `["metadata", "version"]`. V1 does not support arbitrary field lists.

### 5.2 Successful response

This example is illustrative. It shows part of a multi-response batch, not a complete result for the four requests.

```json
{
  "schema_version": 1,
  "batch_id": "<saved-result-id>",
  "wiki_id": "<wiki-id-or-null>",
  "captured_at": "2026-10-19T12:00:00.000Z",
  "expires_at": "2026-10-19T13:00:00.000Z",
  "projection": ["metadata", "body", "version"],
  "request_count": 4,
  "records": [
    {
      "request_index": 0,
      "kind": "page",
      "status": "found",
      "id": "<page-id>",
      "metadata": {"title": "Soil health", "slug": "soil-health"},
      "version": {
        "page_version_id": "<observed-head-id>",
        "ref_generation": 12,
        "body_hash": "<captured-body-hash>"
      },
      "body_chunk": {
        "text": "Soil",
        "byte_offset": 0,
        "total_bytes": 4,
        "complete": true
      }
    },
    {
      "request_index": 1,
      "kind": "source",
      "status": "no_markdown",
      "id": "<source-id>",
      "metadata": {"name": "Field notes.pdf"},
      "version": {"source_markdown_version_id": null}
    }
  ],
  "complete": false,
  "next_cursor": "<opaque-token>"
}
```

The top-level `complete` means all requested outcomes and body chunks have been returned. The final response has `complete: true` and `next_cursor: null`. Internally, `hasMore` is its inverse. No cursor is returned when `hasMore` is false, so first-response replay is impossible for a single-response batch.

A body chunk's `complete` applies only to that body's bytes. A response can finish one body while the batch still needs continuation.

Use RFC 3339 UTC timestamps with millisecond precision for `captured_at` and `expires_at` in both the manifest and envelopes.

Page metadata includes title, slug, and available creation/update timestamps. Source metadata includes name and available MIME and timestamp fields. These are captured values.

Page version identity includes the observed head ID, available ref generation, and captured body hash. Source identity includes the Markdown head ID and available generation/hash. Missing version identity uses explicit null fields, not invented IDs.

`body_hash` always hashes the complete canonical UTF-8 bytes that the command prints, before chunking or JSON escaping. These are the page Markdown bytes from `page get`, or the source Markdown bytes from `source cat --markdown` when a head exists. Do not normalize Unicode or line endings. If a stored hash is reported, name it `blob_hash`. It may differ from the computed `body_hash`.

Metadata-only responses omit `body_chunk` and `body_hash`. They select stored identity and optional `blob_hash` metadata without loading bodies or hashing their bytes. Do not call body-loading convenience methods for this projection.

Repeat identity and metadata on each body-chunk record. This lets callers correlate a continuation without retaining an earlier response's metadata.

A `missing` record carries the requested selector and no resolved ID. An `ambiguous` record carries bounded candidate IDs and a candidate count. Page-title collisions also carry `duplicate_title_count`. Never include candidate bodies.

If candidates exceed their cap, include `candidates_complete: false`. The agent must select an ID through a separate lookup, not guess from that subset.

Duplicates retain separate indexes even when they resolve to the same object. Their captured values must agree within the batch. Storage may share bytes internally.

### 5.3 Compare-and-swap writes

Returned `(page_version_id, ref_generation)` pairs are valid `--expect-head` values under the page-write CAS contract. A `missing` outcome is valid evidence for `--create-only`. Pass the expected head through the existing CLI representation of that pair.

Batch capture pairs the body and head identity in one transaction. This is stronger than `page get`, which reads the body and head in two separate transactions. The pair pins content when a refs row exists. A null generation from the `MAX(id)` fallback gives weaker pinning.

The five-second same-actor amend window remains a caveat. It can amend a version in place, so the version ID alone is insufficient. Batch does not strengthen or bypass the existing CAS checks. Stale expectations must fail under those checks. Start a new batch after writes when current state is needed.

The implementation PR must amend the ingest CAS rules wherever prompts specify supported read paths. It must explicitly allow batch evidence for `--expect-head` and `--create-only` without removing single-item reads.

## 6. Snapshot capture and saved-result lifecycle

### 6.1 One composed read

Add one typed batch-capture operation through `WikiReadAccess`. The store capture method must be `internal`, since the facade is in the same module. This leaves `StoreEmissionExhaustivenessTests`' public-function partition untouched. Classify any new public read-facade additions as READ.

The store must execute selector resolution, metadata, identity, and projected body reads inside one composed `dbWriter.read` closure. Use database-taking internal helpers, following the existing `…Locked(in db:)` pattern. Do not call public methods that start another `dbWriter.read`. Do not expose a connection, statement, or transaction handle through the facade.

Factor the store-internal pipeline into resolution and body-capture phases. A test-only initializer accepts an optional `betweenPhases` closure inside the same read transaction. Tests use this seam to commit a second-connection write after resolution and before body capture. All captured values must predate that commit. Production construction installs no callback.

Capture value results for the whole bounded request, not just the first response. Materialize projected body bytes before releasing the read transaction. Do not defer blob loads to continuation time. Metadata-only capture must avoid body/blob loads. Prove this with GRDB trace statement counting, including assertions that no blob-content or page-body column is selected.

The source Markdown-head query must detect a NULL blob join before applying `COALESCE`. A missing blob produces whole-command `corrupt_projected_data`, not `found` with an empty body. A real empty blob remains a valid empty body.

The composed capture pins the WAL read snapshot for its duration and delays checkpointing. The #332 stale-snapshot precedent makes prompt release important. Request, capture-byte, and duration caps bound the delay in practice. The provisional maximum capture duration is 30 seconds, with a cap-sized test assertion and measurement gate in §9.

A private temporary directory can receive bounded captured data before publication. Serialization and response rendering may follow the read closure, using only captured values. They must not revisit the database. Keep network, inference, and provider calls outside the transaction. Release the snapshot before response delivery.

The snapshot promise covers committed database state and captured projected values. It does not promise read-your-writes across batches or a workspace overlay.

### 6.2 Scratch for each caller

App-spawned agents, both chats and queue runs, receive timestamped per-run scratch:

```text
<Caches>/Self Driving Wiki-agent/<id>/runs/<ts>/
```

A later message, retry, or provider run gets a different scratch root. Fallback and forked contexts may also get a different root. Scratch context does not carry forward even though old directories remain on disk. Cross-message continuation is impossible by construction. Capture and fully consume each batch within one run.

Standalone `wikictl` uses the caller-provided `--scratch` root. Its useful continuation lifetime depends on that root remaining available and the fixed expiry. Neither cwd nor an environment variable selects it implicitly.

A cursor with a different scratch binding returns `batch_wrong_scratch`. A result past its fixed deadline returns `batch_expired`. Tests must distinguish these conditions. Missing data in the correct root returns `batch_unavailable`, never a recapture from current heads.

### 6.3 Location and atomic publication

Use `<scratch>/.wikictl/batches/<random-batch-id>/` under the canonical root. Keep the manifest, captured data, and pre-rendered response pages private to the command.

Use generated identifiers for path components. Never derive paths from titles, names, IDs supplied as paths, or cursor text.

1. Validate the request, database selection, scratch root, and capture caps.
2. Reserve storage under a per-root cross-process lock before creating a private temporary directory.
3. Capture all bounded values in one snapshot.
4. Fix the publication timestamp and expiry, then pre-render every response page from the captured values.
5. Write the pages and manifest with selection identity, saved-result format version, projection, limits, positions, and expiry.
6. Close the files and atomically publish the completed directory on the same filesystem.
7. Return the first prepared response only after publication succeeds.

Use owner-only permissions where supported. Reject symlinks and paths outside the canonical scratch root. Always publish, including single-response batches, for uniform behavior.

Aggregate storage accounting includes existing batches, active reservations, incomplete captures, manifests, and encoded response pages. Enforce the provisional 128 MiB per-root cap across processes. For app agents this is the per-run cap. A standalone root shares one aggregate cap. If the next capture cannot fit, return `batch_storage_limit` and publish no batch. Never evict an unexpired batch to make room.

If capture, rendering, or publication fails, remove its temporary files and release its reservation. Never return a cursor for an incomplete saved result. The command must not create, migrate, checkpoint, or mutate the wiki database.

### 6.4 Lifetime and cleanup

Proposed expiry is one hour from publication. Store the fixed deadline in the manifest. Continuation and replay do not extend it. Keep completed saved results until expiry so earlier cursors remain replayable.

Expiry is enforced on read only. Disk reclaim is not guaranteed. `AgentLauncher` retains run scratch for debugging and provides no normal teardown. Later runs do not sweep older run roots. Manual removal or cache eviction can remove saved results sooner, which limits availability.

On batch operations, sweep expired results and abandoned temporary captures only within the current scratch subtree. Bound cleanup work. Never follow symlinks or touch sibling runs. Command help must explain that standalone `<scratch>/.wikictl` trees require later batch operations in that same root for sweeping. If the caller explicitly chooses cwd as scratch, the same rule applies to `cwd/.wikictl`.

A temporary capture is abandoned only when its mtime age exceeds 10 minutes. This threshold is well beyond the provisional 30-second capture maximum. The sweeper must never touch younger temporaries or their active reservations. Coordinate storage accounting and sweeping through the per-root lock. An active process refreshes its lease while it renders and publishes.

A cleanup failure must produce a diagnostic, not corrupt an active result. Tests must hold process A's active temporary capture while process B sweeps, then assert A publishes successfully.

An expired or unavailable result instructs the caller to start a new batch. Never reconstruct it from current heads. After writes, agents start a new batch for current state even when an older cursor remains valid.

## 7. Cursor binding and validation

A cursor is opaque and replayable. Its logical payload is `(batch_id, page_index)`, not a query or a body offset. Pre-rendering fixes every response boundary at publication.

Use a strict-charset, unguessable random `BatchID` with no path separators. Encode `BatchCursor` tokens at a fixed length, including a fixed scratch-context fingerprint for wrong-root diagnostics. This context field is not an additional response position. Never put an absolute or relative filesystem path in a cursor.

No HMAC or authenticated-token requirement applies. `wikictl` and the agent share privileges, so a MAC key cannot be secret from the agent. Validate syntax, allowed identifiers, manifest bindings, saved-file integrity, and position instead. These checks protect against wrong-context use, path escape, and corruption. They are not an authorization boundary against the caller.

The manifest binds:

- The random batch identity and canonical scratch context.
- The canonical database URL plus wiki ID when one exists.
- The saved-result format version.
- The canonical projection and fixed response limits.
- The page count and each page's starting `request_index`, byte length, and integrity digest.
- The fixed `captured_at` and `expires_at` timestamps.

The validated response position is `(request_index, page_index)`. The token carries the global response `page_index`. The manifest supplies and validates its starting `request_index`, including repeated indexes for split bodies. There is no separate outcome-detail position or caller-supplied body offset.

Validate token size, strict syntax, scratch context, format support, selection bindings, expiry, and page bounds before output. Then validate the saved page's length and integrity digest. Resolve only generated allowed identifiers under the canonical scratch root. Reject symlinks and path escape.

Replay of a valid cursor returns the identical prepared response bytes and next cursor. Do not consume or advance mutable state on disk. Never echo cursor text in diagnostics. Log only a short fingerprint.

Continuations never read the database. Current-head changes and database replacement do not invalidate captured data. Do not bind continuations to captured database schema versions or attempt replacement detection. Wrong database selection, unsupported saved-result format, wrong scratch, expiry, and lost saved data remain explicit errors.

## 8. Pre-rendered pages, chunking, and exact output limits

Render every response page once before atomic publication. Fixed budgets, immutable captured values, and fixed-length cursor tokens make all response sizes knowable at that point. Exact-byte fitting never runs again during continuation.

Build one ordered stream of outcome records. Finish a found item's body before moving to the next request. A response page may contain multiple complete items and a final partial-body item.

Offsets count bytes in the original captured UTF-8 body, before JSON escaping. `total_bytes` always describes that complete body. Concatenate decoded `text` values in offset order to reconstruct the exact body.

Never split a UTF-8 scalar sequence. Chunks need not end at a line, Markdown block, or grapheme boundary. Do not normalize Unicode or line endings.

For an empty body, emit one chunk with empty text, offset zero, total zero, and `complete: true`. A nonempty partial chunk must make positive byte progress.

During pre-rendering, count the actual serialized UTF-8 response bytes. Include metadata, escaping, envelope fields, fixed-length cursor text, and the final newline. Raw body length alone cannot enforce this cap.

Reserve envelope and continuation space before selecting chunk bytes. Use deterministic sizing or encode-and-check with bounded adjustment at publication. Never cut serialized JSON after encoding. Store the final encoded response pages, including their next cursors and completion markers.

Stop when either the byte budget or record budget applies. A body-chunk record counts as one record. A record count target never overrides the byte cap.

If the envelope plus one minimal progress record cannot fit, fail with `response_budget_too_small`. Do not publish an empty response with a non-advancing cursor.

Exceptionally large metadata or selectors can also prevent a record from fitting. Apply validated field/capture bounds and return `record_too_large` when needed. Never silently truncate identity or body fields. A rendering failure prevents publication of the entire batch, not just its first response.

## 9. Provisional limits and validation

**All values below need implementation review. Response values specifically need provider-output-tool validation.** These values are not claims about current tool limits.

| Limit | Proposal | Validation needed |
| --- | ---: | --- |
| Default encoded response | 32 KiB | Provider output tool, escaping, envelope overhead, agent readability |
| Hard encoded response maximum | 128 KiB | Provider truncation and transport limits |
| Records per response | 8 | Mixed outcomes and large-body continuation behavior |
| Saved-result lifetime | About 1 hour | Run duration, replay needs, scratch cleanup |
| Request file bytes | 256 KiB | Real request sizes and parser memory |
| Requests per batch | 256 | Capture latency, duplicate behavior, title-heavy use |
| Captured result bytes | 32 MiB | Flower sample, larger wikis, transaction duration, memory |
| Saved-result bytes per run | 128 MiB | Concurrent batches, encoded pages, reservations, disk pressure, cleanup |
| Ambiguity candidates per item | 16 | Output cap and useful ID disambiguation |
| Maximum capture duration | 30 seconds | Cap-sized fixture, WAL checkpoint delay, hardware baseline |
| Abandoned temporary age | More than 10 minutes | Active capture/sweep race, lease renewal, crash recovery |

Reject values above hard bounds rather than silently clamping them. Define and validate a minimum response budget before release. Apply the capture-duration budget inside the composed read, with bounded query work and deadline checks. Exceeding it returns `batch_capture_timeout` and publishes no batch.

Captured-result accounting must include bodies and bounded metadata/outcomes, not only unique blob bytes. Disk accounting must include serialization overhead, encoded pages, and incomplete captures.

At the 32 KiB default, one median source head (38 KiB) costs two batch executions versus one unchanged `source cat` execution. Batch's execution-count win concentrates in grouped page reads. Do not claim a general source-heavy execution reduction at that default.

Provider validation must test real tool responses through supported providers. Test quotes, control characters, multilingual text, and worst-case JSON escaping near both response limits. Record whether current large `source cat` outputs arrive intact, rather than assuming truncation.

Decision rule: if provider validation shows that 128 KiB responses arrive intact, move the default to 128 KiB. This fits the measured p95 source head in one response, subject to measured envelope overhead. Operator decision 3 remains provisional until that evidence exists.

Measure capture duration, WAL snapshot duration, time to first response, rendering time, total executions, and complete-body recovery. Compare the same workload with separate `page get` / `source cat` calls. Assert the 30-second capture-duration budget at the item and byte caps on a documented hardware baseline. A failed assertion blocks approval of those caps.

## 10. Failure taxonomy

A valid captured batch can contain unsuccessful item outcomes. These are data, not command failures. They must not discard other items.

| Scope | Conditions | Behavior |
| --- | --- | --- |
| Per item: `found` | Target resolves and projected values exist | Return captured metadata, identity, and requested body chunks. |
| Per item: `missing` | No target matches a valid selector | Return its `request_index` and selector. Continue other items. |
| Per item: `ambiguous` | Multiple title/name matches | Return bounded candidate IDs and count. Include `duplicate_title_count` for page titles. Never choose one. |
| Per item: `no_markdown` | Source exists without a current Markdown head | Return source metadata and explicit absent Markdown identity. Never load raw bytes. |
| Usage | Missing options, conflicting command inputs, parser failures | Keep plain `wikictl: …` stderr and exit 2 before command code runs. |
| Whole command: invalid request | Bad JSON/schema, invalid selectors, unknown fields | Exit 1 before capture. Publish no saved result. |
| Whole command: limits | Request/capture/storage cap, inadequate response budget, unrepresentable record, capture timeout | Exit 1 with the named limit. Use `batch_storage_limit` or `batch_capture_timeout` where applicable. Never publish a partial capture. |
| Whole command: database | Wiki resolution/access failure, unsupported database schema, query failure, `corrupt_projected_data` | Exit 1. Do not disguise database errors as missing items. |
| Whole command: saved result | Scratch unavailable, publication failure, corrupt or incomplete saved data | Exit 1. Do not return partial stdout. |
| Whole command: cursor | Malformed token, wrong selection, unsupported saved-result format, invalid position, path escape | Exit 1. Return no item data. |
| Whole command: wrong scratch | Cursor belongs to another canonical root | Return `batch_wrong_scratch`. Do not report expiry. |
| Whole command: unavailable batch | Expired result or missing saved data in the correct root | Return `batch_expired` or `batch_unavailable` respectively. Instruct the agent to start a new batch. |

Exit codes are 0 for success, including mixed item outcomes, 1 for command failure, and 2 for usage. Exit 3 remains reserved for CAS. Build and validate the complete response before writing stdout.

Command-stage failures use one bounded JSON diagnostic on stderr and no stdout. This rule does not apply to parser/usage errors.

```json
{
  "schema_version": 1,
  "error": {
    "code": "batch_expired",
    "message": "The saved result expired. Start a new batch.",
    "action": "start_new_batch"
  }
}
```

Use stable error codes. Do not expose raw paths, body content, cursor text, or database internals in diagnostics. Log only a short cursor fingerprint. A failed continuation does not silently create a replacement batch.

## 11. Prompt-teaching plan

Change prompts only in the implementation PR. This design PR changes no prompt source or generated prompt resource.

Update the `wikictl` command reference through the command-spec table in `Sources/WikiCtlCore/CLIReference.swift`. Add routing, required scratch options, request-path rules, help, and the cleanup availability warning.

The implementation PR must update all nine prompt files below. Keep single-item instructions for isolated reads and preserve `source cat`'s existing behavior.

| Prompt under `prompts/` | Batch teaching change | Single-item instruction that stays |
| --- | --- | --- |
| `system-prompt-default.md` | Group independent reads, copy `--scratch` from RUN ENVIRONMENT, consume all continuations. | Use `page get` or `source cat` for an isolated read. |
| `ingest-executor.md` | Batch known page-title reads and source Markdown reads. Accept batch CAS evidence and require complete bodies before dependent writes. | Allow `page get --json` for one page and `source cat --markdown` for one source. |
| `ingest-curator-task.md` | Group independent curation reads and refresh after writes. | Keep targeted single-page inspection when the next read depends on an earlier result. |
| `ingest-single-task.md` | Group source/context reads and handle `no_markdown` explicitly. | Keep a single source read and dependent page lookup available. |
| `ingest-write-rule.md` | Accept batch head pairs for `--expect-head` and `missing` for `--create-only`. Require ID writes for duplicated titles. | Keep `page get --json` evidence and existing CAS failure handling. |
| `chat.md` | Group independent context reads and finish a batch within the current run. | Keep single-item reads for follow-up questions about one object. |
| `query-task.md` | Batch independent evidence reads and consume complete bodies before answering. | Keep targeted reads discovered from previous evidence. |
| `lint-page-task.md` | Group independent page/context reads without treating an old batch as post-write state. | Keep single-page lint inspection. |
| `wiki-tree-render.md` | Teach grouping of independent reads selected from the tree, with explicit correlation and outcomes. | Keep individual `page get` / `source cat` lookup examples for one target. |

Teach this sequence:

1. Group independent page and source Markdown reads in one ordered request file.
2. Use page titles when known. Use source IDs rather than guessed names.
3. Copy the absolute scratch path from RUN ENVIRONMENT into every command.
4. Run all continuations of a batch from the same working directory within the same run.
5. Follow `next_cursor` until the needed bodies have `complete: true`.
6. Consume all chunks of each body before a rewrite that depends on that body.
7. Handle missing, ambiguous, and no-Markdown outcomes explicitly. Target duplicated titles by ID for writes.
8. Use captured head pairs or missing outcomes as CAS evidence under §5.3.
9. After writes, start a new batch when subsequent work needs current state.
10. If a saved result expires, disappears, or belongs to another scratch context, start a new batch.

The same-working-directory instruction is run discipline, not scratch discovery. Explicit `--scratch` remains authoritative even if a tool changes cwd.

Include one mixed request example and one multi-response body example in the command help/reference. Explain both completion markers and `request_index`.

After prompt edits, run `make prompts` and commit the synchronized resource copies. Check R10 specifically against the ingest executor flow, including grouped title reads, CAS evidence, complete-body use, and post-write refresh.

## 12. Test plan

Implement these tests with the feature. This document adds no test code.

| Area | Required cases |
| --- | --- |
| Request validation | Ordered JSON, defaults, metadata-only form, unknown fields, invalid IDs, conflicting selectors, mutually exclusive inputs, caps, required absolute `--scratch`, request paths relative to scratch rather than cwd. `unknownOrAmbiguousWikiFailsBeforeCapture` proves no capture begins for either selector failure. |
| Database selection | `registryAndExplicitDatabaseSelections` covers `--wiki` and `--database-path`, canonical URL binding, and absent wiki ID for explicit paths. |
| Mixed outcomes | Found pages/sources, missing targets, ambiguous selectors, source without Markdown. Verify no raw-byte fallback. `duplicateTitleCollisionRequiresID` checks deliberate divergence from lowest-ULID resolution, count, bounded candidate IDs, and ID-targeted writes. |
| Correlation | Duplicates retain indexes and order. A page and source with the same raw ID remain distinct. |
| Projection and integrity | `metadataOnlyAvoidsBlobLoads` uses GRDB trace statement counts and selected-column checks. Default capture pairs canonical body bytes and identity. `missingMarkdownBlobFailsCapture` distinguishes a NULL join from a real empty blob. Hash tests distinguish `body_hash` from `blob_hash`. |
| Snapshot | `snapshotCaptureBetweenPhases` uses the test-only initializer's `betweenPhases` seam. A second connection commits after resolution, before body capture. All captured metadata, head pairs, and body bytes must predate that commit. This is the single-snapshot acceptance criterion. |
| CAS | Captured head pairs support `--expect-head`. Missing evidence supports `--create-only`. Cover stale expectations, five-second same-actor amendment, and null-generation fallback limits. |
| Continuation | Edit, delete, rename, replace heads, and trigger same-actor head coalescing between executions. Assert no skipped or repeated bytes/items. Database replacement does not change prepared responses. |
| Chunk bytes | Empty and large bodies, multilingual scalars, combining text, emoji, quotes, backslashes, control characters, CRLF, exact-cap boundaries. Reconstruct byte-identical bodies. |
| Budgets | Count encoded JSON and newline bytes at publication. Test minimum progress, envelope overflow, metadata overflow, record count, hard limits, and no silent truncation. `captureDurationAtCaps` asserts the 30-second budget at item/byte caps. `captureTimeoutPublishesNothing` covers the named failure. |
| Storage cap | `aggregateStorageCapPublishesNothing` pre-fills the root near 128 MiB, requests another capture, and asserts `batch_storage_limit` with no published batch. Include concurrent reservations and encoded-page overhead. |
| Cursor | `preparedPageReplayIsByteIdentical` checks records, encoding, and next cursor. Reject malformed syntax, wrong selection, format mismatch, invalid page bounds, corruption, and path traversal. Single-response publication returns no cursor. Never echo a cursor in diagnostics. |
| Lifecycle | `captureSurvivesConcurrentSweep` holds process A's active temporary while B sweeps, then proves A publishes. Test the 10-minute abandonment threshold, atomic publication, capture/disk failures, symlink rejection, and concurrent replay. `wrongScratchDiffersFromExpiry` checks `batch_wrong_scratch` versus `batch_expired`. Cover unavailable data and retained earlier-run scratch without claiming teardown. |
| Read-only behavior | No database creation, migration, checkpoint, write profile, or writable-handle escape. Continuations serve prepared files without database reads. Keep the internal capture outside the public emission partition. Classify any new public reads as READ. |
| Compatibility | Use `WikiCtlRunner` behavior tests, `CLIReference` parser/help tests, and boundary fixtures. Existing commands' outputs remain unchanged. Expect one new family row in the top-level `--help` snapshot. There is no golden-file CLI fixture harness. Verify plain usage stderr/exit 2 and command JSON stderr/exit 1. |
| Agent use | Provider-output-tool validation and a live grouped-read ingest task. Verify complete-body use, batch CAS evidence, same-run scratch use, and a new batch after writes. Compare page-heavy and source-heavy execution counts. |

Use controlled synchronization for concurrent-update tests, not timing guesses. Use Swift Testing with bounded asynchronous waits for process coordination. Distinguish infrastructure tests from live agent behavior evidence.

## 13. Implementation review and gates

Before implementation, confirm:

- Response defaults and hard limits with provider-output-tool evidence, including the 128 KiB decision rule and source-heavy baseline.
- Capture, request, storage, minimum response, field bounds, and the capture-duration budget at the caps.
- The internal typed composed-read API, deterministic `betweenPhases` test seam, and GRDB trace proof for metadata-only capture.
- Canonical database selection for both selector forms and fixed-length cursors bound to saved-result manifests, not live database replacement/schema checks.
- Whether source-name selectors ship in v1. If they do, require explicit ambiguity results.
- Atomic publication of pre-rendered pages, cross-process storage reservations, the capture-versus-sweep race, and read-only expiry without guaranteed disk reclaim.
- All nine prompt updates, batch CAS evidence, and deliberate duplicate-title semantics.
- Re-verified code anchors at implementation start.

The implementation PR must pass `make build`, `make test`, and the new batch tests in §12. Required named acceptance tests include:

- `snapshotCaptureBetweenPhases` and `metadataOnlyAvoidsBlobLoads` for the snapshot seam and projection.
- `captureSurvivesConcurrentSweep` for the active capture-versus-sweep race.
- `aggregateStorageCapPublishesNothing` for the 128 MiB aggregate cap.
- `unknownOrAmbiguousWikiFailsBeforeCapture` and `registryAndExplicitDatabaseSelections` for selector handling.
- `captureDurationAtCaps` and `captureTimeoutPublishesNothing` for the capture-duration budget.
- `wrongScratchDiffersFromExpiry`, `preparedPageReplayIsByteIdentical`, `duplicateTitleCollisionRequiresID`, and `missingMarkdownBlobFailsCapture` for the remaining reviewed failure paths.

Preserve existing-command outputs through `WikiCtlRunner` behavior tests, `CLIReference` parser/help tests, and boundary fixtures. Update only the expected top-level help family row. Run `make prompts` when the implementation PR changes prompts.

This design PR requires both `make build` and the full `make test` suite. Neither command proves the proposed feature works because this PR implements no feature.
