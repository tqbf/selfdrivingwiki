# Apple Podcasts TTML extractor package

Status: implemented on `feature/apple-ttml-extractor-package`, stacked on
`feature/rss-podcast-extractor-package`.

## Goal

Apple Podcasts transcripts move from built-in Swift code (the signing helper,
the AMP request, the TTML parser, and the materializer) to a reviewed
extractor package, `org.selfdrivingwiki.apple-podcast-transcript`. The
package owns the whole workflow: token acquisition, Apple AMP access, TTML
download, TTML-to-Markdown conversion, and the RSS fallback when the signing
helper is unavailable.

The signed `podcast-token-helper` Mach-O stays OUTSIDE the immutable package
snapshot. Code signing rewrites Mach-O bytes, so a signed helper can never
reproduce the package digest. The host stages the helper into the private
operation root for one exact reviewed revision only.

## Design decisions

### The helper is operation-local host support

- The host opens a typed operation-support provider
  (`ExtractorOperationSupportProviding`). It returns nothing, or one bounded
  executable grant (role, source URL, destination file name, expected
  SHA-256, expected byte count).
- Admission is the COMPLETE revision identity: package ID, version, and
  digest (`ReviewedExtractorPackages.applePodcastTranscript`). A kind, a
  MIME type, a manifest capability, a credential, or any package-controlled
  string never grants support. An imported lookalike with the same ID and
  version but a different digest receives nothing.
- Staging copies from an `O_NOFOLLOW`-opened descriptor while hashing,
  verifies size and hash, sets mode 0500, publishes with an exclusive
  rename, and re-verifies the staged inode. Symlinks, hard links, identity
  changes, and planted destinations all fail closed.
- The request's operation-configuration file carries only the staged
  helper's RELATIVE path. The configuration envelope is now a closed tagged
  model: `.doclingServe(endpoint:timeout:)` keeps the legacy flat wire shape
  (the installed reviewed Docling package reads it), and
  `.applePodcastTranscript(helperPath:)` writes
  `{"kind": "apple-podcast-transcript", "helperPath": …}`. Mixed, unknown,
  and absolute/traversal shapes are rejected on decode.
- The support directory (`support/<request-id>/`) is removed on every
  terminal path by the same defer that cleans credential and configuration
  subdirectories; the operation-root deinitializer stays as the final net.

### Package capabilities remain declarations

The manifest declares `network` only. The staged helper is not a manifest
file, not a capability, and not a sandbox: the package process runs as the
same user, and the security boundary is exact reviewed-revision trust plus
the host's admission check. Documentation states this plainly.

### The package owns the workflow

`tools/apple-podcast-transcript/apple-podcast-transcript` (PEP 723,
protocol revision 3, `remote-url`):

- Helper supervision: a forked supervisor owns the helper's process group,
  drains stdout/stderr under byte caps, enforces a local timeout with
  TERM-to-KILL escalation, honors a one-byte control pipe (`T` = terminate,
  EOF = package death), and always reaps. The supervisor gets a timeout head
  start and its own SIGTERM handler, so a parent-side escalation can never
  orphan the helper group.
- Token cache: the host creates a durable, revision-scoped cache root
  (`<extractors root>/package-cache/<packageID>/<version>-<digest12>`) with
  owner-only permissions and passes it through a dedicated environment key
  (`WIKI_EXTRACTOR_PACKAGE_TOKEN_CACHE`) only for the exact revision. The
  package stores `{"token", "fetched"}` atomically (0600), treats missing,
  expired (~30 days), and corrupt entries as misses, and sweeps superseded
  sibling revisions on each host-side cache admission.
- AMP + TTML: the request rules and the one-time forced refresh on Apple
  error `40012` are ported from `ApplePodcastAMP` /
  `ApplePodcastTranscriptService`. The parser ports `TTMLTranscript`
  semantics: local-name matching for any namespace prefix, word-unit joining
  with spaces, speaker labels, three clock formats, raw-paragraph fallback,
  and failure on malformed or cue-free TTML.
- Fallback rule: the RSS transcript algorithm runs ONLY when no helper was
  staged. A failure after helper admission (helper, AMP, TTML download,
  parsing, or timeout) never falls back to RSS.

### Routing

- New kind `apple-podcast-transcript`, backend kind
  `.applePodcastTranscript`, route
  (`apple-podcast-transcript`, `audio/apple-podcast`), and a standard
  registration-driven Settings row. The bespoke Apple TTML backend row is
  removed.
- `prepareApplePodcastTranscript()` mirrors `preparePodcastTranscript()`:
  the reviewed lineage is the bundled default, an explicit `.none`
  disables, and everything else fails closed.
- Both queue providers route `.applePodcast` through the selected or
  reviewed Apple package with the validated `origin.plan` URL, persisting
  installed-package provenance, `.transcript` origin, and the immutable
  initial source-version link.
- The model-level `transcribe`/`refreshSource` podcast arms throw
  `.podcastQueueRequired` (same as the RSS arm since the RSS packaging);
  availability predicates derive from the route, not helper presence.
- Removed production Swift: `ApplePodcastAMP`, `ApplePodcastTranscriptService`,
  `TTMLTranscript`, `ApplePodcastMaterializer`, the built-in Apple plugin,
  and the `podcastFetcher` seams. `HelperPodcastTokenProvider` is reduced to
  helper discovery (`resolveHelperURL()`), the one piece the host still owns.
- `WIKIFS_APP_STORE=1` builds keep compiling (no helper target, no private
  framework Swift). The reviewed package ships in the bundle and uses its
  RSS fallback there.

## Fallback semantics

| State | Behavior |
| --- | --- |
| No helper staged (App Store, helper absent) | Package runs the RSS transcript algorithm |
| Helper staged, workflow succeeds | Apple TTML workflow output |
| Helper staged, any step fails | One failure frame; RSS never runs |
| Route explicitly disabled in Settings | Typed unavailable failure; nothing runs |

## Test strategy

- Python (`tools/apple-podcast-transcript/tests`): request parsing, fallback
  semantics, `40012` refresh, TTML parser parity, helper-path validation,
  token cache lifecycle, real helper-supervisor behavior (hung, flooded,
  TERM-ignoring helpers; leak detection), and redaction canaries.
- Swift: operation-support admission/staging/cleanup, tagged configuration
  coding (mixed, unknown, legacy shapes), composition-boundary scans (no
  legacy RSS construction sites; no Apple policy branches outside the
  reviewed seams), kind-neutrality for the new kind, reviewed digest gate
  (`ReviewedExtractorPackageTests`), and manifest/protocol validation.
- `extractor-package-tool validate` + `protocol-smoke` cover the generated
  package bytes and the fixture frame sequence offline.

## Follow-ups

- An executable-package loopback harness (launch production-derived package
  bytes against a bounded loopback HTTP server) can deepen the end-to-end
  coverage; the workflow seams are already injectable for it.
- The optional live Apple diagnostic (`WIKIFS_LIVE_PODCAST_TESTS=1`) was
  retired with the Swift service; a package-side live test can return as an
  opt-in script if Apple API drift needs monitoring.
