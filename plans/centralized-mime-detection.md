# Centralized MIME Detection

**Status:** Implemented on `feature/centralized-mime-detection`.

## Goal

Use one bounded detector for every byte-bearing source. The detector makes byte evidence authoritative for format dispatch and persistence.

## Detector contract

`ContentTypeDetector` accepts these inputs:

- a declared MIME value with a typed origin;
- a filename extension;
- an optional UTI MIME hint;
- a bounded byte prefix with explicit complete or truncated state.

The detector returns these values:

- a normalized MIME value;
- ordered typed evidence;
- a confidence value;
- typed conflicts;
- an optional structured artifact kind.

`ContentTypeDetectionLimits.maximumPrefixByteCount` is 64 KiB. Callers must not infer completeness from the prefix size.

## Precedence

The detector uses this order:

1. A validated binary signature overrides all declarations and fallback hints.
2. A complete structured document overrides declarations and fallback hints.
3. A trusted generated declaration identifies app-controlled output.
4. An HTTP or Zotero declaration identifies content when bytes do not contradict it.
5. Complete plausible UTF-8 text identifies text.
6. A UTI MIME hint is a fallback.
7. The project extension map is the final fallback.

The detector reports each disagreement with the chosen MIME. It does not assign `application/octet-stream` to unknown binary data.

The signature table includes PDF, PNG, JPEG, GIF87a, GIF89a, WebP, ZIP, gzip, 7z, and RAR v4/v5. ZIP signatures identify only `application/zip`.

## Structured content

Structured recognition requires a complete bounded input. A valid truncated prefix is inconclusive.

The detector recognizes JSON, XML, SVG, HTML, XHTML, and plausible UTF-8 text. JSON Canvas remains `application/json`.

`ContentArtifactValidator` validates JSON Canvas separately. It requires complete JSON with `nodes` and `edges` object arrays. Renderer matching repeats this bounded validation and fails closed for legacy or truncated input.

## Architecture boundary

`ContentTypeDetector` is a pure `WikiFSCore` policy. It is stateless, synchronous, and deterministic.

The detector does not own resources or mutable operation state. It has no activation order or disposal work. Therefore, it is not a Cordis service.

Cordis-composed ingestion services call the typed detector API as ordinary code. Architecture tests reject Cordis imports, service keys, and component definitions for content detection.

## Persistence

Initial source writes, refresh versions, and snapshot image writes run the detector from their byte payload. The store writes the same normalized MIME to the active `source_versions` row and the `sources` mirror.

The store logs conflicts through `DebugLog.store`. Logs include the filename, chosen MIME, and evidence origins. Logs do not include source bytes.

Byteless sources do not run byte detection. Their declared MIME passes through the shared normalizer only.

## NULL MIME repair

`wikictl admin repair-mime` is a dry run by default. Add `--apply` to write changes. Add `--json` for a typed JSON report.

The command selects an active byte-bearing source when either MIME mirror is NULL. It resolves the active version from the ref first, then uses the maximum version ID as a fallback.

The query reads `substr(content, 1, limit)` and `length(content)`. It does not load each complete blob.

Apply mode updates both MIME mirrors in one transaction. It does not change historical inactive versions. It emits one source update event per changed source after commit.

The command skips byteless and inconclusive rows. It does not change rows where both MIME mirrors are non-NULL.

## Compatibility and scope

Existing NULL MIME rows remain readable until an operator applies the repair. No schema migration scans source blobs.

This work does not change source bytes, HTML extraction, renderer package security, renderer preferences, or byteless source policy.

Archive subtype inspection, executable signatures, additional media codecs, and recursive container inspection remain out of scope.
