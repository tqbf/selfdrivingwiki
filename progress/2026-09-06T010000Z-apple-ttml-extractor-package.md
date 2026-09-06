---
timestamp: 2026-09-06T010000Z
title: Apple Podcasts TTML extractor package
branch: feature/apple-ttml-extractor-package
status: complete
---

# Apple Podcasts TTML extractor package — 2026-09-06

## Progress

The Apple Podcasts TTML workflow moved into a reviewed extractor package.
The signed helper became operation-local host support; the model kept only
helper discovery.

## What shipped

- **Reviewed package** `org.selfdrivingwiki.apple-podcast-transcript` 1.0.0
  (protocol revision 3, `apple-podcast-transcript` kind,
  `audio/apple-podcast` MIME, `network` capability, digest pinned in
  `ReviewedExtractorPackages` and `sources.lock.json`). Source:
  `tools/apple-podcast-transcript/` with 36 Python tests, ruff, and pyright
  green.
- **Workflow**: staged-helper bearer token → Apple AMP → one `40012`
  forced-refresh retry → TTML download (bounded) → parser that ports the
  former `TTMLTranscript` semantics. Without a staged helper the package
  runs the RSS transcript algorithm. A failure after helper admission never
  falls back to RSS.
- **Helper staging**: `ExtractorOperationSupportProviding` +
  `ReviewedApplePodcastSupportProvider` admit the COMPLETE revision identity
  only. `ExtractorOperationSupportStager` copies from an `O_NOFOLLOW`-opened
  descriptor while hashing, verifies size and hash, sets mode 0500, and
  publishes with exclusive `link(2)` (POSIX `rename` silently replaces a
  planted destination — found and fixed during this work). Cleanup rides the
  existing per-request defer; the operation-root deinitializer is the net.
- **Tagged operation configuration**: `.doclingServe` keeps the legacy flat
  wire shape (the installed reviewed Docling package reads it);
  `.applePodcastTranscript` writes the tagged helper-path shape. Mixed,
  unknown, absolute, and traversal shapes fail decode.
- **Token cache**: host-owned, revision-scoped
  (`package-cache/<id>/<version>-<digest12>`), owner-only, ~30-day expiry,
  atomic replacement, corrupt entries treated as misses, superseded sibling
  revisions swept on admission. Exposed to the child only through
  `WIKI_EXTRACTOR_PACKAGE_TOKEN_CACHE`, gated on the exact revision.
- **Routing**: `.applePodcast` in both queue providers resolves through
  `prepareApplePodcastTranscript()` (same selection state machine as RSS;
  reviewed lineage is the bundled default) and persists installed-package
  provenance with `.transcript` origin and the source-v1 link. New tests
  drive both providers through a fake managed executor and a real store.
- **Removals**: `ApplePodcastAMP`, `ApplePodcastTranscriptService`,
  `TTMLTranscript`, `ApplePodcastMaterializer`, the built-in Apple plugin,
  the `podcastFetcher` seams, the model-level Apple transcribe/refresh
  fetch paths (now `.podcastQueueRequired`, matching RSS), and the bespoke
  Apple TTML settings row. `HelperPodcastTokenProvider` is reduced to helper
  discovery — the one piece the host still owns.
- **Availability**: `isSourceRefreshable`/`isTranscribable` for
  `.applePodcast` now derive from the route, not helper presence.

## Gates

- Package: `sync-extractor-packages.sh` (sync + `--check` byte compare),
  `extractor-package-tool validate` (digest
  `7d02732f…69d3a8`), `protocol-smoke` on the new fixture.
- Swift suites: operation-support (9), composition boundaries (3, allow-list
  removed and replaced with a stronger zero-site scan plus an Apple-policy
  scan), kind neutrality (6 with the Apple analog), reviewed packages (14),
  protocol (13), manifest validator, credential tests, and the touched
  routing/refresh/materializer suites.
- App (opt-in): `AppleQueueExtractionProviderTests` for AC.9 provenance in
  both hosts; `ExtractionRouteTableHostedTests` updated for the removed
  settings row.
- Full `make build` / `make test`, `WIKIFS_APP_STORE=1 swift build`,
  `scripts/validate-skills`, and `git diff --check` run before the PR.

## Notes for future work

- The executable-package loopback harness (production-derived package bytes
  against a bounded loopback server) is the named follow-up for deeper
  end-to-end coverage; the package's seams are already injectable.
- `ExtractionConfig.podcastBackend` is now decode-only compatibility data;
  nothing writes it and no control reads it for Apple routing.

## Drift audit round (same day)

A Claude/Paseo conceptual drift audit of the branch (verdict FIX-FIRST,
zero live defects) found the new source-scan guard `noApplePolicyBranch`
scanning roots that could never contain its allow-listed files — a
silently vacuous guard — plus stale doc comments describing the deleted
materializer path, the write-only support-grant role with a hardcoded
configuration mapping, the dead `RSSPodcastTranscriptService` family, and
the vestigial `podcastBackend` setting. All findings are fixed in commit
`55962995`: the guard now scans the engine/extractor roots and asserts its
allow-list is reachable; the support configuration is selected by grant
role with a single-writer precondition; the dead types, setting, resolver
plumbing, and re-transcribe submenu are removed (legacy config keys decode
as ignored); the grant trust anchor and the staging-failure-fails-closed
behavior are directly tested; and the rename→`link(2)` documentation is
corrected. Full gates re-run green (4201 tests, lint, opt-in app suites,
drift check).

## Verification

- Package gates: `scripts/sync-extractor-packages.sh` (sync and
  `--check` byte-compare), `swift run extractor-package-tool validate
  ExtractorPackages/ApplePodcastTranscript` (digest `7d02732f…69d3a8`), and
  `protocol-smoke` on the new fixture all pass.
- Python: 36 tests, `ruff check`, and `pyright` are green in
  `tools/apple-podcast-transcript`.
- Swift suites: operation support (9), composition boundaries (3), kind
  neutrality (6), reviewed packages (14), protocol (13), manifest validator
  (4), credential tests (13), and the touched routing, refresh, and
  materializer suites pass. `AppleQueueExtractionProviderTests` (3,
  opt-in) covers installed-package provenance in both hosts.
- Full `make test` (4201 tests after the drift fixes), `make lint`,
  `WIKIFS_APP_STORE=1 swift build`, and `git diff --check` pass on the
  branch.
