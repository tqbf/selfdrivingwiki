---
timestamp: 2026-08-24T010000Z
title: Cordis Phase 5b — delete the privileged core
branch: feature/cordis-5b-delete-privileged-core
status: complete
---

# Cordis Phase 5b — delete the privileged core

## Progress

Landed Phase 5b Stage 2 on `feature/cordis-5b-delete-privileged-core`
(stacked on `feature/cordis-full-architecture`, PR #1138), in twelve gated
commits (`ee95dae9` … `cabdbe4f`).

- Production plugin catalogs for the app, daemon, and CLI with injected
  factories; assembly-owned composition moved into standalone runtime
  factories (`*RuntimeFactory.swift`).
- Process-profile vs per-wiki profile lifetimes split: process services
  (agent provider, extraction, queue, transport, renderer) are supplied as
  typed leases from a process profile root; per-wiki store/sessions/search
  boot as child contexts (`CordisBoot` parent-context support).
- `SessionManager` gained async per-wiki readiness; `ProfileWikiSession` is
  the sole session implementation (the legacy `WikiSession` type is
  deleted); views use `WikiSessionProtocol`.
- The app boots `AppProcessProfileOwner` (single composition path, no
  assembly construction); `wikid` awaits process-profile readiness before
  `NSXPCListener.resume()` and serves stores through retained per-wiki child
  profiles; CLI search resolves through `CLIPluginCatalog`.
- Deleted `WikiSession.swift` and all six `*RuntimeAssembly.swift` files;
  `scripts/check-cordis-boundaries` is strict by default (no baseline) and
  `grep -r "RuntimeAssembly" Sources/` returns nothing (AC.4).

Full sequence and caller inventory: `plans/cordis-5b-status.md` (marked
complete).

## Verification

- `make build` — passed (signed app bundle) after every commit.
- `make test` — 3,572 tests in 360 suites passed.
- `make check-cordis` — "Cordis boundaries verified" (strict by default).
- `grep -r "RuntimeAssembly" Sources/` — no matches.
- Store invariants (`StoreConcurrencyTests`,
  `StoreEmissionExhaustivenessTests`) pass unmodified (AC.7).
