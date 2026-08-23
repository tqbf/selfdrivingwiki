---
timestamp: 2026-08-23T235000Z
title: Cordis domain plugins, bundles, profiles, and boot gates
branch: feature/cordis-full-architecture
status: complete
---

# Cordis domain plugins, bundles, profiles, and boot gates

## Progress

Completed Phases 4 (all 11 domains), 5a (bundles/profiles as data), 5b Stage
1 (boundary checker), and the AC.5/AC.8 boot gates on
`feature/cordis-full-architecture` (commits `425c98b9` … `bfc1c259`).

- Every product domain now has an additive Cordis plugin seam in
  `WikiFSEngine`: store (`wiki.store`), session log + chat persistence
  (`wiki.sessions`, `wiki.chats-persistence`), LLM runtime + ACP adapter
  (`wiki.llm-runtime`, `wiki.llm-acp-adapter`), tools with pre/execute/post
  waterfalls (`wiki.tools`), system prompt (`wiki.system-prompt`), agent
  loop with turn/step events (`wiki.agent-loop`), extraction backends
  (`wiki.extraction` + adapters), search providers (`wiki.search` +
  adapters), renderers (`wiki.renderers`), daemon transport
  (`wiki.transport`), and integrations (`wiki.integrations` + Zotero,
  podcast, URL-fetch adapters). All registrations are reversible; heavy
  dependencies stay behind injected lazy factories.
- Bundles ship as data (`bundles/{wikifs-base,wikifs-app,wikid,wikictl}/
  cordis.patch.yml`) with `ProfileBundle` resolution (bundle → profile →
  home → `--patch` overlay) and `wikictl --dump-config`.
- `scripts/check-cordis-boundaries` (+ `make check-cordis`,
  `CordisBoundaryScriptTests`) guards against new privileged-core
  construction; `--strict` enforces the end state once Phase 5b Stage 2
  lands.
- AC.5/AC.8 suites: `AppProfileBootTests`, `DaemonProfileBootTests` (store
  subscriber observes committed state and stops after disposal),
  `CordisBootIntegrationTests` (config-only store swap → distinct service
  identity), plus per-domain `*PluginBootTests`.

Phase 5b Stage 2 — deleting `WikiSession.swift` and the six
`*RuntimeAssembly.swift` files and rewiring app/daemon/CLI entry points to
boot from profiles — is deliberately staged out; the caller inventory and
16-step sequence live in `plans/cordis-5b-status.md`. Each domain plugin
slice kept the legacy assembly in place, so today both composition paths
coexist and every gate is green.

## Verification

- `make build` — passed (signed app bundle) after every slice.
- `make test` — 3,566 tests in 360 suites passed.
- `make check-cordis` — passed.
- Store invariants: `StoreConcurrencyTests` and
  `StoreEmissionExhaustivenessTests` passed unmodified (AC.7).
