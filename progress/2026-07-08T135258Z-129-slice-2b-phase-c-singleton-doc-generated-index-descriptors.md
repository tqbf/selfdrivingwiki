---
timestamp: 2026-07-08T135258Z
title: "2026-07-08 — #129 slice 2b, Phase C: singleton-doc + generated-index descriptors"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-08 — #129 slice 2b, Phase C: singleton-doc + generated-index descriptors

## Progress


**Shipped (on `feature/129-2b-phase-c-singleton-index-descriptors`; tests green).**
Phase C: the last non-flat projection kinds collapse to descriptor-driven code.
The bespoke singleton-doc builders (`README.md`, `CLAUDE.md`/`AGENTS.md`,
`index.md`, `log.md`, `WIKI-STRUCTURE.md`/`TREE.md`) and the generated-index
files (`manifest.json`, the three `*.jsonl` under `indexes/`) — each previously
a hand-coded switch arm + builder in `node(for:)` / `children(of:)` /
`contents(for:)` — now route through two registries (`singletonDocs` +
`generatedIndexes`) of value-typed descriptors, exactly as Phase B did for
flat resources. **Behavior byte-identical.**

**What shipped:**
- **`SingletonDoc` + `SingletonDocEntry` descriptors.** A value type holding
  one-or-more root-level filename entries (`entries`), a `nodeFor` closure, a
  `contentFor` closure, and a `participatesInWorkingSet` flag (static docs like
  README never change → excluded from the working set). Five instances:
  `readmeDoc`, `systemPromptDoc` (dual-alias: CLAUDE.md + AGENTS.md),
  `wikiIndexDoc`, `logDoc`, `wikiStructureDoc` (dual-alias:
  WIKI-STRUCTURE.md + TREE.md). The private helper methods
  (`systemPromptNode`, `wikiIndexNode`, `logNode`, `treeNode`, etc.) are
  unchanged — the closures call them.
- **`GeneratedIndex` descriptor.** Collects the per-index variation (identifier,
  filename, parent, generator closure) that was previously inlined in the
  `generateIndexData(for:)` switch. Four instances: `manifestIndex` (root-level),
  `pagesJSONLIndex` / `linksJSONLIndex` / `sourcesJSONLIndex` (under `indexes/`).
  The `parent` field drives root-vs-indexes children enumeration. `generateIndexData`
  is deleted; `indexData(for:)` now looks up the descriptor by id and calls its
  generator. `indexFileNode` takes a descriptor instead of `(id, name, parent)`.
- **Dispatch sites all registry-driven.** `node(for:)` iterates `singletonDocs`
  then `generatedIndexes` before the structural-folder switch; `children(of:)`
  root iterates singleton-doc entries + root-level indexes + flat folders + the
  indexes folder, and the `indexes/` case filters `generatedIndexes` by parent;
  `contents(for:)` dispatches through both registries; the working set emits all
  generated indexes + participating singleton docs.
- **12 new characterization tests** in `ProjectionTreeTests` (singleton-doc node
  resolution + content serving for every alias pair, root-children order, `indexes/`
  children order, manifest size==content, jsonl row counts, working-set
  exclusion of README + inclusion of all non-static docs + indexes).

**Gate:** full suite green — **1906 tests** (156 suites); the 10 Phase B
`ProjectionTreeTests` + 12 pure `ProjectionTests` pass unchanged
(byte-identical). No schema change; no `user_version` bump.

**Next:** Phase D — bookmarks projection (#125) via `NestedResourceProjection`,
the nested-shape capstone.

## Verification

Historical verification remains in the progress record above.
