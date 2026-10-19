# wikictl batch reads

Status: Design only. Pending operator review. This document does not implement the command.

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
| R8 | Make cursors replayable. Bind them to the saved result, wiki/database identity, schema versions, projection, and position. |
| R9 | Use a read-only dispatch path. Keep database handles and transaction state private to the store. Preserve existing CLI contracts. |
| R10 | Teach agents to group independent reads, consume complete bodies before dependent rewrites, and start a new batch for post-write state. |

### 3.3 Current code constraints

Code anchors refer to the design baseline, `ee9a2143`. Reviewers should use the named methods if later changes move the lines.

- `WikiReadService.asyncRead` exposes `WikiReadAccess`, not a database handle (`Sources/WikiFSCore/Store/WikiReadService.swift:122–135`).
- `WikiReadAccess` delegates individual calls to the store (`Sources/WikiFSCore/Store/WikiReadService.swift:36–54`). The private pool lends one store, not one transaction (`Sources/WikiFSCore/Store/WikiReadService.swift:197–206`).
- `GRDBWikiStore.getPage` opens its own `dbWriter.read` (`Sources/WikiFSCore/Store/GRDBWikiStore.swift:4718–4743`). Grouping existing facade calls does not give one snapshot.
- Same-actor coalescing changes a head version's `blob_hash` and `title` in place (`Sources/WikiFSCore/Store/GRDBWikiStore.swift:13129–13142`, `13179–13201`). A page-version ID alone cannot pin captured content.
- `source cat --markdown` falls back to raw bytes when no Markdown head exists (`Sources/WikiCtlCore/SourceCommand.swift:274–289`). Batch reads must not copy that rule.
- The sandbox permits scratch writes, including in its read-only profile (`Sources/WikiFSCore/Core/SandboxProfile.swift:198–206`). Source export already uses atomic writes (`Sources/WikiCtlCore/SourceCommand.swift:294–320`).
- Job inspection bypasses the writable store path without migrations or checkpoints (`Sources/wikictl/main.swift:107–117`). Batch dispatch should follow that precedent.

The research calls this the `WikiReadPool` facade. In current code, `WikiReadPool` is private. The implementation must extend the public `WikiReadService` / `WikiReadAccess` boundary.

## 4. Command surface

```text
wikictl [--wiki <id-or-name>] batch get --request-file <path>
wikictl [--wiki <id-or-name>] batch get --cursor <opaque-token>
```

Exactly one of `--request-file` and `--cursor` is required. Both forms emit one JSON envelope. V1 does not accept a request on standard input.

The normal wiki selector resolves one database before capture. A continuation must resolve the same database identity. It cannot silently switch wikis.

The request file carries the projection and response limits. A cursor inherits those settings. Continuations cannot change selectors, projection, or budgets.

Use the run's existing scratch working directory for request files and saved results. A standalone caller must use a writable scratch working directory. Continuations must use the same scratch root.

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

Page selectors accept `id` or `title`. Titles use existing page-title matching rules, but ambiguous matches must never select an arbitrary row.

Source selectors accept `id` in the required v1 surface. If v1 also accepts `name`, it must return explicit ambiguity outcomes. Source-name support is not required to ship v1.

Unknown kinds, fields, projection members, malformed IDs, and conflicting selectors are request errors. Validate the complete request before database work.

Internally, decode targets into tagged types with `PageID` and `SourceID`. Equal raw IDs in different namespaces remain different targets.

`metadata` and `version` form the required base projection. `body` is optional. Thus the metadata-only form is `["metadata", "version"]`. V1 does not support arbitrary field lists.

### 5.2 Successful response

```json
{
  "schema_version": 1,
  "batch_id": "<saved-result-id>",
  "wiki_id": "<wiki-id>",
  "captured_at": "<UTC timestamp>",
  "expires_at": "<UTC timestamp>",
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

The top-level `complete` means all requested outcomes and body chunks have been returned. The final response has `complete: true` and `next_cursor: null`.

A body chunk's `complete` applies only to that body's bytes. A response can finish one body while the batch still needs continuation.

Page metadata includes title, slug, and available creation/update timestamps. Source metadata includes name and available MIME and timestamp fields. These are captured values.

Page version identity includes the observed head ID, available ref generation, and captured body hash. Source identity includes the Markdown head ID and available generation/hash. Missing version identity uses explicit null fields, not invented IDs.

Metadata-only responses omit `body_chunk`. They select stored identity/hash metadata without loading bodies or hashing their bytes. Do not call body-loading convenience methods for this projection.

Repeat identity and metadata on each body-chunk record. This lets callers correlate a continuation without retaining an earlier response's metadata.

A `missing` record carries the requested selector and no resolved ID. An `ambiguous` record carries bounded candidate metadata and a candidate count. Never include candidate bodies.

If candidates exceed their cap, include `candidates_complete: false`. The agent must select an ID through a separate lookup, not guess from that subset.

Duplicates retain separate indexes even when they resolve to the same object. Their captured values must agree within the batch. Storage may share bytes internally.

## 6. Snapshot capture and saved-result lifecycle

### 6.1 One composed read

Add one typed batch-capture operation through the read facade. The store must execute all resolution, metadata, identity, and projected body reads inside one composed `dbWriter.read` closure.

Use database-taking internal helpers inside that closure. Do not call public methods that start another `dbWriter.read`. Do not expose a connection, statement, or transaction handle through the facade.

Capture value results for the whole bounded request, not just the first response. Materialize body bytes before releasing the read transaction. Do not defer blob loads to continuation time.

Write those captured values to the saved result in scratch. A private temporary file can receive bounded captured data before publication. No continuation can see it until capture succeeds.

The implementation may serialize captured values after the read closure returns. Serialization must use only captured values. It must not revisit the database.

Keep network, inference, and provider calls outside the transaction. Release the snapshot before response delivery. Separate executions never hold a database transaction open.

The snapshot promise covers committed database state and the captured projected values. It does not promise read-your-writes across batches or a workspace overlay.

### 6.2 Location and atomic publication

Proposed location: `<run-scratch>/.wikictl/batches/<random-batch-id>/`. Keep the manifest and saved data private to the command.

Use generated identifiers for path components. Never derive paths from titles, names, IDs supplied as paths, or cursor text.

1. Validate the request and capture caps.
2. Create a private temporary saved-result directory under the same scratch root.
3. Capture all bounded values in one snapshot.
4. Write data and a manifest with identity, schema versions, projection, limits, and expiry.
5. Close the files and atomically publish the completed directory or manifest.
6. Return the first response only after publication succeeds.

Use owner-only permissions where supported. Reject symlinks and paths outside the canonical scratch root. Publish on the same filesystem to preserve atomic rename behavior.

If capture, serialization, or publication fails, remove temporary files. Never return a cursor for an incomplete saved result. The command must not create, migrate, checkpoint, or mutate the wiki database.

### 6.3 Lifetime and cleanup

Proposed expiry is one hour from publication. Store the fixed deadline in the manifest. Continuation and replay do not extend it.

Keep completed saved results until expiry so earlier cursors remain replayable. Run scratch deletion may remove them sooner. This is an explicit availability limit.

On batch operations, remove expired saved results and abandoned temporary captures within the owned scratch subtree. Run teardown can remove the entire subtree.

Cleanup must not follow symlinks or touch another run's scratch. Bound cleanup work. A cleanup failure must produce a diagnostic, not corrupt an active result.

An expired or missing result returns a command error that says to start a new batch. Never reconstruct it from current heads. After writes, agents start a new batch for current state even when an older cursor remains valid.

## 7. Cursor binding and validation

A cursor is opaque and replayable. It identifies a saved result and an absolute response position, not a database query.

Bind the cursor to:

- The random saved-result identity and integrity identity.
- The wiki ID and resolved database identity, including detection of database replacement.
- The cursor format, saved-result format, response schema, and captured database schema versions.
- The canonical projection and fixed response limits.
- The position: `request_index`, body byte offset, and any bounded outcome-detail position.
- The fixed expiry and owning scratch context.

Use an authenticated token or an unguessable server-side token map in the saved manifest. Encoding fields alone does not protect their integrity. Choose one mechanism during implementation review.

Never put an absolute or relative filesystem path in a cursor. Resolve an allowed identifier under the known scratch root.

Validate token size, syntax, integrity, schema support, identity bindings, expiry, and position before reading result data. Validate UTF-8 boundaries and saved-file integrity before output.

A cursor for the same valid position must return the same records and next cursor. Use deterministic encoding and fixed budgets for replay. Do not consume or advance mutable state on disk.

Changes to current heads do not invalidate the saved data. Database replacement, a wrong wiki, unsupported schema, or lost scratch state produces an explicit error. Do not reopen the writable store to validate a continuation.

## 8. Chunking and exact output limits

Use one ordered stream of outcome records. Finish a found item's body before moving to the next request. A response may contain multiple complete items and a final partial-body item.

Offsets count bytes in the original captured UTF-8 body, before JSON escaping. `total_bytes` always describes that complete body. Concatenate decoded `text` values in offset order to reconstruct the exact body.

Never split a UTF-8 scalar sequence. Chunks need not end at a line, Markdown block, or grapheme boundary. Do not normalize Unicode or line endings.

For an empty body, emit one chunk with empty text, offset zero, total zero, and `complete: true`. A nonempty partial chunk must make positive byte progress.

Count the actual serialized UTF-8 response bytes. Include metadata, escaping, envelope fields, cursor text, and the final newline. Raw body length alone cannot enforce this cap.

Reserve envelope and continuation space before selecting chunk bytes. Use deterministic sizing or encode-and-check with bounded adjustment. Never cut the serialized JSON string after encoding.

Stop when either the byte budget or record budget applies. A body-chunk record counts as one record. A record count target never overrides the byte cap.

If the envelope plus one minimal progress record cannot fit, fail with `response_budget_too_small`. Do not return an empty response with a non-advancing cursor.

Exceptionally large metadata or selectors can also prevent a record from fitting. Apply validated field/capture bounds and return `record_too_large` when needed. Never silently truncate identity or body fields.

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
| Saved-result bytes per run | 128 MiB | Concurrent batches, disk pressure, cleanup |
| Ambiguity candidates per item | 16 | Output cap and useful ID disambiguation |

Reject values above hard bounds rather than silently clamping them. Define and validate a minimum response budget before release.

Captured-result accounting must include bodies and bounded metadata/outcomes, not only unique blob bytes. Disk accounting must include serialization overhead and incomplete captures.

Provider validation must test real tool responses through supported providers. Test quotes, control characters, multilingual text, and worst-case JSON escaping near both response limits.

Measure time to capture, time to first response, total executions, and complete-body recovery. Compare the same workload with separate `page get` / `source cat` calls.

## 10. Failure taxonomy

A valid captured batch can contain unsuccessful item outcomes. These are data, not command failures. They must not discard other items.

| Scope | Conditions | Behavior |
| --- | --- | --- |
| Per item: `found` | Target resolves and projected values exist | Return captured metadata, identity, and requested body chunks. |
| Per item: `missing` | No target matches a valid selector | Return its `request_index` and selector. Continue other items. |
| Per item: `ambiguous` | Multiple title/name matches | Return bounded candidates and count. Never choose one. |
| Per item: `no_markdown` | Source exists without a current Markdown head | Return source metadata and explicit absent Markdown identity. Never load raw bytes. |
| Whole command: invalid request | Bad JSON/schema, invalid selectors, unknown fields, conflicting command inputs | Exit nonzero before capture. Publish no saved result. |
| Whole command: limits | Request/capture/storage cap, inadequate response budget, unrepresentable record | Exit nonzero with the named limit. Never publish a partial capture. |
| Whole command: database | Wiki resolution/access failure, unsupported database schema, query failure, corrupt projected data | Exit nonzero. Do not disguise database errors as missing items. |
| Whole command: saved result | Scratch unavailable, atomic publication failure, corrupt or incomplete saved data | Exit nonzero. Do not return partial stdout. |
| Whole command: cursor | Malformed/tampered token, wrong wiki/database, unsupported schema, invalid position, path escape | Exit nonzero. Return no item data. |
| Whole command: unavailable batch | Expired or missing saved result | Exit nonzero. Instruct the agent to start a new batch. |

Use exit zero for a valid envelope, including mixed item outcomes. Use nonzero for whole-command errors. Build the complete response before writing stdout.

Proposed error output uses one JSON diagnostic on stderr and no stdout. Keep diagnostics within a small fixed bound.

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

Use stable error codes. Do not expose raw paths, body content, or database internals in diagnostics. A failed continuation does not silently create a replacement batch.

## 11. Prompt-teaching plan

Change prompts only in the implementation PR. This design PR changes no prompt source or generated prompt resource.

Update `prompts/system-prompt-default.md` and the `wikictl` command reference. `Sources/WikiCtlCore/CLIReference.swift:16–31` defines command routing, options, and help from one table.

Teach this sequence:

1. Group independent page and source Markdown reads in one ordered request file.
2. Use page titles when known. Use source IDs rather than guessed names.
3. Follow `next_cursor` until the needed bodies have `complete: true`.
4. Consume all chunks of each body before a rewrite that depends on that body.
5. Handle missing, ambiguous, and no-Markdown outcomes explicitly.
6. After writes, start a new batch when subsequent work needs current state.
7. If a saved result expires or disappears, start a new batch. Do not treat a new batch as the old snapshot.

Include one mixed request example and one multi-response body example in the command help/reference. Explain both completion markers and `request_index`.

After prompt edits, run `make prompts` and commit the synchronized resource copies. Keep existing single-item guidance available for isolated reads.

## 12. Test plan

Implement these tests with the feature. This document adds no test code.

| Area | Required cases |
| --- | --- |
| Request validation | Ordered JSON, defaults, metadata-only form, unknown fields, invalid IDs, conflicting selectors, mutually exclusive command inputs, caps. |
| Mixed outcomes | Found pages/sources, missing targets, ambiguous selectors, source without Markdown. Verify no raw-byte fallback. |
| Correlation | Duplicates retain indexes and order. A page and source with the same raw ID remain distinct. |
| Projection | Metadata-only capture loads no body/blob. Default capture includes body and observed version identity from the same snapshot. |
| Snapshot | Commit concurrent updates during capture. Assert all captured values reflect one database snapshot, not separate facade calls. |
| Continuation | Edit, delete, rename, replace heads, and trigger same-actor head coalescing between executions. Assert no skipped or repeated bytes/items. |
| Chunk bytes | Empty and large bodies, multilingual scalars, combining text, emoji, quotes, backslashes, control characters, CRLF, exact-cap boundaries. Reconstruct byte-identical bodies. |
| Budgets | Count encoded JSON and newline bytes. Test minimum progress, envelope overflow, metadata overflow, record count, hard limits, and no silent truncation. |
| Cursor | Replay produces the same response. Reject expiry, missing files, wrong wiki, replaced database, tampering, schema mismatch, invalid offsets, and path traversal. |
| Lifecycle | Atomic publication, capture failure, disk failure, cleanup, abandoned temporary files, symlink rejection, concurrent replay, and run teardown. |
| Read-only behavior | No database creation, migration, checkpoint, write profile, or writable-handle escape. Continuations do not reload bodies from the database. |
| Compatibility | Existing `page get`, `source cat`, source export, parser/help, and CLI fixtures remain unchanged. |
| Agent use | Provider-output-tool validation and a live grouped-read task. Verify complete-body use before rewrites and a new batch after writes. |

Use controlled synchronization for concurrent-update tests, not timing guesses. Distinguish infrastructure tests from live agent behavior evidence.

## 13. Implementation review and gates

Before implementation, confirm:

- Response defaults and hard limits with provider-output-tool evidence.
- Capture, request, storage, minimum response, and field bounds.
- The typed composed-read API, database-replacement identity, and cursor-integrity mechanism.
- Whether source-name selectors ship in v1. If they do, require explicit ambiguity results.
- Atomic publication and bounded cleanup behavior for concurrent CLI processes.

The implementation PR must pass `make build`, `make test`, new batch tests, and unchanged CLI fixtures. Run `make prompts` when that PR changes prompts.

This design PR requires `make build`. Repository instructions also require `make test` before a PR. Neither command proves the proposed feature works because this PR implements no feature.
