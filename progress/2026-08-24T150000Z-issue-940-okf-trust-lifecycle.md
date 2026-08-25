---
timestamp: 2026-08-24T150000Z
title: OKF trust lifecycle and freshness metadata
branch: feature/issue-940-okf-trust-lifecycle
status: complete
---

# OKF Trust, Lifecycle, and Freshness Metadata

Date: 2026-08-24

## Progress

### Typed metadata

The implementation adds typed OKF metadata for exact page versions and processed source Markdown versions.

The status type accepts only `draft`, `stable`, and `deprecated`. Verification bases use versioned JSON with closed basis kinds and typed evidence references. Freshness policies support fixed deadlines and TTL values anchored to generation or verification.

Verifier identities use validated human, process, or producer forms. Derived trust tiers and stale state remain read-time diagnostics. The store does not persist them as claims.

### Schema and provenance

Schema v52 adds separate metadata and verification tables for pages and source Markdown. The migration does not add metadata to existing versions.

Each verification links to a `verify` activity and an agent. A correction creates a `correct-verification` activity and adds a durable tombstone. Activity vacuum retains both activity records.

All writes target an exact version. New versions do not inherit metadata. Separate typed APIs and foreign keys keep page and source Markdown identifiers in different namespaces.

### Projection and change signaling

File Provider frontmatter emits persisted `verified`, `status`, and `stale_after` facts in stable order. Empty optional fields remain absent, so content without v52 metadata keeps the issue #927 output.

Each metadata mutation increments one target-local projection revision. Both aliases use the same revision. The whole-wiki token appends an OKF revision fold without changing older field positions.

Each public mutation emits one owning page or source update after commit. Failed writes emit no event. Corrupt typed JSON fails the concept read instead of producing partial trust metadata.

### Command-line interface

`wikictl page okf` and `wikictl source okf` support inspection, status, freshness, verification, and correction operations. Mutations require an exact page or source Markdown version ID.

The parser validates actors, timestamps, durations, basis kinds, typed evidence, and anchor ownership. Successful writes request one post-commit notification. Inspection and invalid input request none.

### Inspector

The existing metadata inspector loads OKF metadata for the exact active version through the read service. It shows explicit status, derived trust tier, ordered verification details, evidence links, the deadline, and fresh or stale state.

The section is read-only. It uses semantic system fonts and text labels for all state. It does not use color as the only signal.

## Verification

The following focused tests passed:

- `OKFTrustLifecycleTests`
- `OKFMetadataStoreTests`
- `SchemaV52MigrationTests`
- `WikiCtlOKFCommandTests`
- `ProvenanceFrontmatterTests`
- affected schema v48 and schema-version compatibility suites

The full `make test` gate passed with 3,647 tests in 374 suites.

`swift build` passed after the inspector integration.

The first inspector filters matched zero tests because the app test target is opt-in. The corrected commands used `WIKIFS_APP_TESTS=1`.

The opt-in page inspector projection suite passed 8 tests. The source inspector projection suite passed 17 tests.

An independent review found two high-severity behavior gaps. The store now rejects missing source evidence and non-HTTP external evidence before it creates provenance rows. File Provider bookmark aliases now fail closed for corrupt OKF metadata instead of serving replacement Markdown.

New store tests prove invalid evidence does not change metadata, revisions, tokens, or events. New event tests prove page, source, and combined verification writes each emit one owning update. A File Provider integration test proves corrupt page metadata fails by-ID, by-title, and bookmark aliases.

The audit read now validates and exposes the correction activity and correcting agent. The real vacuum regression proves this linkage remains readable after vacuum.

The final required gates passed:

- `make build`
- `make test`
- `swift build`
- `swift test`

The final default suite ran 3,653 tests in 374 suites. A focused re-review found no remaining critical or high findings.

The final independent implementation review found no defects at any severity and recommended shipment. It identified only optional source-side symmetry tests.

The reviewed delivery is committed. The branch push and pull request are pending.
