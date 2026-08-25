# Issue #940: OKF trust, lifecycle, and freshness

## Scope

This feature adds durable OKF v0.2 metadata to exact concept versions.

The supported concepts are:

- a page version, identified by `PageVersionID`
- a processed source Markdown version, identified by `SourceMarkdownVersionID`

Raw source files remain evidence resources. They do not get OKF frontmatter.

This feature extends the producer from [issue #927](issue-927-okf-v0-2.md). It does not change the existing `generated` or `sources` semantics.

## Normative status vocabulary

OKF v0.2 defines these status values:

- `draft`
- `stable`
- `deprecated`

The store rejects `active`, `archived`, and all other values. The projection emits `status` only after an explicit write.

An absent status is not an authored `stable` claim. The inspector shows **Not explicitly set** for this state.

## Exact-version model

All metadata belongs to one immutable concept version. Metadata does not belong to the mutable page or source row.

A new page version starts without metadata. A new processed source Markdown version also starts without metadata.

The store does not copy status, freshness, or verification records from a parent version. This rule prevents old trust claims from following changed content.

Separate page and source tables enforce the identifier boundary. A `PageVersionID` cannot select a source Markdown metadata API.

## Schema v52

Schema v52 adds four tables:

- `page_okf_metadata`
- `source_markdown_okf_metadata`
- `page_okf_verifications`
- `source_markdown_okf_verifications`

The metadata tables store an optional status, an optional freshness policy, a resolved deadline, and a projection revision.

The verification tables store immutable verification records. A correction adds tombstone fields to the original record.

The migration is additive. It does not create metadata for historical versions.

Foreign keys delete metadata when the exact concept version is deleted. The activity vacuum retains activities referenced by verification and correction records.

## Verification and PROV mapping

A verification write creates these records in one transaction:

1. The store resolves or creates a verifier agent.
2. The store creates an activity with kind `verify`.
3. The store creates the target-specific verification record.
4. The store updates the target projection revision.
5. The store resolves optional verification-anchored freshness.

The activity timestamps match the verification timestamp.

Verifier identities use one of these forms:

- `human:<id>`
- `process:<id>`
- `<producer>/<version>`

The CLI rejects empty or malformed components. The older permissive producer mapping remains unchanged for issue #927 output.

## Verification basis payload

The verification basis uses JSON payload version 1. The payload contains:

- a closed basis kind
- typed evidence references
- an optional note

Supported basis kinds are:

- `human-review`
- `source-checked`
- `external-revalidation`

Evidence uses tagged values:

- `source:<SourceID>`
- `url:<absolute HTTP or HTTPS URL>`

The encoder sorts JSON keys. The decoder rejects unsupported payload versions.

## Correction behavior

A correction never deletes the verification record.

The correction transaction creates an activity with kind `correct-verification`. It then adds the correction timestamp, activity ID, and optional reason to the verification.

A verification can be corrected once. A second correction fails without a write or event.

Active projection reads exclude corrected verifications. Audit reads include them.

If freshness is anchored to the corrected verification, the correction clears the policy and deadline.

## Freshness resolution

The store persists an absolute UTC `stale_after` timestamp. Projection reads never recalculate this value.

A fixed policy stores its supplied timestamp.

A generated TTL uses the exact concept version creation timestamp. The store adds the positive whole-second TTL once during the write.

A verification TTL uses an active verification on the same exact version. A combined verification command can anchor the TTL to the new verification in the same transaction.

The store rejects missing and foreign verification anchors. A concept is stale when the current time is equal to or later than its deadline.

## Projection and invalidation

Projected frontmatter uses this stable order:

1. `type`
2. `title`
3. `generated`
4. `verified`
5. `status`
6. `stale_after`
7. `sources`

`verified` is always a YAML list. Records sort by verification timestamp and verification ID.

The projection omits empty optional field families. A concept without v52 metadata keeps the issue #927 bytes and leaf version.

Each successful metadata mutation increments one target-local projection revision. Both aliases use this revision in their content version.

The whole-wiki change token appends the sum of these revisions as its final field. All older field positions remain unchanged.

Raw source files and unrelated concepts do not use the changed target revision.

Corrupt payload JSON fails closed. The store throws an explicit metadata error. File Provider does not return partial concept bytes.

## CLI grammar

Page commands use this prefix:

```text
wikictl page okf <operation> --version <page-version-id>
```

Source commands use this prefix:

```text
wikictl source okf <operation> --version <source-markdown-version-id>
```

Supported operations are:

```text
inspect [--json]
status (--status draft|stable|deprecated | --clear)
freshness (--stale-after <ISO-8601> | --ttl <duration> [--anchor generated|verification] [--verification <id>] | --clear)
verify --by <actor> [--at <ISO-8601>] --basis <kind> [--evidence <typed-value> ...] [--note <text>] [--ttl <duration>]
correct --verification <id> --by <actor> [--at <ISO-8601>] [--reason <text>]
```

Durations require a unit suffix. Supported suffixes are `s`, `m`, `h`, and `d`.

Verification and correction timestamps default to command time when `--at` is absent. Successful mutations request one post-commit process notification.

Inspection does not request a notification. Invalid input does not write or request a notification.

## Inspector scope

The existing metadata inspector shows the exact active version metadata. It uses the read service for file-backed sessions.

The inspector shows:

- explicit lifecycle status
- derived trust tier
- verification actor and timestamp
- verification basis, evidence, and note
- absolute freshness deadline
- current fresh or stale state

The inspector is read-only. It uses text for all state, so color is not the only signal.

Editable controls remain out of scope. Users author metadata with `wikictl`.

## Prohibited inference

The system does not infer verification from source presence, extraction origin, timestamps, or author identity.

The system does not calculate credibility scores. It does not emit attested computation fields.

The migration does not fabricate historical status, freshness, or verification claims.

## Related records

- [Issue #927 OKF v0.2 producer](issue-927-okf-v0-2.md)
- [Page provenance](page-provenance.md)
- [wikictl author provenance](wikictl-author-provenance.md)
- [Issue #940](https://github.com/tqbf/selfdrivingwiki/issues/940)
