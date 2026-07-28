---
timestamp: 2026-07-17T222703Z
title: "2026-07-17 — Issue #532: Module restructuring design research (branch `design/module-restructure`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-17 — Issue #532: Module restructuring design research (branch `design/module-restructure`)

## Progress


**Design doc only — `plans/module-restructure.md`. No code changes.** Researched
whether to split `WikiFSCore` (131 files, ~30k lines, organized into 7 subdirs
by #531) into domain-specific SPM targets. Key findings:

- **The 7 subdirectories from #531** are: Core (51 files/6,967 lines), Store
  (9/13,408), Integrations (25/3,660), Markdown (15/2,929), Links (11/1,822),
  Sources/glue (14/1,935), Search (6/413).
- **The Links cluster is pure logic** — zero actual `store.` method calls; the
  only `WikiStore` references in Links files are doc comments. Same for Search's
  link-fetch types.
- **No real circular dependency exists.** The dependency is a DAG. The one
  protocol-level type cycle — `WikiStore.replaceLinks` takes
  `[WikiLinkParser.ParsedLink]` — is breakable by moving the tiny `ParsedLink`
  struct (~15 lines) into WikiFSCore.
- **SQLiteWikiStore is a fan-in hub**, not a leaf. It references 54+ cross-domain
  type calls: 27 `WikiNameRules`, 6 `WikiLinkParser`, 6 `EmbeddingService`, 5
  `WikiIndex`, 3 `DisplayNameResolver`, etc. Extracting it as `WikiFSStorage`
  makes a hub that depends on all domain targets, not a clean leaf.
- **WikiStoreModel is the composition root by design** — 3,096 lines, 75+
  distinct `store.<method>` calls across every domain, plus direct calls to
  WikiLinkParser, MarkdownLinter, EmbeddingService, SourceRefreshService,
  LinkReconciler, DisplayNameResolver, WikiRenderContext, WikiStateSnapshot.
  Cannot be decomposed into per-domain models without refactoring 68 app views.
- **Build time:** 25s cached, 64s incremental (1 file changed). The ~39s delta
  is recompiling all 131 WikiFSCore files + dependents.
- **Access-control audit:** ~22 types can become `internal` after extraction
  (HTMLTokenizer, Embedder, NLEmbedder, RankFusion, etc.). Key cross-target types
  (DebugLog×245, PageID×160, WikiStoreModel×89, WikiLinkParser×6, EmbeddingService×5)
  must stay `public`.
- **Recommendation: Option D (phased), scoped to Phases 1–3.** Extract
  WikiFSLinks + WikiFSMarkdown + WikiFSSearch (low risk, ~4,420 lines, modest
  build win, ~22 types → internal). Defer WikiFSStorage extraction + WikiStoreModel
  decomposition (HIGH risk, uncertain payoff — the storage impl is a fan-in hub
  that would need 54 protocol-injection refactor sites to become a clean leaf).

PR: branch `design/module-restructure` → `main` (NOT merged).

## Verification

Historical verification remains in the progress record above.
