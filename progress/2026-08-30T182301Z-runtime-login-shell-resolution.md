---
timestamp: 2026-08-30T182301Z
title: Manager-neutral runtime resolution through the login shell
branch: feature/docx-extractor-package
status: complete
---

# Manager-neutral runtime resolution through the login shell

## Progress

Extractor runtime launch no longer knows any tool manager. A new
`RuntimeCommandLocator` in `WikiFSCore` asks the account login shell (zsh,
bash, or fish, started as an interactive login shell) which absolute
executable it selects for a manifest runtime name. It accepts one absolute
path, probes the file identity through `stat`, and returns a typed result.
The query runs through `RaceFreeProcessGroupRunner` with empty stdin, bounded
output, and a 10-second startup timeout. A shell that hangs during startup is
terminated and reaped, and the failure is typed as a startup timeout.

Preparation is the single resolution boundary. `ProcessExtractorProvider`
resolves a runtime command once per prepared operation and retains the
outcome in `PreparedProcessOperation`. The operation-level `readiness()`
function and every execution consume the same retained result. Readiness
reports a retained failure as setup guidance. Execution throws the matching
typed managed-process error. A new preparation resolves again, so a runtime
installed after a failure works without an app restart.

The executor revalidates both pinned identities immediately before spawn. It
always rechecks the package entry point with `lstat`, and for a runtime
launch it rechecks the host executable with `stat`. Any change fails closed
before spawn. A direct entry point must be a regular, single-link,
owner-executable file. A runtime entry point must be a regular, single-link,
owner-readable file and needs no execute permission.

`ExtractorRuntimeSearchPolicy`, its resolver, the directory search, and all
`MISE_*` environment variables are gone. The managed child environment stays
a closed allowlist with no `PATH` and no tool-manager configuration.

Diagnostics are pure and unit-tested in `ManagedExtractorDiagnostics`. Every
Console line is one line, bounded, control-free, and home-redacted. Resolution
events carry the requested command, the source category, a redacted path, and
an identity fingerprint. User-facing messages contain no paths. Failure
categories cover the account shell record, the shell family, shell launch,
startup timeout, shell exit, command absence, invalid shell output, unusable
executable, identity change, spawn failure, nonzero exit, and protocol
failure.

Import-time auto-extraction is kind-neutral and package-driven. The import
gate matches the source's stored MIME type or filename extension against the
active registration claims, and the kinds that auto-convert at import are
derived in the wiring: claimed kinds minus the host route catalog's built-in
routes (package-only kinds). A future package-only kind converts on import
with no host-policy change. The single typed dispatch lives behind
`ExtractionCoordinator.prepareImportExtractor`. This is now a project tenet:
"Extractor-kind policy comes from package data, not host branches" in
AGENTS.md Modeling rules, with `ExtractorKindNeutralityContractTests` failing
on kind comparisons or kind-named policy seams.

## Verification

- `make build` passed.
- `make test` passed: 4033 tests in 428 suites.
- `RuntimeCommandLocatorTests` cover every typed failure and every adapter
  argument vector, including runtime names with all manifest-allowed
  punctuation.
- `RuntimeCommandLocatorIntegrationTests` resolve a real fixture runtime
  through zsh and bash with temporary shell configuration roots, launch it
  from an operation directory outside the repository, and verify that a
  startup-hang shell is reaped after timeout. Fish was not installed on this
  machine, so the fish adapter test recorded a skip reason. Its exact syntax
  stays covered by unit tests.
- `ManagedExtractorProcessExecutorTests` prove the retained absolute URL, the
  allowlisted environment with no `MISE_*` values, entry-point rules, symlink
  and hard-link rejection, and that an identity change prevents spawn.
- `ProcessExtractorProviderTests` prove one resolution per prepared
  operation, shared retained results, and retry after a new preparation.
- `ExtractorRuntimeSourceContractTests` fail if extractor-host sources
  reintroduce tool-manager knowledge or a directory search.
- Live app check (operator run): the app was launched with `make run` and
  the DOCX route showed the exact typed setup guidance for an absent
  runtime. Console showed `category=absent`. The root cause was machine
  configuration, not host behavior: bun was pinned only in the repository
  `mise.toml`, so login shells outside the repository had no bun on PATH.
  `mise use -g bun@1.4.0` made bun global, and the login shell now resolves
  bun from `/` under a minimal app-like environment.
- Manual DOCX extraction from `make run` was not repeated after the fix by
  this agent. The PR records it as the remaining manual check.
