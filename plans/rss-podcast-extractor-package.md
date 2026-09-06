# RSS podcast transcripts as an extractor package

Status: implemented. This document describes the final package boundary, the
URL protocol, the route model, and the Apple TTML follow-up boundary.

## What this change does

The portable RSS podcast transcript pipeline moved from a direct host
subprocess into a reviewed extractor package. A `.podcast` source now
transcribes through the same package registry, queue, and provenance
machinery as PDF, HTML, and DOCX extraction.

- The reviewed package `org.selfdrivingwiki.podcast-transcript` (version
  1.0.0) ships in the app and daemon resources, next to the other reviewed
  packages.
- Both hosts — the app's `AppQueueExtractionProvider` and the daemon's
  `DaemonQueueExtractionProvider` — resolve the RSS podcast transcript route
  through the extraction services and run the package in a managed process.
- Neither host constructs `RSSPodcastTranscriptService` for this route. The
  three remaining constructions are the allow-listed `.applePodcast`
  fallbacks, which the Apple TTML follow-up removes.

## The URL protocol (script protocol revision 3)

Protocol revision 3 adds a second operation input transport:

- `operation-file` — the existing staged-bytes transport, available to every
  revision. The host writes the input into the private operation directory.
- `remote-url` — revision 3 only. The request carries one normalized HTTP or
  HTTPS source URL; the host stages no bytes, and the package fetches the
  source itself.

The host validates the URL before any process launch. Rejected shapes: other
schemes (`file:`, `data:`, ftp:), embedded credentials, fragments, missing
hosts, NUL bytes, and strings over 2,048 bytes. The stored value is
normalized (lowercase scheme and host, no default port) so one source has one
wire identity. Revisions 1 and 2 keep their exact wire shape and reject the
`remoteURL` key and the `remote-url` transport; no revision accepts a mixed
shape with both `inputPath` and `remoteURL`.

A remote-url package is a registration and transport change, not a manifest
format change: the reviewed podcast package keeps manifest revision 1 with
protocol revision 3. An older host fails closed by rejecting the unknown
kind at validation. The machine catalog persists each record's manifest
revision explicitly; records without that field derive it from the protocol
revision, which implied it before revision 3.

## Package behavior

The package entry point serves one revision-3 request: a JSON request object
on stdin, JSON Lines frames on stdout, Markdown only at the requested output
path. It resolves an Apple Podcasts URL through the public iTunes lookup
when needed, selects the published `<podcast:transcript>` attachment, and
converts VTT, SRT, HTML, or plain text to Markdown.

Failure mapping is bounded: absent podcast or episode, absent transcript
attachment, malformed transcript files, and network failures all map to one
terminal failure frame with a short message. Diagnostics never contain the
source URL or feed content. The Whisper audio-transcription fallback is NOT
part of the reviewed registration; the package entry point never invokes it,
and the manifest declares only the `network` capability.

## Route model

The route is `podcast-transcript` + `audio/podcast` (the synthetic source
MIME for byteless RSS feed sources). Selection is registration-driven and
follows one state machine:

1. No saved record: the bundled default-route record supplies the reviewed
   `org.selfdrivingwiki.podcast-transcript` lineage.
2. Saved installed reference: the active compatible exact revision and
   registration runs.
3. Saved reference with no active registration: the identity stays saved,
   the route fails closed, and Settings shows the redacted diagnostic.
4. Explicit no-default record: RSS transcript extraction is disabled. The
   reviewed default is NOT revived over an explicit disable — this differs
   from DOCX deliberately.

Host code contains no package-ID or kind comparison for selection; the
kind-neutrality contract test enforces the boundary, including for the
podcast kind.

## Provenance and lineage

A package transcript persists with:

- `origin == transcript` on the `source_markdown_versions` row;
- the exact package producer — revision, registration, protocol revision,
  and the redacted reported metadata — in the tagged extraction activity
  plan;
- `source_version_id` equal to the source's immutable initial version. The
  store refuses the write when the source has no initial version, and the
  queue provider resolves the initial version before writing.

Re-transcription appends a coexisting alternative; earlier alternatives are
never changed or deleted. A failed fetch, timeout, cancellation, or missing
transcript writes no activity and no Markdown row.

## Apple TTML follow-up boundary

Apple Podcasts transcripts are NOT packaged in this change. `.applePodcast`
sources keep the Apple materializer, the `#if PODCAST_TRANSCRIPTS`
conditional compilation, the `podcast-token-helper`, and the current
built-in RSS fallback. The three allow-listed `RSSPodcastTranscriptService`
constructions (both queue providers' `.applePodcast` arms and the
`transcribePodcast` helper) carry that fallback and are removed by the Apple
TTML packaging follow-up. Apple results written through the model entry
point keep `.tool(.appleTTML)` with the source-v1 link (issue #251); the
queue Apple path's nil source-version link predates this change and is a
documented carry-over the same follow-up aligns. The Extraction settings
route table shows the RSS podcast transcript route as a standard row and
keeps the Apple TTML backend control as its own separate row.

YouTube captions are unchanged: they stay a built-in transcript adapter with
`.tool(.youtubeCaptions)` provenance.

## Sources of truth in code

- Request and transport model: `Sources/WikiFSTypes/Extractor/ExtractorProtocol.swift`
- Catalog record manifest revision: `Sources/WikiFSTypes/Extractor/ExtractorPackageCatalog.swift`
- Selection state machine: `Sources/WikiFSCore/Extractor/ExtractorSelectionResolver.swift`
- Process-backed adapter: `Sources/WikiFSEngine/ProcessExtractorProvider.swift`
- Package registration: `Sources/WikiFSEngine/ExtractorPackagePluginDefinitionFactory.swift`
- Package generation: `scripts/sync-extractor-packages.sh`
- Reviewed identity: `Sources/WikiFSCore/Extractor/ReviewedExtractorPackages.swift`
- Composition boundary: `Tests/WikiFSTests/ExtractionCompositionBoundaryTests.swift`
