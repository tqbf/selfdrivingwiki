---
timestamp: 2026-08-18T052700Z
title: Catalog-driven chat thinking
branch: bugfix/chat-thinking-labels
status: delivered-live-regression-fix-validated
---

# Catalog-Driven Chat Thinking Progress

Date: 2026-08-18
Branch: `bugfix/chat-thinking-labels`

## Progress

- Added typed core thinking catalogs with exact ACP option IDs.
- Added ordered choices, valid defaults, and discovered default model markers.
- Added one pure configured and effective value resolver.
- Added a provider and model catalog resolver for chat fallback rules.
- Added schema version 51 with nullable configured and effective chat columns.
- Updated fresh schemas, migrations, readiness checks, queries, and decoders.
- Added one atomic chat model and thinking mutation with one event.
- Enriched provider probes and live model capture from shared ACP extraction logic.
- Preserved previous catalogs after empty or failed refreshes.
- Added draft thinking state and request fields.
- Added a typed runtime thinking configuration with legacy decoding.
- Reloaded the provider sidecar before each cold daemon runtime start.
- Applied and confirmed thinking before the first provider submit.
- Persisted only confirmed live effective values.
- Kept configured intent and the previous effective value after rejection.
- Made the Thinking menu work for draft, idle, restored, and live chats.
- Made model family labels use catalog aliases before the legacy fallback list.
- Added fallback help and accessibility state to the native menu.
- Added typed ACP agent fingerprints and complete provider observations.
- Added one source-priority resolver for live ACP, cached ACP, adapters, overrides, and no capability.
- Added the version-gated Codex model-variant adapter.
- Removed generic bracket and display-name capability discovery.
- Added strict local override validation with an empty bundled registry.
- Added mechanism-discriminated runtime payloads with strict legacy decoding.
- Added post-model live ACP authority and model-variant runtime handling.
- Added an actor and kernel `flock` around provider-sidecar mutations.
- Added monotonic provider-sidecar generations and post-unlock local and Darwin signals.
- Added app-lifetime provider reloads and activation repair for missed signals.
- Migrated production provider writes to the locked mutation API.
- Added a static production writer guard.
- Added a two-process helper test for the kernel lock.
- Added strict command-fingerprint matching for trusted compatibility fallback.
- Added an immutable compatibility record for the legacy `npx @agentclientprotocol/codex-acp@1.1.7` seed.
- Kept provider IDs, labels, changed arguments, other package versions, and unrelated bracketed models outside the fallback.

## Verification

- Core capability, adapter, parser, and compatibility gate: 12 tests passed.
- Command fingerprint and stale-model gate: 9 tests passed.
- Locked provider store and writer guard: 6 tests passed.
- Provider reload coordinator gate: 16 tests passed.
- Final probe, selector, presentation, and provider gate: 87 opt-in tests passed.
- Final runtime, ACP backend, and daemon lifecycle gate: 162 opt-in tests passed.
- Earlier schema and store focused gate: 118 tests passed.
- Earlier ACP provider probe gate: 26 tests passed. One live smoke test skipped by configuration.
- Earlier catalog UI gate: 32 tests passed.
- Earlier live configuration gate: 11 tests passed.
- Earlier combined opt-in acceptance gate: 116 tests passed across nine suites.
- `make build`: passed and produced a signed debug app.
- Final `make test`: 3,350 tests passed across 310 suites.
- `make lint`: zero violations across 504 files.
- `git diff --check`: passed.

The reload tests found a cached-generation comparison bug. The coordinator now reads the sidecar generation before it refreshes sessions.

The stale-model test found that an explicit removed model could use the default model capability. Explicit unknown models now resolve to no capability.

The OpenAI review found one high, three medium, and one low issue. The fixes preserve selectability, bind observed capability to one model, order live updates, remove unlocked seed writes, and isolate favorite clicks.

A final Claude Sonnet 4.6 review through Paseo found no blocking issues and three low issues. The final fixes add Darwin teardown safety, require known nonstandard fingerprints, and restore favorites after failed writes.

A Swift 6.3 compiler assertion occurred in a compact enum switch. A direct switch implementation fixed the compiler issue.

A controller test had an existing asynchronous assertion race. The test now uses its bounded persisted-state wait helper.

A live `make run` check found that a legacy Codex sidecar still showed model names such as `(high)` without a separate Thinking selector. The sidecar had cached bracketed variants but no catalog observation or ACP fingerprint.

The resolver now accepts that legacy sidecar only when its complete configured command matches the immutable `1.1.7` seed. The adapter uses the package's observed ACP identity, `@agentclientprotocol/codex-acp`.

A Paseo and `codex-acp@1.1.7` source review confirmed that current sessions advertise standard ACP `thought_level` metadata. The bracketed model list remains a legacy compatibility surface. The fallback no longer depends on the GUI process `PATH`.

Focused core capability and command tests passed 20 tests. Focused opt-in probe, selector, presentation, and label tests passed 46 tests.

An independent Z.AI GLM 5.2 review found two medium test and safety gaps. The parser now rejects duplicate variant IDs without a dictionary trap. A config-level regression proves that a real observed fingerprint suppresses the legacy command fallback. The fix also removed a repeated render-path diagnostic.

The final post-review gates passed. `make test` passed 3,356 tests across 310 suites. `make build`, `make lint`, and `git diff --check` also passed.

## Remaining Work

- Commit and push the fix to pull request 1114.
