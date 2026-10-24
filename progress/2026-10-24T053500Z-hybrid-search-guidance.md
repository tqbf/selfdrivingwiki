---
timestamp: 2026-10-24T053500Z
title: Hybrid search guidance for chat agents
branch: fix/1475-keyword-search-guidance
status: active
---

# Hybrid search guidance for chat agents

## Progress

The maintainer prompt and staged `WIKI_STATE.md` now describe hybrid BM25 and cosine search. They allow short concept questions and tell agents to avoid instruction-style search queries. They also tell agents to inspect relevant hits before they conclude that the wiki lacks an answer.

This guidance assumes issue #1474 restores cosine search in the daemon. The daemon currently registers an unavailable embedding provider, so its live searches still use BM25 alone.

## Verification

`make prompts` synchronized the prompt resource copies. The focused prompt and staging test run passed 49 tests across three suites. The documentation contract run passed 16 tests across two suites. `make build` passed before the final wording revision. The full `make test` run was interrupted while the store suites ran and has no final result.
