---
timestamp: 2026-10-25T23:31:00Z
title: W3 pre-flight — eval host entitlement, report parser, container hygiene; trials reach the provider
branch: feature/generalized-page-validity-lint
status: preflight-complete-trials-reach-provider
---

# W3 — three pre-flight fixes before the next live-gate run

Continuation of
`progress/2026-10-25T210000Z-w3-live-gate-driver.md`. The host served
end-to-end but three defects blocked a meaningful verdict: the agent
never received provider credentials (Keychain -34018), a run-report
parser rejected the seeded report template
(`malformedLine`), and 54 leaked disposable wikis polluted the eval
container. All three are fixed; a live bail trial now reaches the
provider, receives credentials, appends its lint log entry, and files a
coverage-complete report. A fourth blocker surfaced during the proof —
scoped-run endpoint paths that cannot fit long App Group ids — and is
also fixed.

## Progress

- **`bf205c50` — the driver host is the signed bundle wikid.** The
  runner's `wikidBinaryPath()` fell through to the bare SwiftPM wikid
  Mach-O, which has no code-signing entitlements: every Keychain
  credential read failed with errSecMissingEntitlement (-34018) and the
  lint agent never got its provider credentials. The runner now prefers
  the wikid XPC service inside the built app bundle (`make build` signs
  it with the daemon entitlements, including `keychain-access-groups`)
  before the sibling and `.build` fallbacks. `LINT_EVAL_HOST_BIN`
  still overrides. The bundle binary is un-sandboxed by design, so it
  reaches the eval container by path; the runner's inherited
  `WIKI_APP_GROUP_ID` (eval group) wins over the bundle's Info.plist.
- **`afbbedfc` — the parser accepts the seeded template's `pending`
  lines.** The lint-page prompt seeds `check/item/finding … pending`
  rows and instructs the agent to replace each with a real outcome, but
  the strict parser threw `malformedLine` on `pending` — the UNFILLED
  seeded template itself was a parse error. `pending` is now a
  first-class parseable `LintFindingOutcome`; the checklist-theater
  defense moved to the single accounting authority: the coverage
  validator rejects every pending row as unfilled (named reasons), the
  verification line stays unfilled-checked, and unfilled finding rows
  stay in the host record's open-findings list. Test parses the EXACT
  `render()`-seeded template.
- **`9044dd0f` — the driver sweeps the eval container before the
  suite.** The 54 leaked `lint-eval-*` wikis in
  `group.eval.selfdrivingwiki.lintgate` (trials that died before their
  per-trial eviction) were wiped by hand — DB files + sidecars, registry
  reset, `renderers/` untouched; the operator container
  (`group.com.willsargent.wiki`) was never touched. The driver now runs
  `evictPreexistingWikis` before composing the suite: list, evict, log
  the count, and name anything eviction could not clear.
- **`afb2dce9` — scoped-run endpoints fit long App Group containers.**
  With credentials flowing, the next blocker surfaced: EVERY scoped-run
  registration in the eval container failed
  `registrationFailed(pathTooLong limit: 103, actual: 108)` — the eval
  group id is 9 characters longer than the operator's, and
  `<container>/r/<24-hex>.sock` overflowed the sockaddr_un budget (the
  30-second socket deadlines in the 21:45 run were the same defect
  wearing a timeout). `DaemonRunEndpointName` now base64url-encodes the
  SAME 12 random bytes into 16 characters (path = 100 bytes); the
  256-bit capability remains the authorization secret. The two launcher
  preflight failures that previously exited without any log line now
  log their cause. Regression test pins the generated name against the
  eval container's path budget.

## Verification

- `make build` clean (app built + signed; the bundle wikid carries the
  host-mode string and the `keychain-access-groups` entitlement).
- `swift test --filter 'LintLiveGate|LintEval|LintAudit'` — 39 tests in
  3 suites passed. `WIKIFS_APP_TESTS=1 swift test --filter
  DaemonRunEndpointTests` — 7 tests passed.
- `swift test --filter LintOutcomeCoverageTests` — 14 tests passed
  (includes the new seeded-template parser test).
- Bare `swift build` clean.
- Live proof (`run --live --gate --provider pi-acp --model
  "GLM 5.3 Flash" --bail-trials 1 --group-runs 1 --wall-clock-hours
  0.25`, output `tmp/w4-preflight-proof-run3.out`, report
  `tmp/wiki-lint-eval/2026-10-25T232013Z/`): the runner hosted from
  `build/Self Driving Wiki.app/…/wikid.xpc/…/wikid`; the driver logged
  `eval container starts clean`; 9 trials consumed 269 s of REAL
  provider turns (the previous run: 1.7 s of instant failures). The
  bail trial (`bail-d25-wrap#1`) reached the provider and returned
  `run-report coverage complete` with every check row filled
  (`valid-as-written|…` / `unresolved|…`, reasons included), cited its
  lint log entry id (`01M5TNVMB33SDKKS666D95QJYW`), and recorded ZERO
  `-34018`, ZERO `AGENT LOG MISSING`, ZERO `malformedLine` across all
  9 trials. Six trials still fail on MODEL behavior the contracts
  correctly reject (check rows claiming `repaired`, leftover `pending`
  rows, a newly introduced defect) — that scoring is the W3 gate's
  job, not a pre-flight concern.
