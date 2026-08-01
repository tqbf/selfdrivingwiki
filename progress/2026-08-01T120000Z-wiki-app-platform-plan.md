# Wiki App platform plan

Date: 2026-08-01

`plans/wiki-app-platform.md` is the single design of record for worker-based
Wiki Apps, extraction, source workflows, provenance, and ingestion integration.

The plan contains six ordered implementation phases. Each phase has a gate,
primary file list, and test requirements.

The plan replaces the versioned platform draft and its review document. Agents
do not need those documents to reconstruct the final direction.

`plans/dynamic-renderers.md` remains separate because renderers do not use the
worker execution model. GitHub issue #1026 tracks that work.

This change updates design documents only. It does not change product behavior,
schema, or code.
